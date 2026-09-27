"""The `garage` and `garage-mcp` forwarder scripts in Garage.app/Contents/Resources/launchers.

Inside the app they exec the helper bundle beside them; copied onto the PATH they find Garage by
bundle identifier (Launch Services through `osascript`, then Spotlight's `mdfind`). These run the
real scripts against a fake Garage.app and stand-ins for `osascript` and `mdfind`.
"""

from __future__ import annotations

import os
import shutil
import stat
import subprocess
from pathlib import Path

import pytest

from garage_rag.config import repo_root

SCRIPTS = {
    "garage": repo_root() / "macapp" / "Sources" / "GarageCLI" / "garage",
    "garage-mcp": repo_root() / "macapp" / "Sources" / "GarageMCPCLI" / "garage-mcp",
}
BUNDLE_ID = "me.rickmark.garage-rag"


def _write_executable(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def _fake_app(root: Path) -> Path:
    """A Garage.app with both forwarders, their Contents/MacOS links and helpers that report how they ran."""
    app = root / "Garage.app"
    for name, script in SCRIPTS.items():
        _write_executable(
            app / "Contents" / "Helpers" / f"{name}.app" / "Contents" / "MacOS" / name,
            '#!/bin/sh\necho "helper $0"\nfor a in "$@"; do echo "arg $a"; done\ncat\n',
        )
        forwarder = app / "Contents" / "Resources" / "launchers" / name
        forwarder.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(script, forwarder)
        forwarder.chmod(0o755)
        link = app / "Contents" / "MacOS" / name
        link.parent.mkdir(parents=True, exist_ok=True)
        link.symlink_to(f"../Resources/launchers/{name}")
    return app


@pytest.fixture
def env(tmp_path: Path) -> dict[str, str]:
    """PATH with stand-ins: osascript prints $LS_ANSWER, mdfind prints $MDFIND_ANSWER and logs its query."""
    bin_dir = tmp_path / "bin"
    _write_executable(bin_dir / "osascript", '#!/bin/sh\nprintf "%s" "$LS_ANSWER"\n')
    _write_executable(bin_dir / "mdfind", '#!/bin/sh\necho "$1" >>"$MDFIND_LOG"\nprintf "%s\\n" "$MDFIND_ANSWER"\n')
    return {
        "PATH": f"{bin_dir}{os.pathsep}/usr/bin{os.pathsep}/bin",
        "LS_ANSWER": "",
        "MDFIND_ANSWER": "",
        "MDFIND_LOG": str(tmp_path / "mdfind.log"),
    }


def _run(command: Path, env: dict[str, str], *args: str, stdin: str = "") -> subprocess.CompletedProcess[str]:
    return subprocess.run([str(command), *args], env=env, input=stdin, capture_output=True, text=True, timeout=30)


@pytest.mark.parametrize("name", sorted(SCRIPTS))
def test_inside_the_app_the_link_runs_the_helper_beside_it(name: str, tmp_path: Path, env: dict[str, str]) -> None:
    app = _fake_app(tmp_path / "apps")
    result = _run(app / "Contents" / "MacOS" / name, env, "search", "two words", stdin="request\n")
    assert result.returncode == 0, result.stderr
    helper = (app / "Contents" / "Helpers" / f"{name}.app" / "Contents" / "MacOS" / name).resolve()
    assert result.stdout.splitlines() == [f"helper {helper}", "arg search", "arg two words", "request"]
    assert not Path(env["MDFIND_LOG"]).exists(), "a forwarder inside the app looks nothing up"


@pytest.mark.parametrize("name", sorted(SCRIPTS))
def test_a_copy_finds_the_app_through_launch_services(name: str, tmp_path: Path, env: dict[str, str]) -> None:
    app = _fake_app(tmp_path / "apps")
    copy = tmp_path / "usr-local-bin" / name
    copy.parent.mkdir()
    shutil.copy(SCRIPTS[name], copy)
    copy.chmod(0o755)
    env["LS_ANSWER"] = str(app)
    result = _run(copy, env, "--help")
    assert result.returncode == 0, result.stderr
    helper = (app / "Contents" / "Helpers" / f"{name}.app" / "Contents" / "MacOS" / name).resolve()
    assert result.stdout.splitlines()[:2] == [f"helper {helper}", "arg --help"]


def test_a_copy_falls_back_to_spotlight(tmp_path: Path, env: dict[str, str]) -> None:
    app = _fake_app(tmp_path / "apps")
    copy = tmp_path / "garage"
    shutil.copy(SCRIPTS["garage"], copy)
    copy.chmod(0o755)
    env["MDFIND_ANSWER"] = f"{app}\n/elsewhere/Garage.app"
    result = _run(copy, env, "stats")
    assert result.returncode == 0, result.stderr
    assert result.stdout.splitlines()[1] == "arg stats"
    assert Path(env["MDFIND_LOG"]).read_text().strip() == f"kMDItemCFBundleIdentifier == '{BUNDLE_ID}'"


def test_a_symlink_to_a_copy_still_looks_the_app_up(tmp_path: Path, env: dict[str, str]) -> None:
    app = _fake_app(tmp_path / "apps")
    copy = tmp_path / "scripts" / "garage-mcp"
    copy.parent.mkdir()
    shutil.copy(SCRIPTS["garage-mcp"], copy)
    copy.chmod(0o755)
    link = tmp_path / "bin-links" / "garage-mcp"
    link.parent.mkdir()
    link.symlink_to(copy)
    env["LS_ANSWER"] = str(app)
    assert _run(link, env).returncode == 0


@pytest.mark.parametrize("name", sorted(SCRIPTS))
def test_without_garage_a_copy_says_so_and_prints_nothing_on_stdout(
    name: str, tmp_path: Path, env: dict[str, str]
) -> None:
    copy = tmp_path / name
    shutil.copy(SCRIPTS[name], copy)
    copy.chmod(0o755)
    env["LS_ANSWER"] = str(tmp_path / "Missing.app")
    result = _run(copy, env)
    assert result.returncode == 127
    assert result.stdout == ""
    assert BUNDLE_ID in result.stderr
