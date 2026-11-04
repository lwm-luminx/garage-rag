//! Facts: `enrich-facts`, `cluster-facts`, `graph …` and `facts …` (`facts prompts …` included).

use garage_facade::proto;
use serde_json::{Map, Value, json};

use super::{Command, Context, Group};
use crate::args::Opt;
use crate::backend::Failure;
use crate::out::{self, Justify, Table, commas};

pub const ENRICH_FACTS: Command = Command {
    name: "enrich-facts",
    opts: &[
        Opt::short_value("source", 's'),
        Opt::value("document-id"),
        Opt::short_value("model", 'm'),
        Opt::value("provider"),
        Opt::short_value("prompt", 'p'),
        Opt::flag("stale-only"),
    ],
    help: "Distill documents into atomic facts, once per prompt. Re-extraction replaces that prompt's prior facts.",
    run: |context, parsed| {
        let document_id: i64 = parsed.int("document-id").map_err(Failure::usage)?.unwrap_or_default();
        let prompts = parsed.all("prompt");
        let named = document_id > 0 || !prompts.is_empty();
        let request = proto::EnrichFactsRequest {
            source: parsed.get("source").unwrap_or("*").to_owned(),
            document_id,
            model: parsed.get("model").unwrap_or_default().to_owned(),
            provider: parsed.get("provider").unwrap_or_default().to_owned(),
            prompts,
            stale_only: parsed.has("stale-only"),
        };
        let mut summary: Option<proto::EnrichFactsStatus> = None;
        context
            .backend()?
            .stream(
                |mut client| async move { client.enrich_facts(request).await },
                |event: proto::EnrichFactsStatus| {
                    match event.phase.as_str() {
                        "started" => out::print(&format!(
                            "[cyan]enriching[/cyan] {} document(s) via [cyan]{}[/cyan]/{}",
                            commas(event.total),
                            event.provider,
                            event.model
                        )),
                        "document" => {
                            if !event.error.is_empty() {
                                let what = if event.document_uri.is_empty() {
                                    event.document_id.to_string()
                                } else {
                                    event.document_uri.clone()
                                };
                                out::print(&format!("  [red]{what}[/red]: {}", event.error));
                            }
                        }
                        "finished" => summary = Some(event),
                        _ => {}
                    }
                    true
                },
            )
            .map_err(|failure| {
                let style = if named { "red" } else { "yellow" };
                Failure::failed(format!("[{style}]{}[/{style}]", failure.message))
            })?;
        if let Some(s) = summary {
            let mut line =
                format!("{}/{} documents enriched, {} facts extracted", s.enriched, s.total, commas(s.facts));
            if s.skipped > 0 {
                line.push_str(&format!(", {} skipped", s.skipped));
            }
            if s.failed > 0 {
                line.push_str(&format!(", [red]{} failed[/red]", s.failed));
            }
            out::print(&format!("{line} (prompts: {})", s.prompts.join(", ")));
        }
        Ok(())
    },
};

pub const CLUSTER_FACTS: Command = Command {
    name: "cluster-facts",
    opts: &[
        Opt::short_value("model", 'm'),
        Opt::value("threshold"),
        Opt::value("neighbors"),
        Opt::flag("distill"),
        Opt::flag("no-distill"),
        Opt::flag("graph"),
        Opt::flag("no-graph"),
        Opt::flag("full"),
    ],
    help: "Distill the potential facts into distinct claims: restatements within each document, then groups across the corpus.",
    run: |context, parsed| {
        let request = proto::ClusterFactsRequest {
            model: parsed.get("model").unwrap_or_default().to_owned(),
            threshold: parsed.float("threshold").map_err(Failure::usage)?.unwrap_or_default(),
            neighbors: parsed.int::<i32>("neighbors").map_err(Failure::usage)?.unwrap_or_default(),
            no_distill: parsed.has("no-distill"),
            no_graph: parsed.has("no-graph"),
            full: parsed.has("full"),
        };
        let mut summary: Option<proto::ClusterFactsStatus> = None;
        context
            .backend()?
            .stream(
                |mut client| async move { client.cluster_facts(request).await },
                |event: proto::ClusterFactsStatus| {
                    if event.phase == "finished" {
                        summary = Some(event);
                    } else if !event.message.is_empty() && !out::is_terminal() {
                        out::print(&format!("[dim]{}[/dim]", event.message));
                    }
                    true
                },
            )
            .map_err(|failure| Failure::failed(format!("[red]{}[/red]", failure.message)))?;
        if let Some(s) = summary {
            let via = if s.distill_model.is_empty() {
                String::new()
            } else {
                format!(" via [cyan]{}[/cyan]", s.distill_model)
            };
            out::print(&format!("[cyan]{}[/cyan]{via}: {}", s.model, s.message));
            for error in &s.errors {
                out::print(&format!("  [red]{error}[/red]"));
            }
            if !s.graph.is_empty() {
                out::print(&s.graph);
            }
        }
        Ok(())
    },
};

pub static GRAPH: Group = Group {
    name: "graph",
    help: "The corpus as an Apache AGE graph (where the server has AGE).",
    commands: &[GRAPH_REBUILD, GRAPH_LABELS, GRAPH_FIND, GRAPH_NEIGHBORS],
    groups: &[],
};

const NO_GRAPH: &str =
    "[yellow]no graph: this server has no Apache AGE, or `garage graph rebuild` has not run[/yellow]";

const GRAPH_REBUILD: Command = Command {
    name: "rebuild",
    opts: &[],
    help: "Re-project documents, chunks, authors, potential facts and distilled facts into the 'garage' graph.",
    run: |context, _| {
        use garage_service::prompts::{effective_prompts, graph_schema, parse_prompts};
        let config = context.config()?;
        let schema = graph_schema(&effective_prompts(&parse_prompts(&config.setting("facts.prompts")?)?)?)?;
        let pool = garage_service::db::pool_for(&config.database_url())?;
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|e| Failure::failed(e.to_string()))?;
        let summary = runtime.block_on(async {
            let mut client = pool.get().await.map_err(|e| Failure::failed(format!("database error: {e}")))?;
            garage_service::graph::rebuild_graph(&mut client, &schema).await.map_err(Failure::from)
        })?;
        if !summary.available {
            return Err(Failure::failed(format!("[yellow]{}[/yellow]", summary.message())));
        }
        out::print(&summary.message());
        Ok(())
    },
};

const GRAPH_LABELS: Command = Command {
    name: "labels",
    opts: &[],
    help: "Count the graph's vertices and edges by label.",
    run: |context, _| {
        let labels = context
            .backend()?
            .call(|mut client| async move { client.get_graph_labels(proto::GraphLabelsRequest {}).await })?;
        if !labels.available {
            return Err(Failure::failed(NO_GRAPH));
        }
        for label in &labels.vertex_labels {
            out::print(&format!("({}) {}", label.label, commas(label.count)));
        }
        for label in &labels.edge_labels {
            out::print(&format!("-[{}]- {}", label.label, commas(label.count)));
        }
        Ok(())
    },
};

const GRAPH_FIND: Command = Command {
    name: "find",
    opts: &[Opt::short_value("label", 'l'), Opt::short_value("limit", 'n')],
    help: "Find vertices to start a walk from.",
    run: |context, parsed| {
        let request = proto::FindGraphVerticesRequest {
            query: parsed.arg(0, "QUERY").map_err(Failure::usage)?.to_owned(),
            label: parsed.get("label").unwrap_or_default().to_owned(),
            limit: parsed.int::<i32>("limit").map_err(Failure::usage)?.unwrap_or(20),
        };
        let found = context.backend()?.call(|mut client| async move { client.find_graph_vertices(request).await })?;
        for vertex in &found.vertices {
            out::print(&format!("[cyan]{}[/cyan] ({} {}) {}", vertex.id, vertex.label, vertex.key, vertex.title));
        }
        Ok(())
    },
};

const GRAPH_NEIGHBORS: Command = Command {
    name: "neighbors",
    opts: &[
        Opt::short_value("depth", 'd'),
        Opt::short_value("vertex", 'v'),
        Opt::short_value("edge", 'e'),
        Opt::short_value("limit", 'n'),
    ],
    help: "Walk out from one vertex and list what it is connected to.",
    run: |context, parsed| {
        let vertex = parsed.arg(0, "VERTEX").map_err(Failure::usage)?.to_owned();
        let vertex_labels = parsed.all("vertex");
        let edge_labels = parsed.all("edge");
        let mut request = proto::GraphNeighborhoodRequest {
            depth: parsed.int::<i32>("depth").map_err(Failure::usage)?.unwrap_or(1),
            filter_vertex_labels: !vertex_labels.is_empty(),
            filter_edge_labels: !edge_labels.is_empty(),
            vertex_labels,
            edge_labels,
            limit: parsed.int::<i32>("limit").map_err(Failure::usage)?.unwrap_or(200),
            ..Default::default()
        };
        let bad = |what: &str| Failure::failed(format!("[red]invalid literal for int() with base 10: '{what}'[/red]"));
        match vertex.split_once(':') {
            Some((label, key)) if !key.is_empty() => {
                label.clone_into(&mut request.label);
                request.key = key.parse().map_err(|_| bad(key))?;
            }
            _ => request.vertex_id = vertex.parse().map_err(|_| bad(&vertex))?,
        }
        let result = context
            .backend()?
            .call(|mut client| async move { client.get_graph_neighborhood(request).await })
            .map_err(|failure| Failure::failed(format!("[red]{}[/red]", failure.message)))?;
        let Some(center) = result.center.filter(|_| result.available) else {
            return Err(Failure::failed(NO_GRAPH));
        };
        let titles: Map<String, Value> = result
            .vertices
            .iter()
            .map(|v| (v.id.to_string(), json!(format!("({} {}) {}", v.label, v.key, v.title))))
            .collect();
        let title = |id: i64| titles.get(&id.to_string()).and_then(Value::as_str).unwrap_or_default().to_owned();
        out::print(&format!("[bold]{}[/bold]", title(center.id)));
        for edge in &result.edges {
            out::print(&format!("  {} -[{}]-> {}", title(edge.source_id), edge.label, title(edge.target_id)));
        }
        out::print(&format!(
            "[dim]{} vertices, {} edges{}[/dim]",
            commas(i64::try_from(result.vertices.len()).unwrap_or(i64::MAX)),
            commas(i64::try_from(result.edges.len()).unwrap_or(i64::MAX)),
            if result.truncated { ", cut at the limit" } else { "" }
        ));
        Ok(())
    },
};

pub static FACTS: Group = Group {
    name: "facts",
    help: "Distilled facts: browse them, and the prompts enrich-facts runs.",
    commands: &[FACTS_LIST, FACTS_STATS],
    groups: &[&PROMPTS],
};

static PROMPTS: Group = Group {
    name: "prompts",
    help: "The effective fact prompts: the built-in default merged with facts.prompts.",
    commands: &[PROMPTS_LIST, PROMPTS_SHOW],
    groups: &[],
};

fn prompt_origin(prompt: &proto::FactPrompt) -> &'static str {
    match (prompt.builtin, prompt.customized) {
        (true, true) => "built-in, customized",
        (true, false) => "built-in",
        (false, _) => "configured",
    }
}

fn prompts(context: &mut Context) -> Result<Vec<proto::FactPrompt>, Failure> {
    Ok(context
        .backend()?
        .call(|mut client| async move { client.list_fact_prompts(proto::ListFactPromptsRequest {}).await })?
        .prompts)
}

/// `EffectivePrompt.to_config()`: the `facts.prompts` entry for the prompt.
fn prompt_config(prompt: &proto::FactPrompt) -> Value {
    json!({
        "name": prompt.name,
        "description": prompt.description,
        "examples": serde_json::from_str::<Value>(&prompt.examples_json).unwrap_or_else(|_| json!([])),
        "corpus_classes": prompt.corpus_classes,
        "sources": prompt.sources,
        "enabled": prompt.enabled,
    })
}

const PROMPTS_LIST: Command = Command {
    name: "list",
    opts: &[Opt::flag("json")],
    help: "List every fact prompt, enabled or not, with its scope and hash.",
    run: |context, parsed| {
        let prompts = prompts(context)?;
        if parsed.has("json") {
            let items: Vec<Value> = prompts
                .iter()
                .map(|p| {
                    let mut entry = prompt_config(p);
                    entry["builtin"] = json!(p.builtin);
                    entry["customized"] = json!(p.customized);
                    entry["sha256"] = json!(p.sha256);
                    entry
                })
                .collect();
            out::echo(&serde_json::to_string_pretty(&items).unwrap_or_default());
            return Ok(());
        }
        let mut table = Table::new(None);
        table.columns(&["name", "enabled", "origin", "scope", "examples", "sha256"]);
        for p in &prompts {
            let mut scope: Vec<String> = p.corpus_classes.clone();
            scope.extend(p.sources.iter().map(|s| format!("source:{s}")));
            let scope = if scope.is_empty() { "all documents".to_owned() } else { scope.join(", ") };
            let examples = serde_json::from_str::<Value>(&p.examples_json)
                .ok()
                .and_then(|v| v.as_array().map(Vec::len))
                .unwrap_or_default();
            table.row(&[
                p.name.clone(),
                if p.enabled { "yes".into() } else { "no".into() },
                prompt_origin(p).to_owned(),
                scope,
                examples.to_string(),
                p.sha256.chars().take(12).collect(),
            ]);
        }
        table.print();
        Ok(())
    },
};

const PROMPTS_SHOW: Command = Command {
    name: "show",
    opts: &[Opt::flag("json")],
    help: "Show one prompt in full: its instructions and few-shot examples.",
    run: |context, parsed| {
        let name = parsed.arg(0, "NAME").map_err(Failure::usage)?.to_owned();
        let Some(prompt) = prompts(context)?.into_iter().find(|p| p.name == name) else {
            return Err(Failure::failed(format!("[red]no fact prompt named {name:?}[/red]")));
        };
        if parsed.has("json") {
            out::echo(&serde_json::to_string_pretty(&prompt_config(&prompt)).unwrap_or_default());
            return Ok(());
        }
        let or_all = |items: &[String]| if items.is_empty() { "all".to_owned() } else { items.join(", ") };
        out::echo(&format!("name:     {} ({})", prompt.name, prompt_origin(&prompt)));
        out::echo(&format!("enabled:  {}", if prompt.enabled { "yes" } else { "no" }));
        out::echo(&format!("classes:  {}", or_all(&prompt.corpus_classes)));
        out::echo(&format!("sources:  {}", or_all(&prompt.sources)));
        out::echo(&format!("sha256:   {}", prompt.sha256));
        out::echo("");
        out::echo(&prompt.description);
        let examples = serde_json::from_str::<Value>(&prompt.examples_json).unwrap_or_else(|_| json!([]));
        for (number, example) in examples.as_array().into_iter().flatten().enumerate() {
            out::echo("");
            out::echo(&format!("Example {}: {}", number + 1, example["text"].as_str().unwrap_or_default()));
            for extraction in example["extractions"].as_array().into_iter().flatten() {
                let attributes = match extraction.get("attributes") {
                    Some(Value::Object(map)) if !map.is_empty() => format!(" {}", Value::Object(map.clone())),
                    _ => String::new(),
                };
                out::echo(&format!(
                    "  - [{}] {}{attributes}",
                    extraction["class"]
                        .as_str()
                        .or_else(|| extraction["extraction_class"].as_str())
                        .unwrap_or_default(),
                    extraction["text"].as_str().unwrap_or_default()
                ));
            }
        }
        Ok(())
    },
};

const FACT_FILTERS: [Opt; 5] = [
    Opt::short_value("query", 'q'),
    Opt::short_value("source", 's'),
    Opt::value("document-id"),
    Opt::value("class"),
    Opt::value("corpus-class"),
];

/// The grounded span itself, cut out of the excerpt around it (`_fact_evidence`).
fn evidence(fact: &proto::FactSummary) -> String {
    let (Some(start), Some(end)) = (fact.char_start, fact.char_end) else { return String::new() };
    if fact.excerpt.is_empty() {
        return String::new();
    }
    let from = usize::try_from(start - fact.excerpt_start).unwrap_or(0);
    let to = usize::try_from(end - fact.excerpt_start).unwrap_or(0);
    fact.excerpt.chars().skip(from).take(to.saturating_sub(from)).collect()
}

fn fact_json(f: &proto::FactSummary) -> Value {
    json!({
        "id": f.id, "document_id": f.document_id, "ord": f.ord, "fact": f.fact, "fact_class": f.fact_class,
        "attributes": serde_json::from_str::<Value>(&f.attributes_json).unwrap_or_else(|_| json!({})),
        "char_start": f.char_start, "char_end": f.char_end, "extractor": f.extractor,
        "extractor_model": f.extractor_model, "created_at": f.created_at, "document_title": f.document_title,
        "document_uri": f.document_uri, "source_slug": f.source_slug, "corpus_class": f.corpus_class,
        "excerpt": f.excerpt, "excerpt_start": f.excerpt_start, "distilled_fact_id": f.distilled_fact_id,
        "distilled_size": f.distilled_size, "distilled_statement": f.distilled_statement,
        "distilled_generated": f.distilled_generated, "distilled_spread": f.distilled_spread,
        "restates_fact_id": f.restates_fact_id, "evidence": evidence(f),
    })
}

const FACTS_LIST: Command = Command {
    name: "list",
    opts: &[
        FACT_FILTERS[0],
        FACT_FILTERS[1],
        FACT_FILTERS[2],
        FACT_FILTERS[3],
        FACT_FILTERS[4],
        Opt::value("limit"),
        Opt::value("offset"),
        Opt::flag("evidence"),
        Opt::flag("collapse"),
        Opt::value("distilled"),
        Opt::flag("json"),
    ],
    help: "List distilled facts, newest first (best match first with --query), with the document each came from.",
    run: |context, parsed| {
        let limit = parsed.int::<i32>("limit").map_err(Failure::usage)?.unwrap_or(50);
        let offset = parsed.int::<i32>("offset").map_err(Failure::usage)?.unwrap_or(0);
        let request = proto::ListFactsRequest {
            query: parsed.get("query").unwrap_or_default().to_owned(),
            source: parsed.get("source").unwrap_or_default().to_owned(),
            fact_class: parsed.get("class").unwrap_or_default().to_owned(),
            corpus_class: parsed.get("corpus-class").unwrap_or_default().to_owned(),
            document_id: parsed.int("document-id").map_err(Failure::usage)?.unwrap_or_default(),
            limit,
            offset,
            collapse: parsed.has("collapse"),
            distilled_fact_id: parsed.int("distilled").map_err(Failure::usage)?.unwrap_or_default(),
        };
        let page = context
            .backend()?
            .call(|mut client| async move { client.list_facts(request).await })
            .map_err(|failure| Failure::usage(format!("[red]{}[/red]", failure.message)))?;
        if parsed.has("json") {
            let payload = json!({
                "total": page.total_count, "limit": limit, "offset": offset,
                "facts": page.facts.iter().map(fact_json).collect::<Vec<_>>(),
            });
            out::echo(&serde_json::to_string_pretty(&payload).unwrap_or_default());
            return Ok(());
        }
        if page.facts.is_empty() {
            if page.total_count > 0 {
                out::print(&format!(
                    "[yellow]no facts past {} of {}[/yellow]",
                    commas(offset),
                    commas(page.total_count)
                ));
            } else {
                out::print("[yellow]no facts[/yellow] (run `garage enrich-facts` to distill some)");
            }
            return Ok(());
        }
        let shown = i64::try_from(page.facts.len()).unwrap_or(i64::MAX);
        let mut table = Table::new(Some(&format!(
            "facts {}-{} of {}",
            commas(i64::from(offset) + 1),
            commas(i64::from(offset) + shown),
            commas(page.total_count)
        )));
        table.columns(&["id", "class", "fact", "document", "source"]);
        for f in &page.facts {
            let mut text = f.fact.clone();
            if parsed.has("evidence") {
                let grounded = evidence(f);
                if !grounded.is_empty() {
                    text.push_str(&format!("\n[dim]“{grounded}”[/dim]"));
                }
            }
            if f.distilled_size > 1 {
                text.push_str(&format!(
                    "\n[cyan]distilled {} ({} facts): {}[/cyan]",
                    f.distilled_fact_id, f.distilled_size, f.distilled_statement
                ));
            }
            let document = if f.document_title.is_empty() { &f.document_uri } else { &f.document_title };
            table.row(&[f.id.to_string(), f.fact_class.clone(), text, document.clone(), f.source_slug.clone()]);
        }
        table.print();
        Ok(())
    },
};

const FACTS_STATS: Command = Command {
    name: "stats",
    opts: &[FACT_FILTERS[0], FACT_FILTERS[1], FACT_FILTERS[2], FACT_FILTERS[3], FACT_FILTERS[4], Opt::flag("json")],
    help: "Count facts per source and per extraction class.",
    run: |context, parsed| {
        let request = proto::FactStatsRequest {
            query: parsed.get("query").unwrap_or_default().to_owned(),
            source: parsed.get("source").unwrap_or_default().to_owned(),
            fact_class: parsed.get("class").unwrap_or_default().to_owned(),
            corpus_class: parsed.get("corpus-class").unwrap_or_default().to_owned(),
            document_id: parsed.int("document-id").map_err(Failure::usage)?.unwrap_or_default(),
        };
        let stats = context
            .backend()?
            .call(|mut client| async move { client.get_fact_stats(request).await })
            .map_err(|failure| Failure::usage(format!("[red]{}[/red]", failure.message)))?;
        if parsed.has("json") {
            let payload = json!({
                "facts": stats.facts, "documents": stats.documents, "by_source": stats.facts_by_source,
                "by_class": stats.facts_by_class, "distilled": stats.distilled, "clusters": stats.clusters,
                "clustered_facts": stats.clustered_facts, "message": stats.formatted_output,
            });
            out::echo(&serde_json::to_string_pretty(&payload).unwrap_or_default());
            return Ok(());
        }
        out::print(&stats.formatted_output);
        for (title, counts) in [("source", &stats.facts_by_source), ("class", &stats.facts_by_class)] {
            if counts.is_empty() {
                continue;
            }
            let mut table = Table::new(None);
            table.column(title, Justify::Left).column("facts", Justify::Right);
            let mut entries: Vec<(&String, &i64)> = counts.iter().collect();
            entries.sort_by(|a, b| b.1.cmp(a.1).then_with(|| a.0.cmp(b.0)));
            for (key, count) in entries {
                table.row(&[key.as_str(), &commas(*count)]);
            }
            table.print();
        }
        Ok(())
    },
};
