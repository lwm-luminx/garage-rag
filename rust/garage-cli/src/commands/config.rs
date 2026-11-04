//! `garage config …`: the configuration file (`config_app`).

use std::path::PathBuf;

use garage_facade::proto;
use garage_service::config::{
    CONFIG_FILENAME, Config, SCHEMA_URL, SECTIONS, candidate_paths, default_config_path, expand_home, resolve_setting,
    save_config,
};
use serde_json::Value;

use super::{Command, Group};
use crate::args::Opt;
use crate::backend::Failure;
use crate::out;

pub static GROUP: Group = Group {
    name: "config",
    help: "Inspect and create the configuration file.",
    commands: &[INIT, IMPORT_SOURCES, SHOW, PATH, GET, SET, SCHEMA],
    groups: &[],
};

/// Strings print bare; everything else as JSON, so `true`/`42`/`["a","b"]` parse unambiguously.
fn format_setting(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        other => other.to_string(),
    }
}

const INIT: Command = Command {
    name: "init",
    opts: &[Opt::value("path"), Opt::flag("user"), Opt::flag("force")],
    help: "Write a configuration file with every setting at its default.",
    run: |_, parsed| {
        let target = match parsed.get("path") {
            Some(path) => PathBuf::from(path),
            None if parsed.has("user") => default_config_path(),
            None => std::env::current_dir().unwrap_or_default().join(CONFIG_FILENAME),
        };
        let target = expand_home(&target);
        if target.exists() && !parsed.has("force") {
            return Err(Failure::failed(format!(
                "[yellow]{} already exists[/yellow]; pass --force to overwrite",
                target.display()
            )));
        }
        let settings = Config::default();
        save_config(&settings, &target)?;
        out::print(&format!("[green]wrote[/green] {}", target.display()));
        // No schema file is written beside the config: `$schema` names the published URL.
        out::print(&format!("  [dim]$schema -> {SCHEMA_URL}[/dim]"));
        if settings.self_name().is_empty() {
            out::print(
                "\n[yellow]next[/yellow]: set [cyan]identity.name[/cyan] and [cyan]identity.identities[/cyan] so your own writing can be told apart from reference material",
            );
        }
        Ok(())
    },
};

const IMPORT_SOURCES: Command = Command {
    name: "import-sources",
    opts: &[Opt::value("path")],
    help: "Copy the database's sources into the config file.",
    run: |context, parsed| {
        let path = parsed.get("path").unwrap_or_default().to_owned();
        let reply = context.backend()?.call(|mut client| async move {
            client.import_sources_to_config(proto::ImportSourcesToConfigRequest { path }).await
        })?;
        if reply.added.is_empty() {
            out::print("[green]config already lists every database source[/green]");
            return Ok(());
        }
        out::print(&format!("[green]added {} sources[/green] to {}", reply.added.len(), reply.path));
        for slug in &reply.added {
            out::print(&format!("  {slug}"));
        }
        Ok(())
    },
};

const SHOW: Command = Command {
    name: "show",
    opts: &[Opt::flag("defaults"), Opt::flag("diff")],
    help: "Print the effective configuration.",
    run: |context, parsed| {
        let config = context.config()?;
        let origin =
            config.path.as_ref().map_or_else(|| "(defaults; no file found)".to_owned(), |p| p.display().to_string());
        out::print(&format!("[dim]loaded from: {origin}[/dim]"));
        let document = if parsed.has("diff") { overrides(&config) } else { config.nest() };
        println!("{}", serde_json::to_string_pretty(&document).unwrap_or_default());
        Ok(())
    },
};

/// `nest(settings, include_defaults=False)`: only the values that differ from the defaults, by
/// section, plus the sources.
fn overrides(config: &Config) -> Value {
    let mut document = serde_json::Map::new();
    for setting in SECTIONS {
        let value = config.field(setting.field);
        if value == setting.default_value() {
            continue;
        }
        document
            .entry(setting.section.to_owned())
            .or_insert_with(|| Value::Object(serde_json::Map::new()))
            .as_object_mut()
            .expect("an object")
            .insert(setting.key.to_owned(), value);
    }
    if !config.sources.is_empty() {
        document.insert("sources".to_owned(), Value::Array(config.sources.clone()));
    }
    Value::Object(document)
}

const PATH: Command = Command {
    name: "path",
    opts: &[],
    help: "Show which config file is in use, and the search order.",
    run: |context, _| {
        let config = context.config()?;
        let in_use =
            config.path.as_ref().map_or_else(|| "[yellow](none)[/yellow]".to_owned(), |p| p.display().to_string());
        out::print(&format!("in use : {in_use}"));
        out::print("search order:");
        for candidate in candidate_paths() {
            let mark = if candidate.is_file() { "[green]found[/green]" } else { "[dim]absent[/dim]" };
            out::print(&format!("  {mark}  {}", candidate.display()));
        }
        Ok(())
    },
};

const GET: Command = Command {
    name: "get",
    opts: &[],
    help: "Print one effective setting (after --config and environment overrides).",
    run: |context, parsed| {
        let name = parsed.arg(0, "SECTION.KEY").map_err(Failure::usage)?;
        let setting = resolve_setting(name).map_err(|e| Failure::usage(format!("[red]{e}[/red]")))?;
        let config = context.config()?;
        // Plain output, not the console: a long URL must not be wrapped at the terminal width.
        out::echo(&format_setting(&config.field(setting.field)));
        Ok(())
    },
};

const SET: Command = Command {
    name: "set",
    opts: &[Opt::value("path")],
    help: "Change one setting in the config file, validating it before writing.",
    run: |context, parsed| {
        let name = parsed.arg(0, "SECTION.KEY").map_err(Failure::usage)?.to_owned();
        let value = parsed.arg(1, "VALUE").map_err(Failure::usage)?.to_owned();
        let path = parsed.get("path").unwrap_or_default().to_owned();
        let shown = name.clone();
        let reply = context
            .backend()?
            .call(|mut client| async move { client.set_setting(proto::SetSettingRequest { name, value, path }).await })
            .map_err(|failure| {
                let mut message = format!("[red]{}[/red]", failure.message);
                if failure.message.contains("unknown") || failure.message.contains("expected SECTION.KEY") {
                    let names: Vec<String> = SECTIONS.iter().map(garage_service::config::Setting::name).collect();
                    message.push_str(&format!("\n[dim]valid keys:[/dim] {}", names.join(", ")));
                }
                Failure::usage(message)
            })?;
        let stored: Value = serde_json::from_str(&reply.value_json).unwrap_or(Value::Null);
        // stdout is exactly the assignment, for callers that parse it; the note goes to stderr.
        out::echo(&format!("{shown} = {}", format_setting(&stored)));
        eprintln!("wrote {}", reply.path);
        Ok(())
    },
};

const SCHEMA: Command = Command {
    name: "schema",
    opts: &[Opt::value("path"), Opt::flag("publish")],
    help: "Emit the JSON Schema describing the config file.",
    run: |_, _| {
        Err(Failure::usage(format!(
            "[red]config schema is not available in this build[/red]: the schema is generated by the Python package \
             and published at {SCHEMA_URL}"
        )))
    },
};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn settings_print_bare_strings_and_json_for_the_rest() {
        assert_eq!(format_setting(&Value::String("a b".into())), "a b");
        assert_eq!(format_setting(&serde_json::json!(true)), "true");
        assert_eq!(format_setting(&serde_json::json!(["a", "b"])), "[\"a\",\"b\"]");
        assert_eq!(overrides(&Config::default()), serde_json::json!({}));
    }

    #[test]
    fn the_user_config_lives_in_the_home_folder() {
        assert!(default_config_path().ends_with(garage_service::config::USER_CONFIG_FILENAME));
    }
}
