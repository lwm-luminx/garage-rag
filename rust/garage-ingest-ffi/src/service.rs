//! The ingest service's run (`garage_ingest_run`), the port of `garage_rag.ingest.ingest_xpc`: one source or
//! every enabled one (`"*"`), each through [`run_source_with`](super::run_source_with) with the files read by
//! the host, and progress sent to the host as the app's `IngestProgress` events, field for field.

use garage_ingest::facade::{self, Connection};
use garage_ingest::pipeline::Counters;
use serde_json::{Map, Value, json};

use super::{GarageIngestHost, Outcome, ReadingHost, budget_from, budget_json, send_event};

/// The `garage.json` settings a run reads from GarageService (`GetSetting`) with `"settings": "service"`,
/// and where each goes in the request: `(name, object, field)`.
const SERVICE_SETTINGS: [(&str, &str, &str); 12] = [
    ("chunking.size", "settings", "chunk_size"),
    ("chunking.overlap", "settings", "chunk_overlap"),
    ("chunking.code_size", "settings", "code_chunk_size"),
    ("chunking.code_overlap", "settings", "code_chunk_overlap"),
    ("quality.max_chunks_per_document", "settings", "max_chunks_per_document"),
    ("quality.reject_machine_generated", "settings", "reject_machine_generated"),
    ("extraction.index_images", "settings", "index_images"),
    ("placeholders.materialize", "budget", "enabled"),
    ("placeholders.limit", "budget", "max_files"),
    ("placeholders.max_bytes", "budget", "max_bytes"),
    ("placeholders.timeout_seconds", "budget", "timeout_seconds"),
    ("identity.name", "self", "name"),
];

/// What a source's progress events say besides the counters: `IngestProgress`'s `source`, `total_items` and
/// `item_type`, from the scan.
pub(super) struct SourceEvents {
    pub(super) source: String,
    pub(super) total_items: u64,
    pub(super) item_type: String,
}

impl SourceEvents {
    /// `_handle_pipeline_progress`'s event for one of the loop's reports.
    pub(super) fn progress(&self, phase: &str, current_item: Option<&str>, counters: &Counters) -> Value {
        let source = &self.source;
        let (seen, total, item_type) = (counters.seen, self.total_items, &self.item_type);
        #[allow(clippy::cast_precision_loss)] // counts far below 2^52
        let progress = if total > 0 { (seen as f64 / total as f64).clamp(0.0, 1.0) } else { 0.0 };
        let percent = if total > 0 { format!("{:.1}%", progress * 100.0) } else { "0.0%".to_owned() };
        let (indexed, skipped, failed) = (counters.indexed, counters.skipped, counters.failed);
        let message = match (phase, current_item) {
            ("scan", _) => format!("Scanning {source}: found {total} {item_type}"),
            ("cancelled", _) => {
                format!(
                    "Ingestion cancelled for {source} after {seen}/{total} {item_type} scanned ({indexed} ingested)"
                )
            }
            (_, Some(item)) if !item.is_empty() => format!(
                "[{seen}/{total} scanned {percent}] {source}: {indexed} ingested ({skipped} skipped, {failed} failed) - {item}"
            ),
            _ => format!(
                "[{seen}/{total} scanned {percent}] {source}: {indexed} ingested ({skipped} skipped, {failed} failed, {} chunks)",
                counters.chunks_written
            ),
        };
        let mut event = self.event(phase, counters, progress, &message);
        event["error"] = counters.errors.last().map_or(Value::Null, |error| json!(error));
        event["current_item"] = current_item.map_or(Value::Null, |item| json!(item));
        event
    }

    /// The `complete` event of a source that ran to its end, or stopped at its limit, from the reply's
    /// counters.
    fn complete(&self, counters: &Value) -> Value {
        let count = |name: &str| counters.get(name).and_then(Value::as_u64).unwrap_or_default();
        let counters = Counters {
            seen: count("seen"),
            indexed: count("indexed"),
            skipped: count("skipped"),
            failed: count("failed"),
            placeholders: count("placeholders"),
            rejected: count("rejected"),
            chunks_written: count("chunks_written"),
            errors: Vec::new(),
        };
        let source = &self.source;
        let message = format!(
            "Ingested {source}: seen {}/{}, indexed {}, skipped {}, failed {}, {} chunks written",
            counters.seen,
            self.total_items,
            counters.indexed,
            counters.skipped,
            counters.failed,
            counters.chunks_written
        );
        self.event("complete", &counters, 1.0, &message)
    }

    fn event(&self, phase: &str, counters: &Counters, progress: f64, message: &str) -> Value {
        json!({
            "source": self.source,
            "phase": phase,
            "seen": counters.seen,
            "total_items": self.total_items,
            "indexed": counters.indexed,
            "skipped": counters.skipped,
            "failed": counters.failed,
            "placeholders": counters.placeholders,
            "rejected": counters.rejected,
            "chunks_written": counters.chunks_written,
            "item_type": self.item_type,
            "progress": progress,
            "message": message,
            "error": Value::Null,
            "current_item": Value::Null,
        })
    }
}

/// An event for `source` before its run, or after it failed: no counters, the scan not yet read.
fn bare_event(source: &str, phase: &str, message: &str, error: Option<&str>) -> Value {
    let events = SourceEvents { source: source.to_owned(), total_items: 0, item_type: "items".to_owned() };
    let mut event = events.event(phase, &Counters::default(), 0.0, message);
    event["error"] = error.map_or(Value::Null, |error| json!(error));
    event
}

/// The request with the settings GarageService runs with filled in, unless the request states its own.
fn with_service_settings(request: &Map<String, Value>, connection: &Connection) -> Map<String, Value> {
    let mut request = request.clone();
    if request.get("settings").and_then(Value::as_str) != Some("service") {
        return request;
    }
    let mut objects: Map<String, Value> =
        ["settings", "budget", "self"].into_iter().map(|name| (name.to_owned(), json!({}))).collect();
    // A key GarageService cannot answer keeps the library's default, which is Python's.
    for (name, object, field) in SERVICE_SETTINGS {
        if let Ok(value) = facade::get_setting(connection, name)
            && !value.is_null()
        {
            objects[object][field] = value;
        }
    }
    if let Ok(Value::Array(identities)) = facade::get_setting(connection, "identity.identities") {
        objects["self"]["identities"] = Value::Array(identities);
    }
    request.extend(objects);
    request
}

/// Runs the request's `"source"` (a slug, or `"*"` for every enabled source) as `ingest_xpc` does.
pub(super) fn run(request: &Map<String, Value>, host: GarageIngestHost) -> Outcome {
    let facade_object =
        request.get("facade").and_then(Value::as_object).ok_or("the request has no \"facade\" object")?;
    let source = request.get("source").and_then(Value::as_str).ok_or("the request has no \"source\" string")?;
    let connection =
        Connection::connect(&super::facade_target(facade_object)?, facade_object.get("token").and_then(Value::as_str))
            .map_err(|error| error.to_string())?;
    let base = with_service_settings(request, &connection);
    let sources = if source == "*" {
        let sources = facade::list_enabled_sources(&connection).map_err(|error| error.to_string())?;
        if sources.is_empty() {
            return Ok(json!({ "error": "No sources registered", "sources": [] }));
        }
        sources
    } else {
        vec![source.to_owned()]
    };
    drop(connection);

    // SAFETY: the host's contract (garage_ingest.h).
    let cancelled = || host.cancelled.is_some_and(|cancelled| unsafe { cancelled(host.context) });
    let mut unavailable = Vec::new();
    let mut outcomes = Vec::new();
    // Only the materialize thread may start a download; a read here of a dataless file fails instead.
    let _policy = garage_ingest::materialize::refusing_dataless_reads();
    for slug in sources {
        if cancelled() {
            break;
        }
        send_event(&host, &bare_event(&slug, "scan", &format!("Starting ingestion for {slug}..."), None));
        let mut request = base.clone();
        let mut facade_object = facade_object.clone();
        facade_object.insert("source_slug".to_owned(), json!(slug));
        request.insert("facade".to_owned(), Value::Object(facade_object));
        // Each source gets the whole budget, as each `ingest_source` call builds its own.
        let budget = budget_from(&request)?;
        let mut events: Option<SourceEvents> = None;
        let reply = super::run_source_with(
            &request,
            |_root, scan| ReadingHost {
                host,
                budget,
                events: Some(SourceEvents {
                    source: slug.clone(),
                    total_items: scan.item_count,
                    item_type: scan.item_type.clone(),
                }),
            },
            |reading, reply| {
                reply.insert("budget".to_owned(), budget_json(&reading.budget));
                events = reading.events;
            },
        );
        let mut reply = match reply {
            Ok(Value::Object(reply)) => reply,
            Ok(_) => unreachable!("run_source_with replies with an object"),
            Err(error) => {
                send_event(
                    &host,
                    &bare_event(&slug, "error", &format!("Error ingesting {slug}: {error}"), Some(&error)),
                );
                return Ok(json!({ "error": error, "sources": outcomes }));
            }
        };
        reply.insert("source".to_owned(), json!(slug));
        if let Some(problem) = reply.get("unavailable").and_then(Value::as_str).map(str::to_owned) {
            // The other sources still get their turn; the run fails as a whole below.
            send_event(
                &host,
                &bare_event(&slug, "error", &format!("Error ingesting {slug}: {problem}"), Some(&problem)),
            );
            unavailable.push(format!("{slug}: {problem}"));
            outcomes.push(Value::Object(reply));
            continue;
        }
        if let Some(error) = reply.get("error").and_then(Value::as_str).map(str::to_owned) {
            send_event(&host, &bare_event(&slug, "error", &format!("Error ingesting {slug}: {error}"), Some(&error)));
            outcomes.push(Value::Object(reply));
            return Ok(json!({ "error": error, "sources": outcomes }));
        }
        outcomes.push(Value::Object(reply));
        if cancelled() {
            // The loop already sent the cancelled event, with the item it stopped on.
            break;
        }
        if let (Some(events), Some(counters)) = (events, outcomes.last().and_then(|reply| reply.get("counters"))) {
            send_event(&host, &events.complete(counters));
        }
    }
    let mut reply = json!({ "sources": outcomes, "cancelled": cancelled() });
    if !unavailable.is_empty() {
        reply["error"] = json!(unavailable.join("; "));
    }
    Ok(reply)
}
