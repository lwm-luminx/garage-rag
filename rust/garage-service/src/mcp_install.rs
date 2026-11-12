//! Registering the MCP server in a client's configuration (`garage_rag.mcp_server.install`,
//! `ops.mcp`): `McpInstall`, `McpUninstall` and `McpStatus`.
//!
//! Every client that reads a JSON config uses the same envelope,
//! `{"mcpServers": {"<name>": {"command": ..., "args": [...]}}}`; they differ only in where the
//! file lives, so the client-specific part is a table and the merge is shared. These are files the
//! user owns, so the rules are: merge, never replace (Claude Desktop keeps `preferences` beside
//! `mcpServers`); back up first; write atomically.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde_json::{Map, Value, json};

use crate::config::{Config, ensure_psycopg_database_url, expand_home, temp_path};
use crate::error::{Result, ServiceError};
use crate::registrations::{TOKEN_ENV, TOKEN_PREFIX, mint_token};

pub const DEFAULT_SERVER_NAME: &str = "garage-rag";

/// `--target` values that mean every client config found on disk.
pub const MULTI_TARGETS: [&str; 2] = ["all", "any"];

/// Set by the macOS app's launchers, and by the app for its server, to the bundled `garage-mcp`.
pub const MCP_EXECUTABLE_ENV: &str = "GARAGE_MCP_EXECUTABLE";

/// Where one MCP client keeps its server configuration (`ClientTarget`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ClientTarget {
    pub key: String,
    pub label: String,
    pub path: PathBuf,
    /// Project-scoped files are usually committed.
    pub project_scoped: bool,
    pub note: String,
}

impl ClientTarget {
    fn new(key: &str, label: &str, path: PathBuf) -> Self {
        Self { key: key.to_owned(), label: label.to_owned(), path, project_scoped: false, note: String::new() }
    }

    fn project(key: &str, label: &str, path: PathBuf, note: &str) -> Self {
        Self { project_scoped: true, note: note.to_owned(), ..Self::new(key, label, path) }
    }
}

/// Where desktop apps keep per-user settings (`_app_support`): `%APPDATA%` on Windows, else
/// `~/Library/Application Support`.
fn app_support(home: &Path) -> PathBuf {
    if cfg!(windows) {
        std::env::var_os("APPDATA").map_or_else(|| home.join("AppData").join("Roaming"), PathBuf::from)
    } else {
        home.join("Library").join("Application Support")
    }
}

/// The known client config locations, in table order (`client_targets`). The home folder is the
/// account's, not a sandboxed process's container.
pub fn client_targets(project_dir: &Path) -> Vec<ClientTarget> {
    let home = expand_home(Path::new("~"));
    let project = std::fs::canonicalize(project_dir).unwrap_or_else(|_| project_dir.to_path_buf());
    let support = app_support(&home);
    let zed = if cfg!(windows) {
        support.join("Zed").join("settings.json")
    } else {
        home.join(".config").join("zed").join("settings.json")
    };
    let cline = |root: &str| {
        support
            .join(root)
            .join("User")
            .join("globalStorage")
            .join("saoudrizwan.claude-dev")
            .join("settings")
            .join("cline_mcp_settings.json")
    };
    vec![
        ClientTarget::project(
            "project",
            "Claude Code (this project)",
            project.join(".mcp.json"),
            "committed with the repo; shared with anyone who clones it",
        ),
        ClientTarget {
            note: "restart Claude Desktop to pick up changes".to_owned(),
            ..ClientTarget::new(
                "claude-desktop",
                "Claude Desktop",
                support.join("Claude").join("claude_desktop_config.json"),
            )
        },
        ClientTarget {
            note: "user-wide configuration for Claude Code".to_owned(),
            ..ClientTarget::new("claude-code-user", "Claude Code (global user config)", home.join(".claude.json"))
        },
        ClientTarget::new("lmstudio", "LM Studio", home.join(".lmstudio").join("mcp.json")),
        ClientTarget::new("cursor", "Cursor", home.join(".cursor").join("mcp.json")),
        ClientTarget::new("cursor-global", "Cursor (global extension settings)", cline("Cursor")),
        ClientTarget::project("vscode", "VS Code (this project)", project.join(".vscode").join("mcp.json"), ""),
        ClientTarget::new("vscode-global", "VS Code (global extension settings)", cline("Code")),
        ClientTarget::new("windsurf", "Windsurf", home.join(".codeium").join("windsurf").join("mcp_config.json")),
        ClientTarget::new("zed", "Zed", zed),
    ]
}

/// Which client configs an install touches (`TargetPlan`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TargetPlan {
    pub targets: Vec<ClientTarget>,
    /// Several configs are in play, so one that refuses is reported and skipped.
    pub multi: bool,
    /// A multi-target request found nothing on disk and fell back to the project file plus
    /// Claude Desktop.
    pub fell_back: bool,
}

/// `--target` / `--path` / `--all` resolved into the configs to write (`plan_targets`).
///
/// # Errors
///
/// A target that is not in the table.
pub fn plan_targets(target: &str, path: Option<&Path>, all_configs: bool, project_dir: &Path) -> Result<TargetPlan> {
    let table = client_targets(project_dir);
    if all_configs || MULTI_TARGETS.contains(&target) {
        let found: Vec<ClientTarget> = table.iter().filter(|t| t.path.is_file()).cloned().collect();
        if !found.is_empty() {
            return Ok(TargetPlan { targets: found, multi: true, fell_back: false });
        }
        let fallback = table.iter().filter(|t| t.key == "project" || t.key == "claude-desktop").cloned().collect();
        return Ok(TargetPlan { targets: fallback, multi: true, fell_back: true });
    }
    if let Some(path) = path {
        return Ok(TargetPlan { targets: vec![custom_target(path)], multi: false, fell_back: false });
    }
    let Some(chosen) = table.iter().find(|t| t.key == target) else {
        let choices: Vec<&str> = table.iter().map(|t| t.key.as_str()).chain(MULTI_TARGETS).collect();
        return Err(ServiceError::invalid(format!(
            "unknown target {}; choose from {}",
            garage_mcp::pyrepr::str_repr(target),
            choices.join(", ")
        )));
    };
    Ok(TargetPlan { targets: vec![chosen.clone()], multi: false, fell_back: false })
}

/// A config file named outright (`ClientTarget("custom", "custom path", path)`), resolved as
/// `Path.resolve()` does for one that exists.
fn custom_target(path: &Path) -> ClientTarget {
    let expanded = expand_home(path);
    let resolved = std::fs::canonicalize(&expanded).unwrap_or_else(|_| absolute(&expanded));
    ClientTarget::new("custom", "custom path", resolved)
}

fn absolute(path: &Path) -> PathBuf {
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        std::env::current_dir().map_or_else(|_| path.to_path_buf(), |cwd| cwd.join(path))
    }
}

fn executable(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}

/// The macOS app's bundled `garage-mcp`, when running under the app (`app_launcher`): it starts
/// the app and reads the database password from the Keychain, so a registration naming it needs
/// no environment.
pub fn app_launcher() -> Option<String> {
    let path = std::env::var(MCP_EXECUTABLE_ENV).ok().filter(|p| !p.is_empty())?;
    (Path::new(&path).is_absolute() && executable(Path::new(&path))).then_some(path)
}

/// The command an MCP client runs to start the server (`server_command`): the app's launcher,
/// else the `garage-mcp` beside this program, else `garage-mcp` from the client's `PATH`. A client
/// starts it from an arbitrary folder, so `--config` carries the absolute path.
pub fn server_command(config_path: Option<&Path>) -> (String, Vec<String>) {
    let args = config_path.map_or_else(Vec::new, |p| {
        let expanded = expand_home(p);
        let resolved = std::fs::canonicalize(&expanded).unwrap_or_else(|_| absolute(&expanded));
        vec!["--config".to_owned(), resolved.to_string_lossy().into_owned()]
    });
    if let Some(launcher) = app_launcher() {
        return (launcher, args);
    }
    if let Ok(exe) = std::env::current_exe() {
        let sibling = exe.with_file_name(if cfg!(windows) { "garage-mcp.exe" } else { "garage-mcp" });
        if executable(&sibling) {
            return (sibling.to_string_lossy().into_owned(), args);
        }
    }
    ("garage-mcp".to_owned(), args)
}

/// The URL a client connects to for the HTTP transport (`http_url`); an IPv6 literal is bracketed.
pub fn http_url(host: &str, port: i64, path: &str) -> String {
    let route = if path.starts_with('/') { path.to_owned() } else { format!("/{path}") };
    let authority = if host.contains(':') { format!("[{host}]") } else { host.to_owned() };
    format!("http://{authority}:{port}{route}")
}

/// What the server entry is built from.
#[derive(Clone, Debug, Default)]
pub struct EntrySpec {
    pub config_path: Option<PathBuf>,
    pub extra_env: BTreeMap<String, String>,
    pub url: Option<String>,
    /// The registration's token (`docs/plans/access-hooks.md`): `GARAGE_MCP_TOKEN` in a stdio
    /// entry's `env`, `Authorization: Bearer` in an HTTP entry's `headers`.
    pub token: Option<String>,
}

/// The JSON object describing this server (`server_entry`): a URL for the HTTP transport, else
/// the command the client spawns.
pub fn server_entry(spec: &EntrySpec) -> Value {
    if let Some(url) = &spec.url {
        let mut entry = json!({"type": "http", "url": url});
        if let Some(token) = &spec.token {
            entry["headers"] = json!({"Authorization": format!("Bearer {token}")});
        }
        return entry;
    }
    let (command, args) = server_command(spec.config_path.as_deref());
    let mut entry = Map::new();
    entry.insert("command".to_owned(), Value::String(command));
    entry.insert("args".to_owned(), json!(args));
    // In `env`, never in `args`, so the token does not show in `ps`.
    let mut env = spec.extra_env.clone();
    if let Some(token) = &spec.token {
        env.insert(TOKEN_ENV.to_owned(), token.clone());
    }
    if !env.is_empty() {
        entry.insert("env".to_owned(), json!(env));
    }
    Value::Object(entry)
}

/// The registration token an entry carries, if any: its `env`'s `GARAGE_MCP_TOKEN`, or the bearer
/// token in its `headers`.
pub fn entry_token(entry: &Value) -> Option<String> {
    let from_env = entry.get("env").and_then(|env| env.get(TOKEN_ENV)).and_then(Value::as_str);
    let from_header = || {
        let headers = entry.get("headers")?.as_object()?;
        let value = headers.iter().find(|(key, _)| key.eq_ignore_ascii_case("authorization"))?.1.as_str()?;
        value.strip_prefix("Bearer ").or_else(|| value.strip_prefix("bearer "))
    };
    from_env.or_else(from_header).filter(|token| token.starts_with(TOKEN_PREFIX)).map(str::to_owned)
}

/// The token of the entry `server_name` has in `target`'s config, if any.
pub fn existing_token(target: &ClientTarget, server_name: &str) -> Option<String> {
    let config = read_client_config(&target.path).ok()?;
    entry_token(config.get("mcpServers")?.get(server_name)?)
}

/// An existing client config, or an empty one (`_read_config`). A malformed file is an error, not
/// something to overwrite.
fn read_client_config(path: &Path) -> Result<Map<String, Value>> {
    if !path.is_file() {
        return Ok(Map::new());
    }
    let text = std::fs::read_to_string(path)
        .map_err(|e| ServiceError::failed(format!("cannot read {}: {e}", path.display())))?;
    if text.trim().is_empty() {
        return Ok(Map::new());
    }
    match serde_json::from_str(&text) {
        Ok(Value::Object(map)) => Ok(map),
        Ok(_) => Err(ServiceError::failed(format!("{} does not contain a JSON object", path.display()))),
        Err(e) => Err(ServiceError::failed(format!(
            "{} is not valid JSON ({e}); fix or move it before installing",
            path.display()
        ))),
    }
}

/// Copies `path` aside (`_backup`), or none when there is nothing to copy or nowhere to put it (a
/// sandboxed process granted only the file itself).
fn backup(path: &Path) -> Option<PathBuf> {
    if !path.is_file() {
        return None;
    }
    let stamp = chrono::Utc::now().format("%Y%m%d%H%M%S");
    let mut name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let _ = std::fmt::Write::write_fmt(&mut name, format_args!(".bak-{stamp}"));
    let backup = path.with_file_name(name);
    match std::fs::copy(path, &backup) {
        Ok(_) => Some(backup),
        Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => {
            eprintln!("cannot back up {} beside it ({e}); writing without a backup", path.display());
            None
        }
        Err(e) => {
            eprintln!("cannot back up {} ({e}); writing without a backup", path.display());
            None
        }
    }
}

/// Writes JSON through a temporary file beside `path`, then renames (`_write_atomic`); when the
/// temporary file cannot be created but `path` exists, it is rewritten in place.
fn write_atomic(path: &Path, data: &Map<String, Value>) -> Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| ServiceError::failed(format!("cannot create {}: {e}", parent.display())))?;
    }
    let mut payload = serde_json::to_string_pretty(&Value::Object(data.clone())).map_err(ServiceError::from)?;
    payload.push('\n');
    let temp = temp_path(path);
    match std::fs::write(&temp, &payload) {
        Ok(()) => std::fs::rename(&temp, path)
            .map_err(|e| ServiceError::failed(format!("cannot replace {}: {e}", path.display()))),
        Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied && path.is_file() => {
            eprintln!("cannot create {}; rewriting {} in place", temp.display(), path.display());
            std::fs::write(path, payload)
                .map_err(|e| ServiceError::failed(format!("cannot write {}: {e}", path.display())))
        }
        Err(e) => Err(ServiceError::failed(format!("cannot write {}: {e}", temp.display()))),
    }
}

/// One install's outcome (`InstallResult`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InstallResult {
    pub entry: Value,
    pub created_file: bool,
    pub replaced_entry: bool,
    pub backup: Option<PathBuf>,
    pub other_servers: Vec<String>,
}

/// Merges this server into `target`'s config (`install`).
///
/// # Errors
///
/// [`ServiceError::AlreadyExists`] when `server_name` is configured and `force` is not set; a
/// malformed file; the file system.
pub fn install(
    target: &ClientTarget,
    server_name: &str,
    spec: &EntrySpec,
    force: bool,
    dry_run: bool,
) -> Result<InstallResult> {
    let mut config = read_client_config(&target.path)?;
    let mut servers = match config.get("mcpServers") {
        None | Some(Value::Null) => Map::new(),
        Some(Value::Object(map)) => map.clone(),
        Some(_) => {
            return Err(ServiceError::failed(format!("{}: 'mcpServers' is not an object", target.path.display())));
        }
    };
    let replaced = servers.contains_key(server_name);
    if replaced && !force {
        return Err(ServiceError::AlreadyExists(format!(
            "{} is already configured in {}; pass --force to overwrite it",
            garage_mcp::pyrepr::str_repr(server_name),
            target.path.display()
        )));
    }
    let entry = server_entry(spec);
    let mut others: Vec<String> = servers.keys().filter(|k| k.as_str() != server_name).cloned().collect();
    others.sort();
    let mut result = InstallResult {
        entry: entry.clone(),
        created_file: !target.path.is_file(),
        replaced_entry: replaced,
        backup: None,
        other_servers: others,
    };
    if dry_run {
        return Ok(result);
    }
    result.backup = backup(&target.path);
    servers.insert(server_name.to_owned(), entry);
    config.insert("mcpServers".to_owned(), Value::Object(servers));
    write_atomic(&target.path, &config)?;
    Ok(result)
}

/// Removes this server from `target`'s config (`uninstall`): the removed entry, or `None` when it
/// was not there.
///
/// # Errors
///
/// A malformed file, or the file system.
pub fn uninstall(target: &ClientTarget, server_name: &str) -> Result<Option<Value>> {
    let mut config = read_client_config(&target.path)?;
    let Some(Value::Object(servers)) = config.get_mut("mcpServers") else { return Ok(None) };
    let Some(entry) = servers.remove(server_name) else { return Ok(None) };
    backup(&target.path);
    write_atomic(&target.path, &config)?;
    Ok(Some(entry))
}

/// Whether `target`'s config names the server (`installed_in`); a malformed file counts as no.
pub fn installed_in(target: &ClientTarget, server_name: &str) -> bool {
    read_client_config(&target.path)
        .ok()
        .and_then(|config| config.get("mcpServers").and_then(Value::as_object).map(|s| s.contains_key(server_name)))
        .unwrap_or(false)
}

/// What `McpInstall` was asked (`install_mcp_server`'s arguments).
#[derive(Clone, Debug)]
#[allow(clippy::struct_excessive_bools)] // the request's flags, as the proto has them
pub struct InstallRequest {
    pub target: String,
    pub path: Option<PathBuf>,
    pub all_configs: bool,
    pub name: String,
    pub stdio: bool,
    pub host: Option<String>,
    pub port: Option<i64>,
    pub route: Option<String>,
    pub force: bool,
    pub dry_run: bool,
}

/// What happened to one client config (`McpTargetOutcome`).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct TargetOutcome {
    pub key: String,
    pub label: String,
    pub path: PathBuf,
    pub written: bool,
    pub created_file: bool,
    pub replaced_entry: bool,
    pub backup: Option<PathBuf>,
    pub other_servers: Vec<String>,
    pub preview: Option<Value>,
    pub skipped: Option<String>,
    /// The registration token written into the entry (a new one, or the one a forced re-install
    /// found there), for the caller to record; never shown.
    pub token: Option<String>,
}

/// How clients will reach the server, and the per-config outcomes (`McpInstallReport`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InstallReport {
    pub server_name: String,
    pub url: Option<String>,
    pub command: Option<String>,
    pub args: Vec<String>,
    pub fell_back: bool,
    pub outcomes: Vec<TargetOutcome>,
}

impl InstallReport {
    /// The report, line by line.
    pub fn lines(&self) -> Vec<String> {
        let mut out = Vec::new();
        match &self.url {
            Some(url) => out.push(format!("url: {url}")),
            None => {
                out.push(format!("command: {} {}", self.command.as_deref().unwrap_or_default(), self.args.join(" ")));
            }
        }
        for o in &self.outcomes {
            if let Some(skipped) = &o.skipped {
                out.push(format!("{} -> {}: {skipped}", o.label, o.path.display()));
            } else if o.written {
                let verb = if o.created_file { "created" } else { "updated" };
                let backup = o
                    .backup
                    .as_ref()
                    .and_then(|b| b.file_name())
                    .map(|n| format!(" (backup {})", n.to_string_lossy()))
                    .unwrap_or_default();
                out.push(format!("{verb} {}{backup}", o.path.display()));
            } else if o.preview.is_some() {
                out.push(format!("{} -> {}: would write {}", o.label, o.path.display(), self.server_name));
            }
        }
        out
    }
}

/// Registers the server in one client's config, a custom file, or every detected one
/// (`install_mcp_server`). `stdio` registers the `garage-mcp` command; otherwise the URL of the
/// HTTP server `config` names. With several targets a refusal is recorded and the rest continue.
///
/// # Errors
///
/// An unknown target; with one target, a refusal (the entry exists without `force`, a malformed
/// file).
pub fn install_mcp_server(config: &Config, request: &InstallRequest) -> Result<InstallReport> {
    let project = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let plan = plan_targets(&request.target, request.path.as_deref(), request.all_configs, &project)?;
    let mut spec = EntrySpec::default();
    let (mut url, mut command, mut args) = (None, None, Vec::new());
    if request.stdio {
        spec.config_path.clone_from(&config.path);
        let (cmd, cmd_args) = server_command(spec.config_path.as_deref());
        command = Some(cmd);
        args = cmd_args;
        // The app's launchers find the database themselves (password from the Keychain); writing
        // the URL would put that password in the client's config.
        if let Ok(database_url) = std::env::var(crate::config::DATABASE_URL_ENV)
            && !database_url.is_empty()
            && app_launcher().is_none()
        {
            spec.extra_env
                .insert(crate::config::DATABASE_URL_ENV.to_owned(), ensure_psycopg_database_url(&database_url));
        }
    } else {
        let (host, port, route) = config.mcp_endpoint();
        let built = http_url(
            request.host.as_deref().unwrap_or(&host),
            request.port.unwrap_or(port),
            request.route.as_deref().unwrap_or(&route),
        );
        spec.url = Some(built.clone());
        url = Some(built);
    }
    let mut outcomes = Vec::new();
    for chosen in &plan.targets {
        let mut outcome = TargetOutcome {
            key: chosen.key.clone(),
            label: chosen.label.clone(),
            path: chosen.path.clone(),
            ..Default::default()
        };
        let preview = match install(chosen, &request.name, &spec, request.force, true) {
            Ok(preview) => preview,
            Err(e) if plan.multi => {
                outcome.skipped = Some(e.message().to_owned());
                outcomes.push(outcome);
                continue;
            }
            Err(e) => return Err(e),
        };
        outcome.other_servers = preview.other_servers;
        outcome.replaced_entry = preview.replaced_entry;
        if request.dry_run {
            outcome.preview = Some(json!({"mcpServers": {request.name.clone(): preview.entry}}));
            outcomes.push(outcome);
            continue;
        }
        // The entry's registration token: the one a forced re-install finds there, so the
        // registration keeps its id and its rules, else a new one. A dry run's preview has none.
        let token = match existing_token(chosen, &request.name) {
            Some(token) => token,
            None => mint_token()?,
        };
        let spec = EntrySpec { token: Some(token.clone()), ..spec.clone() };
        let result = install(chosen, &request.name, &spec, request.force, false)?;
        outcome.token = Some(token);
        outcome.written = true;
        outcome.created_file = result.created_file;
        outcome.backup = result.backup;
        outcomes.push(outcome);
    }
    Ok(InstallReport { server_name: request.name.clone(), url, command, args, fell_back: plan.fell_back, outcomes })
}

/// Removes the server from one client's config (`uninstall_mcp_server`): `(path, removed entry)`.
///
/// # Errors
///
/// An unknown target, a malformed file, or the file system.
pub fn uninstall_mcp_server(target: &str, path: Option<&Path>, name: &str) -> Result<(PathBuf, Option<Value>)> {
    let chosen = if let Some(path) = path {
        custom_target(path)
    } else {
        let project = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
        client_targets(&project)
            .into_iter()
            .find(|t| t.key == target)
            .ok_or_else(|| ServiceError::invalid(format!("unknown target {}", garage_mcp::pyrepr::str_repr(target))))?
    };
    let removed = uninstall(&chosen, name)?;
    Ok((chosen.path, removed))
}

/// One client in `McpStatus`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ClientStatus {
    pub key: String,
    pub label: String,
    pub path: PathBuf,
    pub registered: bool,
    pub config_exists: bool,
}

/// Which known clients have the server registered, and the command they would run
/// (`mcp_status`): `(server command, clients)`.
pub fn mcp_status() -> (String, Vec<ClientStatus>) {
    let (command, args) = server_command(None);
    let server_command = format!("{command} {}", args.join(" ")).trim().to_owned();
    let project = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let clients = client_targets(&project)
        .into_iter()
        .map(|t| ClientStatus {
            registered: installed_in(&t, DEFAULT_SERVER_NAME),
            config_exists: t.path.is_file(),
            key: t.key,
            label: t.label,
            path: t.path,
        })
        .collect();
    (server_command, clients)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("garage-mcp-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn targets_are_the_python_table() {
        let keys: Vec<String> = client_targets(Path::new("/tmp")).into_iter().map(|t| t.key).collect();
        assert_eq!(
            keys,
            [
                "project",
                "claude-desktop",
                "claude-code-user",
                "lmstudio",
                "cursor",
                "cursor-global",
                "vscode",
                "vscode-global",
                "windsurf",
                "zed"
            ]
        );
        let err = plan_targets("emacs", None, false, Path::new("/tmp")).unwrap_err();
        assert!(err.message().starts_with("unknown target 'emacs'; choose from project, claude-desktop"));
        assert!(err.message().ends_with("zed, all, any"));
        assert_eq!(http_url("::1", 8787, "mcp"), "http://[::1]:8787/mcp");
        assert_eq!(http_url("127.0.0.1", 8787, "/mcp"), "http://127.0.0.1:8787/mcp");
    }

    #[test]
    fn installs_merge_back_up_and_refuse_duplicates() {
        let dir = scratch("install");
        let path = dir.join("claude_desktop_config.json");
        std::fs::write(&path, r#"{"preferences": {"theme": "dark"}, "mcpServers": {"other": {"command": "x"}}}"#)
            .unwrap();
        let target = ClientTarget::new("custom", "custom path", path.clone());
        let spec = EntrySpec { url: Some("http://127.0.0.1:8787/mcp".into()), ..EntrySpec::default() };
        let result = install(&target, "garage-rag", &spec, false, false).unwrap();
        assert!(!result.created_file && !result.replaced_entry);
        assert_eq!(result.other_servers, vec!["other"]);
        assert!(result.backup.as_ref().unwrap().to_string_lossy().contains(".json.bak-"));
        let written: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(written["preferences"]["theme"], json!("dark"));
        assert_eq!(written["mcpServers"]["other"]["command"], json!("x"));
        assert_eq!(written["mcpServers"]["garage-rag"], json!({"type": "http", "url": "http://127.0.0.1:8787/mcp"}));
        let err = install(&target, "garage-rag", &spec, false, true).unwrap_err();
        assert!(matches!(err, ServiceError::AlreadyExists(_)));
        assert!(err.message().starts_with("'garage-rag' is already configured in "));
        assert!(install(&target, "garage-rag", &spec, true, true).unwrap().replaced_entry);
        assert!(installed_in(&target, "garage-rag"));
        assert!(uninstall(&target, "garage-rag").unwrap().is_some());
        assert!(uninstall(&target, "garage-rag").unwrap().is_none());
        assert!(!installed_in(&target, "garage-rag"));
        std::fs::write(&path, "{not json").unwrap();
        assert!(
            install(&target, "garage-rag", &spec, false, true).unwrap_err().message().contains("is not valid JSON")
        );
        assert!(!installed_in(&target, "garage-rag"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_http_entry_carries_its_token_as_a_bearer_header() {
        let spec = EntrySpec {
            url: Some("http://127.0.0.1:8787/mcp".into()),
            token: Some("gmr_xyz".into()),
            ..Default::default()
        };
        let entry = server_entry(&spec);
        assert_eq!(entry["headers"]["Authorization"], json!("Bearer gmr_xyz"));
        assert_eq!(entry_token(&entry).as_deref(), Some("gmr_xyz"));
        // Only Garage's own tokens are taken for one.
        assert_eq!(entry_token(&json!({"headers": {"authorization": "Bearer someone-elses"}})), None);
        assert_eq!(entry_token(&json!({"type": "http", "url": "http://x"})), None);
    }

    #[test]
    fn a_new_file_is_created_with_the_stdio_entry() {
        let dir = scratch("new");
        let path = dir.join("deep").join(".mcp.json");
        let target = ClientTarget::new("project", "Claude Code (this project)", path.clone());
        let spec = EntrySpec {
            config_path: Some(dir.join("garage.json")),
            extra_env: BTreeMap::from([("GARAGE_DATABASE_URL".to_owned(), "postgresql+psycopg:///g".to_owned())]),
            url: None,
            token: Some("gmr_abc".to_owned()),
        };
        let result = install(&target, "garage-rag", &spec, false, false).unwrap();
        assert!(result.created_file && result.backup.is_none());
        let written: Value = serde_json::from_str(&std::fs::read_to_string(&path).unwrap()).unwrap();
        let entry = &written["mcpServers"]["garage-rag"];
        assert_eq!(entry["args"][0], json!("--config"));
        assert!(entry["args"][1].as_str().unwrap().ends_with("garage.json"));
        assert_eq!(entry["env"]["GARAGE_DATABASE_URL"], json!("postgresql+psycopg:///g"));
        assert_eq!(entry["env"]["GARAGE_MCP_TOKEN"], json!("gmr_abc"));
        assert_eq!(entry.as_object().unwrap().keys().collect::<Vec<_>>(), ["command", "args", "env"]);
        assert_eq!(entry_token(entry).as_deref(), Some("gmr_abc"));
        assert_eq!(existing_token(&target, "garage-rag").as_deref(), Some("gmr_abc"));
        let report = InstallReport {
            server_name: "garage-rag".into(),
            url: None,
            command: Some("garage-mcp".into()),
            args: vec!["--config".into(), "/c.json".into()],
            fell_back: false,
            outcomes: vec![TargetOutcome {
                label: "Claude Code (this project)".into(),
                path: path.clone(),
                written: true,
                created_file: true,
                ..Default::default()
            }],
        };
        assert_eq!(
            report.lines(),
            vec!["command: garage-mcp --config /c.json".to_owned(), format!("created {}", path.display())]
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
