//! The schema and the embedding models: `init-db`, `stats`, `register-model`, `list-models`,
//! `set-default-model`, `drop-model` and `backfill`.

use garage_facade::proto;
use garage_service::db::redact_url;
use serde_json::json;

use super::{Command, Context};
use crate::args::Opt;
use crate::backend::Failure;
use crate::out::{self, Justify, Table, commas};

pub const INIT_DB: Command = Command {
    name: "init-db",
    opts: &[Opt::value("schema-dir")],
    help: "Apply the schema: extensions, enums, core tables, model registry.",
    run: |context, parsed| {
        let schema_dir = parsed.get("schema-dir").unwrap_or_default().to_owned();
        let backend = context.backend()?;
        let result =
            backend.call(|mut client| async move { client.init_db(proto::InitDbRequest { schema_dir }).await })?;
        for name in &result.applied {
            out::print(&format!("  applied [cyan]{name}[/cyan]"));
        }
        out::print(&format!("[green]schema ready[/green] ({})", redact_url(&backend.config.database_url())));
        Ok(())
    },
};

/// Every registered model (`ListModels`).
fn models(context: &mut Context) -> Result<Vec<proto::ModelInfo>, Failure> {
    Ok(context
        .backend()?
        .call(|mut client| async move { client.list_models(proto::ListModelsRequest {}).await })?
        .models)
}

pub const STATS: Command = Command {
    name: "stats",
    opts: &[],
    help: "Row counts across the corpus.",
    run: |context, _| {
        let stats =
            context.backend()?.call(|mut client| async move { client.get_stats(proto::StatsRequest {}).await })?;
        let models = models(context)?;
        let mut table = Table::new(Some("corpus"));
        table.column("table", Justify::Left).column("rows", Justify::Right);
        for (name, count) in [
            ("sources", stats.sources),
            ("documents", stats.documents),
            ("chunks", stats.chunks),
            ("embedding_models", stats.models),
        ] {
            table.row(&[name, &commas(count)]);
        }
        table.print();
        if !models.is_empty() {
            let mut mt = Table::new(Some("embedding models"));
            for col in ["slug", "dims", "storage", "index", "default", "vectors"] {
                mt.column(col, if matches!(col, "dims" | "vectors") { Justify::Right } else { Justify::Left });
            }
            for m in &models {
                let vectors = stats.chunks_by_model.get(&m.slug).copied().unwrap_or_default();
                mt.row(&[
                    m.slug.clone(),
                    m.dims.to_string(),
                    format!("{}({})", m.storage_kind, m.stored_dims),
                    m.index_kind.clone(),
                    if m.is_default { "yes".to_owned() } else { String::new() },
                    commas(vectors),
                ]);
            }
            mt.print();
        }
        Ok(())
    },
};

pub const REGISTER_MODEL: Command = Command {
    name: "register-model",
    opts: &[
        Opt::value("dims"),
        Opt::value("model-ref"),
        Opt::value("provider"),
        Opt::value("model-id"),
        Opt::value("distance"),
        Opt::value("modality"),
        Opt::flag("default"),
    ],
    help: "Register an embedding model and create its table and index.",
    run: |context, parsed| {
        let slug = parsed.arg(0, "SLUG").map_err(Failure::usage)?.to_owned();
        let request = proto::RegisterModelRequest {
            slug,
            dims: parsed.int::<i32>("dims").map_err(Failure::usage)?.unwrap_or_default(),
            model_ref: parsed.get("model-ref").unwrap_or_default().to_owned(),
            provider: parsed.get("provider").unwrap_or_default().to_owned(),
            model_id: parsed.get("model-id").unwrap_or_default().to_owned(),
            make_default: parsed.has("default"),
            distance: parsed.get("distance").unwrap_or_default().to_owned(),
            modality: parsed.get("modality").unwrap_or_default().to_owned(),
        };
        let result = context
            .backend()?
            .call(|mut client| async move { client.register_model(request).await })
            .map_err(|failure| Failure::usage(format!("[red]{}[/red]", failure.message)))?;
        let row = result.model.unwrap_or_default();
        out::print(&format!(
            "[green]registered[/green] {}{}: {}-dim -> {}({}), index={}, distance={}, table={}",
            row.slug,
            if row.modality == "image" { " (image model)" } else { "" },
            row.dims,
            row.storage_kind,
            row.stored_dims,
            row.index_kind,
            row.distance,
            row.table_name
        ));
        for note in &result.notes {
            out::print(&format!("  [yellow]note[/yellow]: {note}"));
        }
        Ok(())
    },
};

pub const LIST_MODELS: Command = Command {
    name: "list-models",
    opts: &[Opt::flag("json")],
    help: "List registered embedding models.",
    run: |context, parsed| {
        let rows = models(context)?;
        if parsed.has("json") {
            let items: Vec<serde_json::Value> = rows
                .iter()
                .map(|m| {
                    json!({
                        "slug": m.slug, "provider": m.provider, "model_ref": m.model_ref,
                        "model_id": if m.model_id.is_empty() { serde_json::Value::Null } else { json!(m.model_id) },
                        "dims": m.dims, "stored_dims": m.stored_dims, "storage_kind": m.storage_kind,
                        "index_kind": m.index_kind, "distance": m.distance, "modality": m.modality,
                        "table_name": m.table_name, "is_default": m.is_default,
                    })
                })
                .collect();
            println!("{}", serde_json::to_string_pretty(&items).unwrap_or_default());
            return Ok(());
        }
        if rows.is_empty() {
            out::print("[yellow]no models registered[/yellow]");
            return Ok(());
        }
        let mut table = Table::new(None);
        table.columns(&[
            "slug", "provider", "ref", "model_id", "dims", "stored", "storage", "index", "distance", "modality",
            "table", "default",
        ]);
        for m in &rows {
            table.row(&[
                m.slug.clone(),
                m.provider.clone(),
                m.model_ref.clone(),
                m.model_id.clone(),
                m.dims.to_string(),
                m.stored_dims.to_string(),
                m.storage_kind.clone(),
                m.index_kind.clone(),
                m.distance.clone(),
                m.modality.clone(),
                m.table_name.clone(),
                if m.is_default { "*".to_owned() } else { String::new() },
            ]);
        }
        table.print();
        Ok(())
    },
};

pub const SET_DEFAULT_MODEL: Command = Command {
    name: "set-default-model",
    opts: &[],
    help: "Point the default embedding model at SLUG.",
    run: |context, parsed| {
        let slug = parsed.arg(0, "SLUG").map_err(Failure::usage)?.to_owned();
        let request = proto::SetDefaultModelRequest { slug: slug.clone() };
        context.backend()?.call(|mut client| async move { client.set_default_model(request).await })?;
        out::print(&format!("[green]default model[/green] = {slug}"));
        Ok(())
    },
};

pub const DROP_MODEL: Command = Command {
    name: "drop-model",
    opts: &[Opt::flag("yes")],
    help: "Deregister a model and drop its vectors.",
    run: |context, parsed| {
        let slug = parsed.arg(0, "SLUG").map_err(Failure::usage)?.to_owned();
        if !parsed.has("yes") && !out::confirm(&format!("Drop model {slug} and discard all its vectors?")) {
            return Err(Failure::failed("Aborted."));
        }
        let request = proto::DropModelRequest { slug: slug.clone() };
        context.backend()?.call(|mut client| async move { client.drop_model(request).await })?;
        out::print(&format!("[green]dropped[/green] {slug}"));
        Ok(())
    },
};

pub const BACKFILL: Command = Command {
    name: "backfill",
    opts: &[
        Opt::short_value("model", 'm'),
        Opt::value("batch-size"),
        Opt::value("limit"),
        Opt::flag("verify"),
        Opt::flag("no-verify"),
    ],
    help: "Embed chunks that a model has no vectors for. Pure insert; safe to re-run.",
    run: |context, parsed| {
        let request = proto::BackfillRequest {
            model: parsed.get("model").unwrap_or_default().to_owned(),
            batch_size: parsed.int::<i32>("batch-size").map_err(Failure::usage)?.unwrap_or_default(),
            limit: parsed.int::<i32>("limit").map_err(Failure::usage)?.unwrap_or_default(),
            skip_verify: parsed.has("no-verify"),
        };
        let outcome = context.backend()?.stream(
            |mut client| async move { client.backfill(request).await },
            |event: proto::BackfillStatus| {
                let model = &event.model_slug;
                match event.phase.as_str() {
                    "complete" => out::print(&format!("[green]{model}[/green]: already complete")),
                    "skipped" => {
                        let prefix = format!("{model}: ");
                        let message = event.message.strip_prefix(&prefix).unwrap_or(&event.message);
                        out::print(&format!("[red]{model}[/red]: {message}"));
                    }
                    "started" => out::print(&format!("[cyan]{model}[/cyan]: embedding {} chunks", commas(event.total))),
                    "progress" => {
                        if !out::is_terminal() && event.batches % 10 == 0 {
                            out::print(&format!(
                                "{model}: {}/{} ({} batches)",
                                commas(event.embedded),
                                commas(event.total),
                                event.batches
                            ));
                        }
                    }
                    "finished" => {
                        let mut summary = format!("embedded {}", commas(event.embedded));
                        if event.failed > 0 {
                            summary.push_str(&format!(", [red]failed {}[/red]", commas(event.failed)));
                        }
                        if event.remaining > 0 {
                            summary.push_str(&format!(", remaining {}", commas(event.remaining)));
                        }
                        out::print(&format!("  {model}: {summary}"));
                    }
                    _ => {}
                }
                true
            },
        );
        outcome.map_err(|failure| {
            if failure.message == "no models registered" {
                Failure::failed("[yellow]no models registered[/yellow]")
            } else {
                failure
            }
        })
    },
};
