//! The commands, as `garage_rag.cli` declares them: the global options, the groups (`config`,
//! `graph`, `facts`, `facts prompts`) and the dispatch, with Typer's usage errors.

mod config;
mod facts;
mod mcp;
mod models;
mod query;
mod serve;
mod sources;

use std::path::PathBuf;

use crate::args::{Opt, Parsed, parse};
use crate::backend::{Backend, Failure, load_config};
use crate::out;

/// What every command runs with: the global options, and the backend once one is needed.
pub struct Context {
    pub verbose: bool,
    pub config_path: Option<PathBuf>,
    backend: Option<Backend>,
}

impl Context {
    /// The configuration, loaded as the service would load it.
    ///
    /// # Errors
    ///
    /// A file that does not load.
    pub fn config(&self) -> Result<garage_service::config::Config, Failure> {
        match &self.backend {
            Some(backend) => Ok(backend.config.clone()),
            None => load_config(self.config_path.as_deref()),
        }
    }

    /// GarageService in this process, started on first use.
    ///
    /// # Errors
    ///
    /// The configuration does not load, or the service does not start.
    pub fn backend(&mut self) -> Result<&Backend, Failure> {
        if self.backend.is_none() {
            let config = load_config(self.config_path.as_deref())?;
            self.backend = Some(Backend::start(config)?);
        }
        match &self.backend {
            Some(backend) => Ok(backend),
            None => Err(Failure::failed("GarageService did not start")),
        }
    }
}

type Handler = fn(&mut Context, &Parsed) -> Result<(), Failure>;

/// One command: its name, the options it takes, what it does, and its one-line help.
pub struct Command {
    pub name: &'static str,
    pub opts: &'static [Opt],
    pub run: Handler,
    pub help: &'static str,
}

/// A group of commands (`garage config …`).
pub struct Group {
    pub name: &'static str,
    pub help: &'static str,
    pub commands: &'static [Command],
    pub groups: &'static [&'static Group],
}

const GLOBAL: &[Opt] = &[Opt::short_flag("verbose", 'v'), Opt::short_value("config", 'c'), Opt::flag("help")];

static ROOT: Group = Group {
    name: "garage",
    help: "Local-first personal RAG pipeline over Postgres + pgvector.",
    commands: &[
        sources::SYNC,
        models::INIT_DB,
        models::STATS,
        models::REGISTER_MODEL,
        models::LIST_MODELS,
        models::SET_DEFAULT_MODEL,
        models::DROP_MODEL,
        sources::ADD_SOURCE,
        sources::REMOVE_SOURCE,
        sources::LIST_SOURCES,
        sources::SCAN,
        sources::INGEST,
        models::BACKFILL,
        facts::ENRICH_FACTS,
        facts::CLUSTER_FACTS,
        sources::RECONCILE,
        mcp::MCP_INSTALL,
        mcp::MCP_UNINSTALL,
        mcp::MCP_STATUS,
        mcp::MCP_TEST,
        mcp::MCP_SERVE,
        query::SEARCH,
        query::ASK,
        query::EXTRACT,
        VERSION,
        serve::SERVE,
    ],
    groups: &[&config::GROUP, &facts::GRAPH, &facts::FACTS],
};

const VERSION: Command = Command {
    name: "version",
    opts: &[],
    help: "Print the garage version.",
    run: |_, _| {
        out::print(&format!("garage v{}", garage_service::VERSION));
        Ok(())
    },
};

fn usage(group: &Group, path: &[&str]) -> String {
    let mut text = format!("Usage: {} [OPTIONS] COMMAND [ARGS]...\n\n  {}\n\nCommands:\n", path.join(" "), group.help);
    let width = group.commands.iter().map(|c| c.name.len()).chain(group.groups.iter().map(|g| g.name.len())).max();
    let width = width.unwrap_or(10);
    for command in group.commands {
        text.push_str(&format!("  {:width$}  {}\n", command.name, command.help));
    }
    for sub in group.groups {
        text.push_str(&format!("  {:width$}  {}\n", sub.name, sub.help));
    }
    text
}

/// Runs the command line; returns the exit code.
pub fn main(args: &[String]) -> i32 {
    // The global options come before the command, as Typer's callback takes them.
    let command_at = args.iter().position(|arg| !arg.starts_with('-') && arg != "-").map_or(args.len(), |at| {
        // `-c PATH`: the value after a value option is not the command.
        let mut i = 0;
        while i < at {
            if matches!(args[i].as_str(), "-c" | "--config") {
                i += 2;
                if i > at {
                    return at + 1;
                }
                continue;
            }
            i += 1;
        }
        at
    });
    let global = match parse(&args[..command_at.min(args.len())], GLOBAL) {
        Ok(global) => global,
        Err(message) => {
            out::eprint(&format!(
                "Usage: garage [OPTIONS] COMMAND [ARGS]...\nTry 'garage --help' for help.\n\nError: {message}"
            ));
            return 2;
        }
    };
    let rest = &args[command_at.min(args.len())..];
    if global.has("help") || rest.is_empty() {
        print!("{}", usage(&ROOT, &["garage"]));
        return i32::from(!global.has("help"));
    }
    let mut context =
        Context { verbose: global.has("verbose"), config_path: global.get("config").map(PathBuf::from), backend: None };
    // A leftover .env is worse than no .env: it looks like configuration and has no effect.
    if std::path::Path::new(".env").is_file() {
        out::print(&format!(
            "[yellow]note[/yellow]: .env is no longer read. Move its values into {} (see 'garage config init'), then delete it.",
            garage_service::config::CONFIG_FILENAME
        ));
    }
    let code = match dispatch(&ROOT, &mut vec!["garage".to_owned()], rest, &mut context) {
        Ok(()) => 0,
        Err(failure) => {
            if !failure.message.is_empty() {
                out::print(&failure.message);
            }
            failure.code
        }
    };
    drop(context);
    code
}

fn dispatch(group: &Group, path: &mut Vec<String>, args: &[String], context: &mut Context) -> Result<(), Failure> {
    let Some(name) = args.first() else {
        let names: Vec<&str> = path.iter().map(String::as_str).collect();
        print!("{}", usage(group, &names));
        return Err(Failure::silent(if path.len() > 1 { 2 } else { 0 }));
    };
    if name == "--help" || name == "-h" {
        let names: Vec<&str> = path.iter().map(String::as_str).collect();
        print!("{}", usage(group, &names));
        return Ok(());
    }
    if let Some(sub) = group.groups.iter().find(|g| g.name == name) {
        path.push(name.clone());
        return dispatch(sub, path, &args[1..], context);
    }
    let Some(command) = group.commands.iter().find(|c| c.name == name) else {
        let names: Vec<&str> = path.iter().map(String::as_str).collect();
        return Err(Failure::usage(format!(
            "Usage: {} [OPTIONS] COMMAND [ARGS]...\nTry '{} --help' for help.\n\nError: No such command '{name}'.",
            names.join(" "),
            names.join(" ")
        )));
    };
    if args[1..].iter().any(|arg| arg == "--help" || arg == "-h") {
        println!("Usage: {} {} [OPTIONS]\n\n  {}\n\nOptions:", path.join(" "), command.name, command.help);
        for opt in command.opts {
            let short = opt.short.map(|c| format!("-{c}, ")).unwrap_or_default();
            println!("  {short}--{}{}", opt.long, if opt.value { " VALUE" } else { "" });
        }
        return Ok(());
    }
    let parsed = parse(&args[1..], command.opts).map_err(|message| {
        Failure::usage(format!(
            "Usage: {} {} [OPTIONS]\nTry '{} {} --help' for help.\n\nError: {message}",
            path.join(" "),
            command.name,
            path.join(" "),
            command.name
        ))
    })?;
    (command.run)(context, &parsed)
}

/// Typer's `BadParameter` for `--option`: exit code 2 with its wording.
pub fn bad_parameter(option: &str, message: &str) -> Failure {
    Failure::usage(format!("Error: Invalid value for '{option}': {message}"))
}
