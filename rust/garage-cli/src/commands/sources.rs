//! Sources: `sync`, `add-source`, `remove-source`, `list-sources`, `scan`, `ingest` and
//! `reconcile`.

use std::ffi::{CStr, CString, c_char, c_void};

use garage_facade::proto;
use serde_json::{Map, Value, json};

use super::{Command, Context, bad_parameter};
use crate::args::Opt;
use crate::backend::Failure;
use crate::out::{self, Justify, Table, commas};

pub const SYNC: Command = Command {
    name: "sync",
    opts: &[Opt::flag("apply"), Opt::flag("dry-run")],
    help: "Apply sources declared in the config file to the database.",
    run: |context, parsed| {
        let apply = !parsed.has("dry-run");
        let result = context
            .backend()?
            .call(|mut client| async move { client.sync_sources(proto::SyncSourcesRequest { dry_run: !apply }).await })
            .map_err(|failure| Failure::failed(format!("[red]{}[/red]", failure.message)))?;
        if result.declared == 0 {
            let path = if result.config_path.is_empty() { "the config file".to_owned() } else { result.config_path };
            out::print(&format!("[yellow]no sources declared[/yellow] in {path}"));
            return Ok(());
        }
        let verb = if apply { "" } else { "would " };
        if !result.created.is_empty() {
            out::print(&format!("[green]{verb}create[/green]: {}", result.created.join(", ")));
        }
        if !result.updated.is_empty() {
            out::print(&format!("[cyan]{verb}update[/cyan]: {}", result.updated.join(", ")));
        }
        if result.created.is_empty() && result.updated.is_empty() {
            out::print("[green]database already matches the config[/green]");
        }
        if !result.undeclared.is_empty() {
            out::print("\n[dim]in the database but not declared (left untouched):[/dim]");
            for source in &result.undeclared {
                out::print(&format!("  {} ({} documents)", source.slug, commas(source.document_count)));
            }
            out::print("  [dim]add them to the config, or remove with 'garage remove-source <slug>'[/dim]");
        }
        Ok(())
    },
};

pub const ADD_SOURCE: Command = Command {
    name: "add-source",
    opts: &[Opt::value("kind"), Opt::value("class"), Opt::value("trust")],
    help: "Register a source root to be walked.",
    run: |context, parsed| {
        let slug = parsed.arg(0, "SLUG").map_err(Failure::usage)?.to_owned();
        let root = parsed.arg(1, "ROOT").map_err(Failure::usage)?.to_owned();
        let request = proto::AddSourceRequest {
            slug: slug.clone(),
            root,
            kind: parsed.get("kind").unwrap_or("filesystem").to_owned(),
            corpus_class: parsed.get("class").unwrap_or("document").to_owned(),
            trust: parsed.get("trust").unwrap_or("authored").to_owned(),
        };
        let (corpus_class, trust) = (request.corpus_class.clone(), request.trust.clone());
        let result = context
            .backend()?
            .call(|mut client| async move { client.add_source(request).await })
            .map_err(|failure| bad_parameter("--kind / --class / --trust / ROOT", &failure.message))?;
        if result.created {
            out::print(&format!("[green]added source[/green] {slug} -> {} ({corpus_class}/{trust})", result.root));
        } else {
            out::print(&format!("[green]updated source[/green] {slug} -> {}", result.root));
        }
        Ok(())
    },
};

/// Every registered source, in id order (`ListSources`).
fn list(context: &mut Context) -> Result<Vec<proto::SourceInfo>, Failure> {
    Ok(context
        .backend()?
        .call(|mut client| async move { client.list_sources(proto::ListSourcesRequest {}).await })?
        .sources)
}

pub const REMOVE_SOURCE: Command = Command {
    name: "remove-source",
    opts: &[Opt::flag("yes")],
    help: "Deregister a source and delete its documents, chunks, and vectors.",
    run: |context, parsed| {
        let slug = parsed.arg(0, "SLUG").map_err(Failure::usage)?.to_owned();
        let Some(source) = list(context)?.into_iter().find(|s| s.slug == slug) else {
            return Err(Failure::failed(format!("[yellow]no such source[/yellow]: {slug}")));
        };
        if !parsed.has("yes")
            && !out::confirm(&format!("Remove source {slug} and delete {} documents?", commas(source.document_count)))
        {
            return Err(Failure::failed("Aborted."));
        }
        let request = proto::RemoveSourceRequest { slug: slug.clone() };
        let result = context.backend()?.call(|mut client| async move { client.remove_source(request).await })?;
        out::print(&format!("[green]removed[/green] {slug} ({} documents)", commas(result.deleted_documents)));
        Ok(())
    },
};

pub const LIST_SOURCES: Command = Command {
    name: "list-sources",
    opts: &[],
    help: "List registered sources.",
    run: |context, _| {
        let sources = list(context)?;
        if sources.is_empty() {
            out::print("[yellow]no sources registered[/yellow]");
            return Ok(());
        }
        let mut table = Table::new(None);
        for col in ["slug", "kind", "docs", "class", "trust", "enabled", "root"] {
            table.column(col, if col == "docs" { Justify::Right } else { Justify::Left });
        }
        for s in &sources {
            table.row(&[
                s.slug.as_str(),
                s.kind.as_str(),
                &commas(s.document_count),
                s.corpus_class.as_str(),
                s.trust_tier.as_str(),
                if s.enabled { "yes" } else { "no" },
                s.root.as_str(),
            ]);
        }
        table.print();
        Ok(())
    },
};

pub const SCAN: Command = Command {
    name: "scan",
    opts: &[Opt::short_value("source", 's'), Opt::flag("include-code"), Opt::flag("json")],
    help: "Scan sources and count items by source type before ingesting.",
    run: |context, parsed| {
        let source = parsed.get("source").unwrap_or("*").to_owned();
        let request = proto::ScanRequest { source: source.clone(), include_code: parsed.has("include-code") };
        let mut results: Vec<proto::SourceScanStatus> = Vec::new();
        context
            .backend()?
            .stream(
                |mut client| async move { client.scan(request).await },
                |status: proto::ScanStatus| {
                    if status.phase == "source"
                        && let Some(result) = status.result
                    {
                        results.push(result);
                    }
                    true
                },
            )
            .map_err(|failure| {
                if failure.message.contains("no such source") || failure.message.contains("not found") {
                    Failure::failed(format!("[red]no such source:[/red] {source}"))
                } else {
                    failure
                }
            })?;
        if results.is_empty() {
            out::print("[yellow]no sources registered to scan[/yellow]");
            return Ok(());
        }
        if parsed.has("json") {
            let items: Vec<Value> = results
                .iter()
                .map(|r| {
                    json!({
                        "source_slug": r.source, "kind": r.kind, "root": r.root, "item_count": r.item_count,
                        "item_type": r.item_type, "details": {},
                        "duration_seconds": (r.duration_seconds * 10_000.0).round() / 10_000.0,
                        "error": if r.error.is_empty() { Value::Null } else { json!(r.error) },
                    })
                })
                .collect();
            println!("{}", serde_json::to_string_pretty(&items).unwrap_or_default());
            return Ok(());
        }
        let mut table = Table::new(Some("source scan"));
        table
            .column("slug", Justify::Left)
            .column("kind", Justify::Left)
            .column("items", Justify::Right)
            .column("item type", Justify::Left)
            .column("time", Justify::Right)
            .column("root", Justify::Left)
            .column("status", Justify::Left);
        let mut total_items = 0;
        for r in &results {
            total_items += r.item_count;
            let status = if r.error.is_empty() {
                "[green]ok[/green]".to_owned()
            } else {
                format!("[red]error: {}[/red]", r.error)
            };
            table.row(&[
                r.source.clone(),
                r.kind.clone(),
                commas(r.item_count),
                r.item_type.clone(),
                format!("{:.2}s", r.duration_seconds),
                r.root.clone(),
                status,
            ]);
        }
        table.print();
        out::print(&format!("[dim]Total across {} source(s): {} items[/dim]", results.len(), commas(total_items)));
        Ok(())
    },
};

/// What `ingest` hears from the run, per source: the scan's count and the last progress report,
/// printed as the Python CLI's status line did off a terminal.
#[derive(Default)]
struct IngestProgress {
    last_reported: u64,
    /// Each source's `total_items` and `item_type`, from its events.
    scans: Map<String, Value>,
}

unsafe extern "C" fn ingest_progress(context: *mut c_void, event: *const c_char) {
    if context.is_null() || event.is_null() {
        return;
    }
    // SAFETY: the context is the IngestProgress `run_ingest` passed, alive until the run returns;
    // the event is a NUL-terminated string for the duration of the call.
    let (state, event) = unsafe { (&mut *context.cast::<IngestProgress>(), CStr::from_ptr(event)) };
    let Ok(event) = serde_json::from_slice::<Value>(event.to_bytes()) else { return };
    let text = |key: &str| event.get(key).and_then(Value::as_str).unwrap_or_default().to_owned();
    let count = |key: &str| event.get(key).and_then(Value::as_u64).unwrap_or_default();
    let (source, phase) = (text("source"), text("phase"));
    let (total, item_type) = (count("total_items"), text("item_type"));
    state.scans.insert(source.clone(), json!({ "total_items": total, "item_type": item_type }));
    match phase.as_str() {
        // The run announces each source before its scan ("Starting ingestion for …"), then the count.
        "scan" if text("message").starts_with("Scanning") => {
            out::print(&format!("[cyan]scanned {source}[/cyan]: found {} {item_type}", commas(total)));
        }
        "scan" | "complete" => {}
        "error" => out::print(&format!("[red]{source}: {}[/red]", text("error"))),
        "cancelled" => out::print(&text("message")),
        _ => {
            let seen = count("seen");
            let should_report = seen.saturating_sub(state.last_reported) >= 50 || (total > 0 && seen == total);
            if should_report && !out::is_terminal() {
                state.last_reported = seen;
                let pct = if total > 0 {
                    #[allow(clippy::cast_precision_loss)]
                    let pct = seen as f64 / total as f64 * 100.0;
                    format!(" [{pct:.1}%]")
                } else {
                    String::new()
                };
                out::print(&format!(
                    "{source}:{pct} scanned {}/{} | ingested {} (skipped {}, failed {})",
                    commas(seen),
                    commas(total),
                    commas(count("indexed")),
                    commas(count("skipped")),
                    commas(count("failed"))
                ));
            }
        }
    }
}

/// Runs the ingest service's request in this process (`garage_ingest_run`, as GarageIngestXPCService
/// does), persisting through the backend.
fn run_ingest(request: &Value, state: &mut IngestProgress) -> Result<Value, Failure> {
    let host = garage_ingest_ffi::GarageIngestHost {
        context: std::ptr::from_mut(state).cast::<c_void>(),
        read: None,
        release: None,
        progress: Some(ingest_progress),
        cancelled: None,
        shared_names: None,
        // No HTTPS client and no cloud account here: a Dropbox or OneDrive source fails as unavailable.
        http: None,
        access_token: None,
    };
    let request = CString::new(request.to_string()).map_err(|_| Failure::failed("the request held a NUL byte"))?;
    let mut result: *mut c_char = std::ptr::null_mut();
    // SAFETY: the request is a C string, the host's context lives for the call, the result pointer
    // is writable; the result is freed below with the library's free.
    let status = unsafe { garage_ingest_ffi::garage_ingest_run(request.as_ptr(), &raw const host, &raw mut result) };
    let reply = if result.is_null() {
        String::new()
    } else {
        // SAFETY: a non-null result is the library's NUL-terminated string, freed once.
        let text = unsafe { CStr::from_ptr(result) }.to_string_lossy().into_owned();
        unsafe { garage_ingest_ffi::garage_ingest_string_free(result) };
        text
    };
    let reply: Value = serde_json::from_str(&reply).unwrap_or(Value::Null);
    if status != 0 {
        let message = reply.get("error").and_then(Value::as_str).unwrap_or("the ingest run failed").to_owned();
        return Err(Failure::failed(format!("[red]{message}[/red]")));
    }
    Ok(reply)
}

pub const INGEST: Command = Command {
    name: "ingest",
    opts: &[Opt::short_value("source", 's'), Opt::flag("include-code"), Opt::value("limit"), Opt::flag("force")],
    help: "Walk a source and index it. Safe to re-run; unchanged files are skipped.",
    run: |context, parsed| {
        let source = parsed.get("source").unwrap_or("*").to_owned();
        let limit: Option<i64> = parsed.int("limit").map_err(Failure::usage)?;
        let sources = list(context)?;
        if source == "*" {
            // '*' means every *enabled* source; a disabled one must be named to be ingested.
            if !sources.iter().any(|s| s.enabled) {
                out::print("[yellow]no sources registered to ingest[/yellow]");
                return Ok(());
            }
        } else if !sources.iter().any(|s| s.slug == source) {
            return Err(Failure::failed(format!("[red]no such source:[/red] {source}")));
        }
        let socket = context.backend()?.socket.display().to_string();
        let mut request = json!({
            "facade": { "socket": socket },
            "source": source,
            "settings": "service",
            "readers": {},
            "include_code": parsed.has("include-code"),
            "force": parsed.has("force"),
            "read_git": true,
        });
        if let Some(limit) = limit {
            request["limit"] = json!(limit);
        }
        let mut state = IngestProgress::default();
        let reply = run_ingest(&request, &mut state)?;
        let mut unavailable: Vec<String> = Vec::new();
        for outcome in reply.get("sources").and_then(Value::as_array).into_iter().flatten() {
            let slug = outcome.get("source").and_then(Value::as_str).unwrap_or_default();
            if outcome.get("unavailable").is_some() {
                unavailable.push(slug.to_owned());
                continue;
            }
            if outcome.get("error").is_some() {
                continue;
            }
            print_ingest_table(slug, outcome, state.scans.get(slug));
        }
        if let Some(error) = reply.get("error").and_then(Value::as_str)
            && unavailable.is_empty()
        {
            return Err(Failure::failed(format!("[red]{error}[/red]")));
        }
        if !unavailable.is_empty() {
            return Err(Failure::failed(format!(
                "\n[red]{} source(s) could not be read:[/red] {}",
                unavailable.len(),
                unavailable.join(", ")
            )));
        }
        Ok(())
    },
};

/// The `ingest: <source>` table and the notes under it, from a source's reply.
fn print_ingest_table(slug: &str, outcome: &Value, scan: Option<&Value>) {
    let counters = outcome.get("counters").cloned().unwrap_or_default();
    let walk = outcome.get("walk_stats").cloned().unwrap_or_default();
    let budget = outcome.get("budget").cloned().unwrap_or_default();
    let count = |object: &Value, key: &str| object.get(key).and_then(Value::as_u64).unwrap_or_default();
    let item_type = scan.and_then(|s| s.get("item_type")).and_then(Value::as_str).unwrap_or("items");
    let total_items = scan.map_or(0, |s| count(s, "total_items"));
    let mut table = Table::new(Some(&format!("ingest: {slug}")));
    table.column("metric", Justify::Left).column("count", Justify::Right);
    let rows: [(String, u64); 14] = [
        (format!("scanned items ({item_type})"), total_items),
        ("candidates seen".into(), count(&counters, "seen")),
        ("indexed".into(), count(&counters, "indexed")),
        ("skipped (unchanged)".into(), count(&counters, "skipped")),
        ("failed".into(), count(&counters, "failed")),
        ("rejected: machine-generated".into(), count(&counters, "rejected")),
        ("chunks written".into(), count(&counters, "chunks_written")),
        ("placeholders pending".into(), count(&counters, "placeholders")),
        ("dirs walked".into(), count(&walk, "dirs")),
        ("files examined".into(), count(&walk, "files_seen")),
        ("skipped: not indexable".into(), count(&walk, "skipped_extension")),
        ("skipped: diagnostic".into(), count(&walk, "skipped_diagnostic")),
        ("skipped: code".into(), count(&walk, "skipped_code")),
        ("skipped: too large".into(), count(&walk, "skipped_too_large")),
    ];
    for (label, value) in &rows {
        table.row(&[label.as_str(), &commas(*value)]);
    }
    table.print();
    if budget.get("enabled").and_then(Value::as_bool).unwrap_or(false) {
        out::print(&format!(
            "[cyan]placeholders[/cyan]: {}",
            budget.get("summary").and_then(Value::as_str).unwrap_or_default()
        ));
        if count(&budget, "deferred") > 0 {
            out::print(
                "  [yellow]budget reached[/yellow]: re-run to continue (unchanged files are skipped, so progress accumulates)",
            );
        }
    } else if count(&counters, "placeholders") > 0 {
        out::print(&format!(
            "[yellow]{} placeholders skipped[/yellow] (set placeholders.materialize = true in the config to download them)",
            commas(count(&counters, "placeholders"))
        ));
    }
    let errors: Vec<&str> =
        counters.get("errors").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_str).collect();
    if !errors.is_empty() {
        out::print(&format!("\n[red]first {} errors[/red]:", errors.len().min(5)));
        for message in errors.iter().take(5) {
            out::print(&format!("  {message}"));
        }
    }
}

pub const RECONCILE: Command = Command {
    name: "reconcile",
    opts: &[Opt::short_value("source", 's'), Opt::flag("apply"), Opt::flag("force")],
    help: "Delete documents whose source files no longer exist.",
    run: |context, parsed| {
        let Some(source) = parsed.get("source").map(str::to_owned) else {
            return Err(Failure::usage("Error: Missing option '--source' / '-s'."));
        };
        let apply = parsed.has("apply");
        let request = proto::ReconcileRequest { source: source.clone(), apply, force: parsed.has("force") };
        let result = context.backend()?.call(|mut client| async move { client.reconcile(request).await })?;
        if result.refused {
            return Err(Failure::failed(format!("[yellow]refused[/yellow]: {}", result.reason)));
        }
        if result.candidates == 0 {
            out::print(&format!("[green]nothing to reconcile[/green] for {source}"));
            return Ok(());
        }
        if apply {
            out::print(&format!(
                "[green]deleted[/green] {} of {} documents from {source}",
                commas(result.deleted),
                commas(result.total_documents)
            ));
        } else {
            out::print(&format!(
                "[cyan]dry run[/cyan]: {} of {} documents in {source} are missing ({:.1}%). Re-run with --apply to delete.",
                commas(result.candidates),
                commas(result.total_documents),
                result.fraction * 100.0
            ));
        }
        Ok(())
    },
};
