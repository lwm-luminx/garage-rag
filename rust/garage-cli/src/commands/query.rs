//! Reading the corpus from the terminal: `search`, `ask` and `extract`.

use std::path::Path;

use garage_facade::proto;
use garage_ingest::pipeline::ReadOutcome;
use garage_ingest::{ContentKind, chunk_text};
use garage_mcp::tools::ToolError;
use serde_json::{Map, Value, json};

use super::Command;
use super::mcp::toolbox;
use crate::args::{Opt, Parsed};
use crate::backend::Failure;
use crate::out::{self, Table, commas, tilde};

const MODES: [&str; 3] = ["hybrid", "vector", "fts"];

fn mode(parsed: &Parsed) -> Result<String, Failure> {
    let mode = parsed.get("mode").unwrap_or("hybrid");
    if !MODES.contains(&mode) {
        return Err(Failure::usage(format!(
            "Error: Invalid value for '--mode': '{mode}' is not one of 'hybrid', 'vector', 'fts'."
        )));
    }
    Ok(mode.to_owned())
}

pub const SEARCH: Command = Command {
    name: "search",
    opts: &[
        Opt::short_value("limit", 'n'),
        Opt::value("mode"),
        Opt::short_value("model", 'm'),
        Opt::value("class"),
        Opt::value("trust"),
        Opt::short_value("source", 's'),
        Opt::value("author"),
        Opt::value("direction"),
        Opt::flag("full"),
    ],
    help: "Search the corpus with hybrid vector and keyword retrieval.",
    run: |context, parsed| {
        let direction = parsed.get("direction").unwrap_or_default().to_owned();
        if !matches!(direction.as_str(), "" | "sent" | "received") {
            return Err(Failure::usage(format!(
                "Error: Invalid value for '--direction': '{direction}' is not one of 'sent', 'received'."
            )));
        }
        let full = parsed.has("full");
        let request = proto::SearchRequest {
            query: parsed.arg(0, "QUERY").map_err(Failure::usage)?.to_owned(),
            limit: parsed.int::<i32>("limit").map_err(Failure::usage)?.unwrap_or(10),
            mode: mode(parsed)?,
            model: parsed.get("model").unwrap_or_default().to_owned(),
            corpus_classes: parsed.all("class"),
            trust_tiers: parsed.all("trust"),
            sources: parsed.all("source"),
            author: parsed.get("author").unwrap_or_default().to_owned(),
            full,
            direction,
        };
        let response = context.backend()?.call(|mut client| async move { client.search(request).await })?;
        if response.hits.is_empty() {
            out::print("[yellow]no results[/yellow]");
            return Ok(());
        }
        for (index, hit) in response.hits.iter().enumerate() {
            let title = if hit.title.is_empty() { "(untitled)" } else { &hit.title };
            out::print(&format!(
                "\n[bold cyan]{}.[/bold cyan] [bold]{title}[/bold] [dim]({}/{}, {}, score {:.4})[/dim]",
                index + 1,
                hit.corpus_class,
                hit.trust_tier,
                hit.matched_by,
                hit.score
            ));
            out::print(&format!("   [dim]{}[/dim]", tilde(&hit.uri)));
            if !hit.heading_path.is_empty() {
                out::print(&format!("   [dim]section: {}[/dim]", hit.heading_path));
            }
            if !hit.authors.is_empty() {
                let shown: Vec<&str> = hit.authors.iter().take(4).map(String::as_str).collect();
                out::print(&format!("   [dim]authors: {}[/dim]", shown.join(", ")));
            }
            if !hit.direction.is_empty() {
                let by = if hit.sender.is_empty() { String::new() } else { format!(" by {}", hit.sender) };
                out::print(&format!("   [dim]{}{by}[/dim]", hit.direction));
            }
            let body = if full { &hit.text } else { &hit.snippet };
            println!("   {body}");
        }
        Ok(())
    },
};

pub const ASK: Command = Command {
    name: "ask",
    opts: &[
        Opt::flag("raw"),
        Opt::short_value("limit", 'n'),
        Opt::value("mode"),
        Opt::value("class"),
        Opt::value("trust"),
        Opt::short_value("source", 's'),
        Opt::value("max-tokens"),
        Opt::short_value("temperature", 't'),
        Opt::flag("json"),
    ],
    help: "Ask the local model a question, answered from retrieved excerpts with numbered citations.",
    run: |context, parsed| {
        let question = parsed.arg(0, "QUESTION").map_err(Failure::usage)?.to_owned();
        let raw = parsed.has("raw");
        let as_json = parsed.has("json");
        let max_tokens = parsed.int::<i64>("max-tokens").map_err(Failure::usage)?;
        let temperature = parsed.float("temperature").map_err(Failure::usage)?;
        let mode = mode(parsed)?;
        let mut args = Map::new();
        if raw {
            args.insert("prompt".into(), json!(question));
        } else {
            args.insert("question".into(), json!(question));
            args.insert("limit".into(), json!(parsed.int::<i64>("limit").map_err(Failure::usage)?.unwrap_or(6)));
            args.insert("mode".into(), json!(mode));
            for (key, option) in [("corpus_class", "class"), ("trust", "trust"), ("source", "source")] {
                let values = parsed.all(option);
                if !values.is_empty() {
                    args.insert(key.into(), json!(values));
                }
            }
        }
        if let Some(max_tokens) = max_tokens {
            args.insert("max_tokens".into(), json!(max_tokens));
        }
        if let Some(temperature) = temperature {
            args.insert("temperature".into(), json!(temperature));
        }
        let (tools, caller) = toolbox(context)?;
        let result = match tools.call(if raw { "rag_generate" } else { "rag_ask" }, &args, &caller) {
            Ok(result) => result,
            Err(ToolError::Failed(reason) | ToolError::Unknown(reason)) => {
                if as_json {
                    println!("{}", json!({ "error": reason }));
                    return Err(Failure::silent(1));
                }
                return Err(Failure::failed(format!("[red]model unavailable[/red]: {reason}")));
            }
            Err(ToolError::Invalid(error)) => return Err(Failure::usage(error.to_string())),
        };
        if as_json {
            // Plain print: no wrapping or markup in machine output.
            println!("{result}");
            return Ok(());
        }
        let text = |key: &str| result.get(key).and_then(Value::as_str).unwrap_or_default().to_owned();
        if raw {
            println!("{}", text("text"));
            out::print(&format!("\n[dim]{}/{}[/dim]", text("provider"), text("model")));
            return Ok(());
        }
        println!("{}", text("answer"));
        let mut footer = format!("{}/{}", text("provider"), text("model"));
        let tokens = |key: &str| result.get(key).and_then(Value::as_i64);
        if tokens("prompt_tokens").is_some() || tokens("completion_tokens").is_some() {
            footer.push_str(&format!(
                ", tokens in/out {}/{}",
                tokens("prompt_tokens").unwrap_or(0),
                tokens("completion_tokens").unwrap_or(0)
            ));
        }
        out::print(&format!("\n[dim]{footer}[/dim]"));
        let citations: Vec<&Value> = result.get("citations").and_then(Value::as_array).into_iter().flatten().collect();
        if citations.is_empty() {
            out::print("[yellow]no excerpts retrieved[/yellow]");
            return Ok(());
        }
        let mut table = Table::new(Some("citations"));
        table.columns(&["n", "title", "location", "score", "snippet"]);
        for c in citations {
            let field = |key: &str| c.get(key).and_then(Value::as_str).unwrap_or_default().to_owned();
            let title = c.get("title").and_then(Value::as_str).filter(|t| !t.is_empty()).unwrap_or("(untitled)");
            table.row(&[
                format!("[{}]", c.get("n").and_then(Value::as_i64).unwrap_or_default()),
                title.to_owned(),
                field("location"),
                format!("{:.4}", c.get("score").and_then(Value::as_f64).unwrap_or_default()),
                field("snippet"),
            ]);
        }
        table.print();
        Ok(())
    },
};

fn kind_name(kind: ContentKind) -> &'static str {
    match kind {
        ContentKind::Prose => "prose",
        ContentKind::Markdown => "markdown",
        ContentKind::Code => "code",
        ContentKind::Tabular => "tabular",
        ContentKind::Conversation => "conversation",
        ContentKind::Image => "image",
    }
}

pub const EXTRACT: Command = Command {
    name: "extract",
    opts: &[Opt::value("show"), Opt::flag("full")],
    help: "Extract and chunk a single file without touching the database.",
    run: |context, parsed| {
        let target = garage_service::config::expand_home(Path::new(parsed.arg(0, "PATH").map_err(Failure::usage)?));
        let show = parsed.int::<usize>("show").map_err(Failure::usage)?.unwrap_or(3);
        let full = parsed.has("full");
        let config = context.config()?;
        let setting =
            |name: &str| config.setting(name).ok().and_then(|v| v.as_u64()).and_then(|v| usize::try_from(v).ok());
        let mut readers = garage_readers::Readers::new(garage_readers::Settings::from_json(
            config.nest().get("extraction").and_then(Value::as_object),
        ));
        let result = match readers.read(&target) {
            ReadOutcome::Document(extracted) => extracted,
            ReadOutcome::Placeholder => {
                // Not a parser problem: the bytes are not on this machine.
                out::print(&format!("[yellow]placeholder[/yellow]: {}", target.display()));
                out::print("  no local content; make it available offline, then re-run");
                return Err(Failure::silent(2));
            }
            ReadOutcome::NoText(message) => {
                out::print(&format!("[yellow]no text[/yellow]: {message}"));
                return Ok(());
            }
            ReadOutcome::Failed(message) | ReadOutcome::Raised(message) => {
                return Err(Failure::failed(format!("[red]extraction failed[/red]: {message}")));
            }
        };
        let extension =
            target.extension().map(|e| format!(".{}", e.to_string_lossy().to_lowercase())).unwrap_or_default();
        let (size, overlap) = if result.kind == ContentKind::Code {
            (setting("chunking.code_size").unwrap_or(1200), setting("chunking.code_overlap").unwrap_or(100))
        } else {
            (setting("chunking.size").unwrap_or(1000), setting("chunking.overlap").unwrap_or(150))
        };
        let chunks = chunk_text(&result.text, result.kind, &extension, size, overlap)
            .map_err(|error| Failure::failed(format!("[red]chunking failed[/red]: {error}")))?;
        out::print(&format!("[bold]{}[/bold]", target.display()));
        out::print(&format!("  extractor : [cyan]{}[/cyan] v{}", result.extractor, result.extractor_version));
        out::print(&format!("  kind      : {}", kind_name(result.kind)));
        out::print(&format!("  title     : {}", garage_mcp::pyrepr::repr(&json!(result.title))));
        out::print(&format!(
            "  chars     : {}",
            commas(i64::try_from(result.text.chars().count()).unwrap_or(i64::MAX))
        ));
        out::print(&format!("  chunks    : {}", chunks.len()));
        if !chunks.is_empty() {
            let mut sizes: Vec<usize> = chunks.iter().map(|c| c.text.chars().count()).collect();
            sizes.sort_unstable();
            out::print(&format!(
                "  chunk len : min={} median={} max={}",
                sizes[0],
                sizes[sizes.len() / 2],
                sizes[sizes.len() - 1]
            ));
            out::print(&format!("  chunker   : {}", chunks[0].chunker));
        }
        if !result.meta.is_empty() {
            out::print(&format!("  meta      : {}", garage_mcp::pyrepr::repr(&Value::Object(result.meta.clone()))));
        }
        if !result.author_hints.is_empty() {
            out::print(&format!("  author?   : {}", garage_mcp::pyrepr::repr(&json!(result.author_hints))));
        }
        for chunk in chunks.iter().take(show) {
            println!();
            let mut header = format!("[dim]--- chunk {} ({} chars)", chunk.ord, chunk.text.chars().count());
            if let Some(heading) = &chunk.heading_path {
                header.push_str(&format!(" | {heading}"));
            }
            out::print(&format!("{header} ---[/dim]"));
            let cut = chunk.text.chars().count() > 400;
            if full || !cut {
                println!("{}", chunk.text);
            } else {
                let head: String = chunk.text.chars().take(400).collect();
                out::print(&format!("{head} [dim]...[/dim]"));
            }
        }
        Ok(())
    },
};
