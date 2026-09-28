"""Registering this MCP server with client applications."""

from __future__ import annotations

import os
from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from garage_rag.config import ensure_psycopg_database_url, expand_home, get_settings
from garage_rag.mcp_server.install import (
    ClientTarget,
    app_launcher,
    client_targets,
    http_url,
    install,
    installed_in,
    plan_targets,
    server_command,
    uninstall,
)


@dataclass
class McpTargetOutcome:
    """What happened to one client config."""

    key: str
    label: str
    path: Path
    note: str = ""
    project_scoped: bool = False
    written: bool = False
    created_file: bool = False
    replaced_entry: bool = False
    backup: Path | None = None
    other_servers: list[str] = field(default_factory=list)
    preview: dict[str, Any] | None = None
    skipped: str | None = None
    declined: bool = False


@dataclass
class McpInstallReport:
    """How clients will reach the server, and the per-config outcomes."""

    server_name: str
    url: str | None
    command: str | None
    args: list[str]
    config_file: Path | None
    fell_back: bool
    outcomes: list[McpTargetOutcome]

    @property
    def lines(self) -> list[str]:
        out: list[str] = []
        if self.url:
            out.append(f"url: {self.url}")
        else:
            out.append(f"command: {self.command} {' '.join(self.args)}")
        for o in self.outcomes:
            if o.skipped:
                out.append(f"{o.label} -> {o.path}: {o.skipped}")
            elif o.written:
                verb = "created" if o.created_file else "updated"
                out.append(f"{verb} {o.path}" + (f" (backup {o.backup.name})" if o.backup else ""))
            elif o.preview is not None:
                out.append(f"{o.label} -> {o.path}: would write {self.server_name}")
        return out


def install_mcp_server(
    *,
    target: str = "project",
    path: Path | None = None,
    all_configs: bool = False,
    name: str = "garage-rag",
    stdio: bool = True,
    host: str | None = None,
    port: int | None = None,
    route: str | None = None,
    force: bool = False,
    dry_run: bool = False,
    confirm: Callable[[McpTargetOutcome], bool] | None = None,
) -> McpInstallReport:
    """Register this server in one client's config, a custom file, or every detected one.

    ``stdio`` (the default, as in the app) registers the `garage-mcp` command the
    client starts itself; ``stdio=False`` registers the URL of a running HTTP
    server. Existing configs are merged, backed up and written atomically.
    ``confirm`` is asked before each write; without it, writes go ahead. With one
    target, a refusal (entry exists without ``force``, malformed file) raises; with
    several, it is recorded and the rest continue.
    """
    plan = plan_targets(target, path=path, all_configs=all_configs)
    settings = get_settings()

    url: str | None = None
    command: str | None = None
    args: list[str] = []
    config_file: Path | None = None
    extra_env: dict[str, str] | None = None
    if stdio:
        config_file = settings.config_path
        command, args = server_command(config_file)
        # The app's launchers find the database themselves (password from the
        # Keychain); writing the URL would put that password in the client's config.
        if (database_url := os.environ.get("GARAGE_DATABASE_URL")) and app_launcher() is None:
            extra_env = {"GARAGE_DATABASE_URL": ensure_psycopg_database_url(database_url)}
    else:
        url = http_url(host or settings.mcp_host, port or settings.mcp_port, route or settings.mcp_http_path)

    outcomes: list[McpTargetOutcome] = []
    for chosen in plan.targets:
        outcome = McpTargetOutcome(
            key=chosen.key,
            label=chosen.label,
            path=chosen.path,
            note=chosen.note,
            project_scoped=chosen.project_scoped,
        )
        outcomes.append(outcome)
        kwargs: dict[str, Any] = {
            "server_name": name,
            "config_path": config_file,
            "extra_env": extra_env,
            "url": url,
            "force": force,
        }
        try:
            preview = install(chosen, dry_run=True, **kwargs)
        except (FileExistsError, RuntimeError) as exc:
            if not plan.multi:
                raise
            outcome.skipped = str(exc)
            continue
        outcome.other_servers = list(preview.other_servers)
        outcome.replaced_entry = preview.replaced_entry
        if dry_run:
            outcome.preview = {"mcpServers": {name: preview.entry}}
            continue
        if confirm is not None and not confirm(outcome):
            outcome.declined = True
            continue
        result = install(chosen, **kwargs)
        outcome.written = True
        outcome.created_file = result.created_file
        outcome.backup = result.backup

    return McpInstallReport(
        server_name=name,
        url=url,
        command=command,
        args=args,
        config_file=config_file,
        fell_back=plan.fell_back,
        outcomes=outcomes,
    )


def uninstall_mcp_server(
    *, target: str = "project", path: Path | None = None, name: str = "garage-rag"
) -> tuple[Path, bool]:
    """Remove this server from one client's config; ``(path, removed)``."""
    if path is not None:
        chosen = ClientTarget("custom", "custom path", expand_home(path).resolve())
    else:
        targets = client_targets()
        if target not in targets:
            raise ValueError(f"unknown target {target!r}")
        chosen = targets[target]
    return chosen.path, uninstall(chosen, server_name=name)


@dataclass
class McpClientStatus:
    key: str
    label: str
    path: Path
    registered: bool
    config_exists: bool


@dataclass
class McpStatus:
    command: str
    args: list[str]
    clients: list[McpClientStatus]

    @property
    def server_command(self) -> str:
        return f"{self.command} {' '.join(self.args)}".strip()


def mcp_status() -> McpStatus:
    """Which known clients have this server registered, and the stdio command they would run."""
    command, args = server_command()
    clients = [
        McpClientStatus(
            key=key,
            label=chosen.label,
            path=chosen.path,
            registered=installed_in(chosen),
            config_exists=chosen.path.is_file(),
        )
        for key, chosen in client_targets().items()
    ]
    return McpStatus(command=command, args=args, clients=clients)
