"""The ``garage`` command line (``garage_rag.cli:main_cli``, as in 1.5.0).

Every command is the Rust CLI's (rust/garage-cli), which keeps the 1.5.0 commands, options,
wording and exit codes and runs GarageService in this process; nothing here parses arguments.
"""

from __future__ import annotations

import sys
from collections.abc import Sequence

from . import _runtime
from ._native import garage_cli

__all__ = ["get_version", "main", "main_cli"]


def get_version() -> str:
    """The version ``garage --version`` prints (1.5.0's ``get_version``)."""
    return garage_cli.version()


def main(argv: Sequence[str] | None = None) -> int:
    """Runs ``garage`` with ``argv`` (default: ``sys.argv[1:]``) and returns its exit code."""
    _runtime.prepare_environment()
    args = list(sys.argv[1:] if argv is None else argv)
    return garage_cli.run_garage(args)


def main_cli() -> int:
    """The ``garage`` console script's entry point."""
    _runtime.as_console_script()
    return main()


if __name__ == "__main__":
    sys.exit(main_cli())
