"""Registering the server in a client config.

These write to files the user owns and did not ask us to rewrite, so the
non-negotiable behaviours are: merge rather than replace, never silently
overwrite an existing entry, and never leave a truncated file behind.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest
from typer.testing import CliRunner

from garage_rag.cli import app
from garage_rag.mcp_server.install import (
    MCP_EXECUTABLE_ENV,
    MULTI_TARGETS,
    ClientTarget,
    client_targets,
    find_existing_configs,
    install,
    installed_in,
    plan_targets,
    server_command,
    server_entry,
    target_keys,
    uninstall,
)


@pytest.fixture
def target(tmp_path: Path) -> ClientTarget:
    return ClientTarget(key="test", label="test client", path=tmp_path / "mcp.json")


def _read(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


class TestCliInstall:
    def test_cli_defaults_to_stdio(self, tmp_path: Path) -> None:
        """Like the app's McpInstall: the HTTP server is off until the user starts it."""
        target_path = tmp_path / "mcp.json"
        result = CliRunner().invoke(app, ["mcp-install", "--path", str(target_path), "--yes"])
        assert result.exit_code == 0, result.output
        entry = _read(target_path)["mcpServers"]["garage-rag"]
        assert "command" in entry
        assert "url" not in entry

    def test_cli_http_flag_registers_a_url(self, tmp_path: Path) -> None:
        target_path = tmp_path / "mcp.json"
        result = CliRunner().invoke(app, ["mcp-install", "--path", str(target_path), "--http", "--yes"])
        assert result.exit_code == 0, result.output
        entry = _read(target_path)["mcpServers"]["garage-rag"]
        assert entry["type"] == "http"
        assert entry["url"] == "http://127.0.0.1:8787/mcp"

    def test_cli_stdio_flag(self, tmp_path: Path) -> None:
        target_path = tmp_path / "mcp.json"
        result = CliRunner().invoke(app, ["mcp-install", "--path", str(target_path), "--stdio", "--yes"])
        assert result.exit_code == 0, result.output
        entry = _read(target_path)["mcpServers"]["garage-rag"]
        assert "command" in entry

    def test_cli_conflicting_flags(self, tmp_path: Path) -> None:
        target_path = tmp_path / "mcp.json"
        result = CliRunner().invoke(app, ["mcp-install", "--path", str(target_path), "--http", "--stdio", "--yes"])
        assert result.exit_code != 0
        assert "choose either --http or --stdio" in result.output

    def test_passes_database_url_to_spawned_mcp_server(self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
        target_path = tmp_path / "mcp.json"
        database_url = "postgresql+psycopg://user:password@localhost:14824/garage-rag"
        monkeypatch.setenv("GARAGE_DATABASE_URL", database_url)

        result = CliRunner().invoke(app, ["mcp-install", "--path", str(target_path), "--stdio", "--yes"])

        assert result.exit_code == 0, result.output
        entry = _read(target_path)["mcpServers"]["garage-rag"]
        assert entry["env"]["GARAGE_DATABASE_URL"] == database_url

    def test_app_launcher_registration_carries_no_database_url(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        """The app's launchers read the password from the Keychain; the URL (password
        included) must not be copied into a client's config file."""
        launcher = tmp_path / "garage-mcp"
        launcher.write_text("#!/bin/sh\n")
        launcher.chmod(0o755)
        monkeypatch.setenv(MCP_EXECUTABLE_ENV, str(launcher))
        monkeypatch.setenv("GARAGE_DATABASE_URL", "postgresql+psycopg://user:secret@localhost:14824/garage-rag")
        target_path = tmp_path / "mcp.json"

        result = CliRunner().invoke(app, ["mcp-install", "--path", str(target_path), "--stdio", "--yes"])

        assert result.exit_code == 0, result.output
        entry = _read(target_path)["mcpServers"]["garage-rag"]
        assert entry["command"] == str(launcher)
        assert "env" not in entry
        assert "secret" not in target_path.read_text()


class TestServerCommand:
    def test_uses_unresolved_sys_executable(self) -> None:
        """Regression: resolving sys.executable escapes the virtualenv.

        Inside a venv, sys.executable is already correct. Following the symlink
        lands on the base interpreter, which has none of this project's packages
        and dies with ModuleNotFoundError when a client launches it.
        """
        command, _args = server_command()
        venv_dir = Path(sys.executable).parent
        assert Path(command).parent == venv_dir

    def test_command_is_absolute(self) -> None:
        """A client launches with its own PATH, which excludes this venv."""
        command, _ = server_command()
        assert Path(command).is_absolute()

    def test_command_is_the_stdio_entry_point(self) -> None:
        """`garage-mcp` is the one stdio entry point, never the `garage` CLI."""
        command, args = server_command()
        if Path(command).name == "garage-mcp":
            assert args == []
        else:
            assert args == ["-m", "garage_rag.mcp_server.server"]
        assert "mcp-serve" not in args

    def test_config_path_is_passed_absolutely(self, tmp_path: Path) -> None:
        """A client launches from an arbitrary cwd, where the config search
        order would find nothing -- so the path must be explicit and absolute."""
        cfg = tmp_path / "garage.json"
        cfg.write_text("{}")
        _command, args = server_command(cfg)
        assert args[-2:] == ["--config", str(cfg.resolve())]
        assert Path(args[-1]).is_absolute()

    def test_bundled_garage_mcp_wins_when_exported(self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
        """In the app, sys.executable is an interpreter the bundle does not ship;
        the Swift launcher exports the bundled `garage-mcp`, which clients must run."""
        launcher = tmp_path / "garage-mcp"
        launcher.write_text("#!/bin/sh\n")
        launcher.chmod(0o755)
        monkeypatch.setenv(MCP_EXECUTABLE_ENV, str(launcher))
        cfg = tmp_path / "garage.json"
        cfg.write_text("{}")
        command, args = server_command(cfg)
        assert command == str(launcher)
        assert args == ["--config", str(cfg.resolve())]

    @pytest.mark.skipif(sys.platform == "win32", reason="Windows has no executable bit: X_OK is true for any file")
    def test_non_executable_launcher_is_ignored(self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
        launcher = tmp_path / "garage-mcp"
        launcher.write_text("")
        launcher.chmod(0o644)
        monkeypatch.setenv(MCP_EXECUTABLE_ENV, str(launcher))
        command, _ = server_command()
        assert command != str(launcher)


class TestServerEntry:
    def test_references_config_by_path(self, tmp_path: Path) -> None:
        cfg = tmp_path / "garage.json"
        cfg.write_text("{}")
        entry = server_entry(config_path=cfg)
        assert "--config" in entry["args"]
        # Referenced, not copied: editing the config takes effect without
        # re-running mcp-install.
        assert str(cfg.resolve()) in entry["args"]

    def test_no_env_needed_at_all(self, tmp_path: Path) -> None:
        """The whole point of the config file: the server needs no environment."""
        cfg = tmp_path / "garage.json"
        cfg.write_text("{}")
        assert "env" not in server_entry(config_path=cfg)
        assert "env" not in server_entry()

    def test_extra_env_still_possible_if_requested(self) -> None:
        entry = server_entry(extra_env={"FOO": "bar"})
        assert entry["env"] == {"FOO": "bar"}

    def test_database_url_can_be_passed_to_the_spawned_server(self) -> None:
        entry = server_entry(extra_env={"GARAGE_DATABASE_URL": "postgresql+psycopg://user:password@localhost/db"})
        assert entry["env"]["GARAGE_DATABASE_URL"].endswith("@localhost/db")


class TestInstallMerge:
    def test_creates_file_when_absent(self, target: ClientTarget) -> None:
        result = install(target)
        assert result.created_file
        assert _read(target.path)["mcpServers"]["garage-rag"]["command"]

    def test_preserves_other_servers(self, target: ClientTarget) -> None:
        target.path.write_text(json.dumps({"mcpServers": {"other": {"command": "/bin/true", "args": []}}}))
        install(target)
        servers = _read(target.path)["mcpServers"]
        assert set(servers) == {"other", "garage-rag"}
        assert servers["other"]["command"] == "/bin/true"

    def test_preserves_unrelated_top_level_keys(self, target: ClientTarget) -> None:
        """Claude Desktop keeps `preferences` in this file; losing it is real damage."""
        target.path.write_text(json.dumps({"preferences": {"theme": "dark"}, "coworkUserFilesPath": "/x"}))
        install(target)
        data = _read(target.path)
        assert data["preferences"] == {"theme": "dark"}
        assert data["coworkUserFilesPath"] == "/x"
        assert "garage-rag" in data["mcpServers"]

    def test_refuses_to_overwrite_without_force(self, target: ClientTarget) -> None:
        install(target)
        with pytest.raises(FileExistsError, match="already configured"):
            install(target)

    def test_force_overwrites_and_backs_up(self, target: ClientTarget) -> None:
        target.path.write_text(json.dumps({"mcpServers": {"garage-rag": {"command": "stale", "args": []}}}))
        result = install(target, force=True)
        assert result.replaced_entry
        assert result.backup is not None and result.backup.is_file()
        assert _read(target.path)["mcpServers"]["garage-rag"]["command"] != "stale"
        # The backup still holds the old value.
        assert _read(result.backup)["mcpServers"]["garage-rag"]["command"] == "stale"

    def test_dry_run_changes_nothing(self, target: ClientTarget) -> None:
        result = install(target, dry_run=True)
        assert result.dry_run
        assert not target.path.exists()

    def test_dry_run_reports_servers_it_would_preserve(self, target: ClientTarget) -> None:
        target.path.write_text(json.dumps({"mcpServers": {"a": {}, "b": {}}}))
        result = install(target, dry_run=True)
        assert result.other_servers == ["a", "b"]

    def test_custom_server_name(self, target: ClientTarget) -> None:
        install(target, server_name="corpus")
        assert "corpus" in _read(target.path)["mcpServers"]

    def test_malformed_json_is_an_error_not_an_overwrite(self, target: ClientTarget) -> None:
        """A hand-edited file may be worth preserving; do not clobber it."""
        target.path.write_text("{ this is not json")
        with pytest.raises(RuntimeError, match="not valid JSON"):
            install(target)
        assert target.path.read_text() == "{ this is not json"

    def test_empty_file_is_treated_as_empty_config(self, target: ClientTarget) -> None:
        target.path.write_text("   \n")
        install(target)
        assert "garage-rag" in _read(target.path)["mcpServers"]

    def test_non_object_mcpservers_is_rejected(self, target: ClientTarget) -> None:
        target.path.write_text(json.dumps({"mcpServers": ["nope"]}))
        with pytest.raises(RuntimeError, match="not an object"):
            install(target)

    def test_creates_parent_directories(self, tmp_path: Path) -> None:
        nested = ClientTarget("t", "t", tmp_path / "a" / "b" / "mcp.json")
        install(nested)
        assert nested.path.is_file()

    def test_output_is_valid_indented_json(self, target: ClientTarget) -> None:
        install(target)
        text = target.path.read_text()
        assert text.endswith("\n")
        assert "\n  " in text  # indented, so it stays hand-editable
        json.loads(text)

    def test_no_temp_file_left_behind(self, target: ClientTarget) -> None:
        install(target)
        assert not list(target.path.parent.glob("*.tmp"))

    def test_single_file_grant_rewrites_in_place(self, target: ClientTarget, monkeypatch: pytest.MonkeyPatch) -> None:
        """A sandboxed service granted only the chosen file cannot create siblings, but can still register."""
        target.path.write_text(json.dumps({"preferences": {"x": 1}, "mcpServers": {"other": {}}}))
        real_write_text = Path.write_text

        def no_siblings(self: Path, *args, **kwargs):
            if self != target.path:
                raise PermissionError(1, "Operation not permitted", str(self))
            return real_write_text(self, *args, **kwargs)

        def no_copy(src, dst, *args, **kwargs):
            raise PermissionError(1, "Operation not permitted", str(dst))

        monkeypatch.setattr(Path, "write_text", no_siblings)
        monkeypatch.setattr("garage_rag.mcp_server.install.shutil.copy2", no_copy)
        result = install(target, force=True)
        assert result.backup is None
        data = _read(target.path)
        assert data["preferences"] == {"x": 1}
        assert set(data["mcpServers"]) == {"other", "garage-rag"}
        assert [p.name for p in target.path.parent.iterdir()] == [target.path.name]

    def test_missing_file_without_directory_access_is_still_an_error(
        self, target: ClientTarget, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        def denied(self: Path, *args, **kwargs):
            raise PermissionError(1, "Operation not permitted", str(self))

        monkeypatch.setattr(Path, "write_text", denied)
        with pytest.raises(PermissionError):
            install(target)


class TestUninstall:
    def test_removes_only_our_entry(self, target: ClientTarget) -> None:
        target.path.write_text(json.dumps({"mcpServers": {"other": {"command": "x"}}}))
        install(target)
        assert uninstall(target)
        servers = _read(target.path)["mcpServers"]
        assert set(servers) == {"other"}

    def test_returns_false_when_absent(self, target: ClientTarget) -> None:
        target.path.write_text(json.dumps({"mcpServers": {}}))
        assert not uninstall(target)

    def test_missing_file_is_not_an_error(self, target: ClientTarget) -> None:
        assert not uninstall(target)

    def test_installed_in_roundtrip(self, target: ClientTarget) -> None:
        assert not installed_in(target)
        install(target)
        assert installed_in(target)
        uninstall(target)
        assert not installed_in(target)


class TestClientTargets:
    def test_known_targets_present(self) -> None:
        keys = set(client_targets())
        assert {"project", "claude-desktop", "lmstudio", "cursor", "vscode"} <= keys

    def test_project_target_is_scoped_to_the_given_directory(self, tmp_path: Path) -> None:
        targets = client_targets(project_dir=tmp_path)
        assert targets["project"].path == tmp_path.resolve() / ".mcp.json"
        assert targets["project"].project_scoped

    def test_user_level_targets_are_absolute(self) -> None:
        for key in ("claude-desktop", "lmstudio", "cursor"):
            assert client_targets()[key].path.is_absolute()

    @pytest.mark.skipif(sys.platform == "win32", reason="the App Sandbox is macOS; pwd does not exist on Windows")
    def test_sandboxed_service_targets_the_account_home(self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
        """In the App Store build $HOME is the XPC service's container; the configs live in the real home."""
        import os
        import pwd

        container = "/Users/me/Library/Containers/me.rickmark.garage-rag.xpc/Data"
        monkeypatch.setenv("HOME", container)
        monkeypatch.setenv("APP_SANDBOX_CONTAINER_ID", "me.rickmark.garage-rag.xpc")
        home = Path(pwd.getpwuid(os.getuid()).pw_dir)
        targets = client_targets(project_dir=tmp_path)
        assert targets["claude-desktop"].path == home / "Library/Application Support/Claude/claude_desktop_config.json"
        assert targets["claude-code-user"].path == home / ".claude.json"
        assert not any(str(t.path).startswith(container) for t in targets.values())
        assert plan_targets(path=Path("~/x.json")).targets[0].path == (home / "x.json").resolve()

    def test_unsandboxed_targets_follow_home(self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
        monkeypatch.delenv("APP_SANDBOX_CONTAINER_ID", raising=False)
        monkeypatch.setenv("HOME", str(tmp_path))
        monkeypatch.setenv("USERPROFILE", str(tmp_path))  # Path.home() on Windows
        assert client_targets()["claude-code-user"].path == tmp_path / ".claude.json"

    def test_windows_desktop_apps_keep_their_config_under_appdata(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        monkeypatch.setattr(sys, "platform", "win32")
        monkeypatch.delenv("APP_SANDBOX_CONTAINER_ID", raising=False)
        monkeypatch.setenv("HOME", str(tmp_path / "home"))
        monkeypatch.setenv("USERPROFILE", str(tmp_path / "home"))
        monkeypatch.setenv("APPDATA", str(tmp_path / "Roaming"))
        targets = client_targets(project_dir=tmp_path)
        assert targets["claude-desktop"].path == tmp_path / "Roaming" / "Claude" / "claude_desktop_config.json"
        assert targets["zed"].path == tmp_path / "Roaming" / "Zed" / "settings.json"
        assert targets["vscode-global"].path.is_relative_to(tmp_path / "Roaming" / "Code")
        # The dot-folder clients stay under the home folder, as on macOS.
        assert targets["claude-code-user"].path == tmp_path / "home" / ".claude.json"
        assert targets["cursor"].path == tmp_path / "home" / ".cursor" / "mcp.json"

    def test_windows_without_appdata_falls_back_to_roaming_under_home(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
    ) -> None:
        monkeypatch.setattr(sys, "platform", "win32")
        monkeypatch.delenv("APP_SANDBOX_CONTAINER_ID", raising=False)
        monkeypatch.delenv("APPDATA", raising=False)
        monkeypatch.setenv("HOME", str(tmp_path))
        monkeypatch.setenv("USERPROFILE", str(tmp_path))
        expected = tmp_path / "AppData" / "Roaming" / "Claude" / "claude_desktop_config.json"
        assert client_targets(project_dir=tmp_path)["claude-desktop"].path == expected


class TestHttpEntry:
    """The HTTP form is a URL the client connects to, not a command it spawns."""

    def test_url_entry_shape(self) -> None:
        entry = server_entry(url="http://127.0.0.1:8787/mcp")
        assert entry == {"type": "http", "url": "http://127.0.0.1:8787/mcp"}

    def test_url_entry_has_no_command_or_config(self, tmp_path: Path) -> None:
        """Nothing is spawned, so a command or config path would be misleading."""
        entry = server_entry(url="http://127.0.0.1:8787/mcp", config_path=tmp_path / "garage.json")
        assert "command" not in entry
        assert "args" not in entry
        assert "env" not in entry

    def test_transport_override(self) -> None:
        entry = server_entry(url="http://x/mcp", transport="sse")
        assert entry["type"] == "sse"

    def test_install_writes_url_entry(self, target: ClientTarget) -> None:
        install(target, url="http://127.0.0.1:8787/mcp")
        entry = _read(target.path)["mcpServers"]["garage-rag"]
        assert entry["url"] == "http://127.0.0.1:8787/mcp"

    def test_switching_stdio_to_http_needs_force(self, target: ClientTarget) -> None:
        install(target)
        with pytest.raises(FileExistsError):
            install(target, url="http://127.0.0.1:8787/mcp")
        install(target, url="http://127.0.0.1:8787/mcp", force=True)
        entry = _read(target.path)["mcpServers"]["garage-rag"]
        assert "command" not in entry


class TestHttpUrl:
    @pytest.mark.parametrize(
        ("host", "port", "path", "expected"),
        [
            ("127.0.0.1", 8787, "/mcp", "http://127.0.0.1:8787/mcp"),
            # A route without a leading slash must not produce a bad URL.
            ("127.0.0.1", 8787, "mcp", "http://127.0.0.1:8787/mcp"),
            ("localhost", 9000, "/rag", "http://localhost:9000/rag"),
            # IPv6 literals need brackets in the authority.
            ("::1", 8787, "/mcp", "http://[::1]:8787/mcp"),
        ],
    )
    def test_url_construction(self, host: str, port: int, path: str, expected: str) -> None:
        from garage_rag.mcp_server.install import http_url

        assert http_url(host, port, path) == expected


class TestLoopbackDetection:
    """Gates whether binding an address needs an explicit opt-in."""

    @pytest.mark.parametrize("host", ["127.0.0.1", "::1", "localhost", "127.0.0.53"])
    def test_loopback(self, host: str) -> None:
        from garage_rag.mcp_server.server import is_loopback

        assert is_loopback(host)

    @pytest.mark.parametrize("host", ["0.0.0.0", "192.168.1.10", "10.0.0.5", "example.com", "::"])
    def test_not_loopback(self, host: str) -> None:
        """0.0.0.0 binds every interface, so it is emphatically not loopback."""
        from garage_rag.mcp_server.server import is_loopback

        assert not is_loopback(host)

    def test_unknown_hostname_treated_as_remote(self) -> None:
        """Fail closed: an unclassifiable name requires the explicit opt-in."""
        from garage_rag.mcp_server.server import is_loopback

        assert not is_loopback("some-host.local")


class TestPlanTargets:
    def test_find_existing_configs_filters_existing_files_only(self, tmp_path: Path) -> None:
        proj_mcp = tmp_path / ".mcp.json"
        proj_mcp.write_text("{}")
        found = find_existing_configs(project_dir=tmp_path)
        assert "project" in found
        assert found["project"].path == proj_mcp

    def test_single_target_from_the_table(self, tmp_path: Path) -> None:
        plan = plan_targets("vscode", project_dir=tmp_path)
        assert [t.key for t in plan.targets] == ["vscode"]
        assert plan.targets[0].path == tmp_path / ".vscode" / "mcp.json"
        assert not plan.multi and not plan.fell_back

    def test_unknown_target_is_a_value_error_naming_the_choices(self, tmp_path: Path) -> None:
        with pytest.raises(ValueError, match="unknown target 'nope'") as info:
            plan_targets("nope", project_dir=tmp_path)
        for key in (*target_keys(), *MULTI_TARGETS):
            assert key in str(info.value)

    def test_explicit_path_wins_over_target(self, tmp_path: Path) -> None:
        plan = plan_targets("vscode", path=tmp_path / "custom.json", project_dir=tmp_path)
        assert [t.key for t in plan.targets] == ["custom"]
        assert plan.targets[0].path == (tmp_path / "custom.json").resolve()

    @pytest.mark.parametrize("alias", MULTI_TARGETS)
    def test_multi_target_uses_what_exists_on_disk(self, tmp_path: Path, alias: str) -> None:
        (tmp_path / ".mcp.json").write_text("{}")
        (tmp_path / ".vscode").mkdir()
        (tmp_path / ".vscode" / "mcp.json").write_text("{}")
        plan = plan_targets(alias, project_dir=tmp_path)
        assert plan.multi and not plan.fell_back
        assert {t.key for t in plan.targets} >= {"project", "vscode"}
        assert all(t.path.is_file() for t in plan.targets)

    def test_multi_target_falls_back_when_nothing_exists(self, tmp_path: Path, monkeypatch) -> None:
        monkeypatch.setattr("garage_rag.mcp_server.install.find_existing_configs", lambda project_dir=None: {})
        plan = plan_targets("project", all_configs=True, project_dir=tmp_path)
        assert plan.multi and plan.fell_back
        assert [t.key for t in plan.targets] == ["project", "claude-desktop"]

    def test_target_keys_match_the_table(self, tmp_path: Path) -> None:
        assert target_keys() == tuple(client_targets(project_dir=tmp_path))

    def test_cli_help_lists_every_target(self) -> None:
        """The --target help is derived from the table, so a new client cannot be left out."""
        result = CliRunner().invoke(app, ["mcp-install", "--help"])
        assert result.exit_code == 0
        flat = " ".join(result.output.split())
        for key in (*target_keys(), *MULTI_TARGETS):
            assert key in flat, key

    def test_cli_rejects_unknown_target(self) -> None:
        result = CliRunner().invoke(app, ["mcp-install", "--target", "nope", "--yes"])
        assert result.exit_code != 0
        assert "unknown target 'nope'" in result.output

    def test_cli_mcp_install_all_flag(self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
        mcp1 = tmp_path / ".mcp.json"
        mcp1.write_text(json.dumps({"mcpServers": {}}))
        mcp2 = tmp_path / ".vscode" / "mcp.json"
        mcp2.parent.mkdir(parents=True, exist_ok=True)
        mcp2.write_text(json.dumps({"mcpServers": {}}))

        monkeypatch.setattr(
            "garage_rag.mcp_server.install.find_existing_configs",
            lambda project_dir=None: {
                "project": ClientTarget(key="project", label="Project", path=mcp1),
                "vscode": ClientTarget(key="vscode", label="VS Code", path=mcp2),
            },
        )

        result = CliRunner().invoke(app, ["mcp-install", "--all", "--http", "--yes"])
        assert result.exit_code == 0
        assert "garage-rag" in _read(mcp1)["mcpServers"]
        assert _read(mcp1)["mcpServers"]["garage-rag"]["url"] == "http://127.0.0.1:8787/mcp"
        assert "garage-rag" in _read(mcp2)["mcpServers"]
        assert _read(mcp2)["mcpServers"]["garage-rag"]["url"] == "http://127.0.0.1:8787/mcp"


class TestCliMcpTest:
    def test_cli_mcp_test_command(self, monkeypatch: pytest.MonkeyPatch) -> None:
        from dataclasses import dataclass

        @dataclass
        class DummyStats:
            documents: int = 42
            chunks: int = 100

        @dataclass
        class DummySources:
            sources: list = None

            def __post_init__(self):
                self.sources = ["docs", "code"]

        @dataclass
        class DummyAuthors:
            authors: list = None

            def __post_init__(self):
                self.authors = ["author1"]

        @dataclass
        class DummySearch:
            hits: list = None

            def __post_init__(self):
                self.hits = []

        monkeypatch.setattr("garage_rag.mcp_server.server.rag_stats", lambda: DummyStats())
        monkeypatch.setattr("garage_rag.mcp_server.server.rag_list_sources", lambda: DummySources())
        monkeypatch.setattr("garage_rag.mcp_server.server.rag_list_authors", lambda: DummyAuthors())
        monkeypatch.setattr("garage_rag.mcp_server.server.rag_search", lambda query, limit=3: DummySearch())

        result = CliRunner().invoke(app, ["mcp-test"])
        assert result.exit_code == 0
        assert "rag_stats" in result.output
        assert "PASS" in result.output
