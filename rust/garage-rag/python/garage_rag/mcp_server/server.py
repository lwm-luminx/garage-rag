"""The ``garage-mcp`` stdio server (``garage_rag.mcp_server.server:main``, as in 1.5.0).

The server is the Rust one (rust/garage-mcp through rust/garage-cli), with GarageService in this
process: the same tools, over stdin and stdout until the client closes them. ``garage mcp-serve``
runs the HTTP transport.
"""

from __future__ import annotations

import sys
from collections.abc import Sequence

from .. import _runtime
from .._native import garage_cli

__all__ = ["main"]


def main(argv: Sequence[str] | None = None) -> int:
    """Serves MCP over stdio with ``argv`` (default: ``sys.argv[1:]``; ``--config PATH``,
    ``--version``, ``--help``) and returns the exit code."""
    _runtime.as_console_script()
    _runtime.prepare_environment()
    args = list(sys.argv[1:] if argv is None else argv)
    return garage_cli.run_garage_mcp(args)


if __name__ == "__main__":
    sys.exit(main())
