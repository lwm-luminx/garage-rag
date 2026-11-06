"""What the Rust command line needs from the installed package before it runs (internal).

The Mac app's launchers export the schema, the model catalog and the ``garage-mcp`` to register
before calling the same Rust (``macapp/Sources/GarageLauncher``); a pip install has neither the app
nor the repository, so the package carries the two data folders (``_data``) and points the
environment at them. A value already in the environment wins, so the app's launchers and a
developer's own settings are untouched.

The database comes from ``GARAGE_DATABASE_URL`` or the config file (``./garage.json``, then
``~/.garage.json``, or ``--config``), as for the Rust CLI.
"""

from __future__ import annotations

import os
import signal
import sys
import sysconfig
from pathlib import Path

_DATA = Path(__file__).resolve().parent / "_data"


def _default(name: str, value: Path | None) -> None:
    if value is not None and not os.environ.get(name):
        os.environ[name] = str(value)


def _existing(path: Path) -> Path | None:
    return path if path.exists() else None


def _mcp_executable() -> Path | None:
    """The ``garage-mcp`` console script of this install, which ``mcp-install --stdio`` registers."""
    name = "garage-mcp.exe" if os.name == "nt" else "garage-mcp"
    candidates = []
    if sys.argv and sys.argv[0]:
        candidates.append(Path(sys.argv[0]).absolute().with_name(name))
    scripts = sysconfig.get_path("scripts")
    if scripts:
        candidates.append(Path(scripts) / name)
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate
    return None


def prepare_environment() -> None:
    """Points ``GARAGE_SQL_DIR``, ``GARAGE_MODEL_MANIFEST`` and ``GARAGE_MCP_EXECUTABLE`` at this
    install when they are unset."""
    _default("GARAGE_SQL_DIR", _existing(_DATA / "sql"))
    _default("GARAGE_MODEL_MANIFEST", _existing(_DATA / "models" / "models.json"))
    _default("GARAGE_MCP_EXECUTABLE", _mcp_executable())


def as_console_script() -> None:
    """Gives the command a native program's signals and output order: Ctrl-C ends it (Python's
    handler would only set a flag the Rust never reads), and what Python buffered is written before
    the Rust writes to the same descriptors."""
    if hasattr(signal, "SIGINT"):
        signal.signal(signal.SIGINT, signal.SIG_DFL)
    sys.stdout.flush()
    sys.stderr.flush()
