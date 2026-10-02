"""The per-launch shared token that guards the GarageService gRPC port.

The app generates a random token each launch and hands it to the gRPC server and
its XPC workers as ``GARAGE_GRPC_TOKEN``. When it is set, the server rejects any
call whose ``x-garage-token`` metadata does not match, and every client in this
package sends it. When it is unset (``garage grpc serve`` for developers, the tests),
nothing changes.

This is a stopgap until the app talks to the server over XPC with code-signing
checks and no network socket at all; the whole module goes away then.
"""

from __future__ import annotations

import hmac
import os

TOKEN_ENV = "GARAGE_GRPC_TOKEN"
METADATA_KEY = "x-garage-token"

# Methods the server answers without the token. EnsureLlamaModel is how a stdio
# `garage-mcp` spawned by an MCP client (outside the app, so without the token) gets
# its llama_xpc model loaded; it only loads a model the app already knows by slug.
UNAUTHENTICATED_METHODS = frozenset({"EnsureLlamaModel"})

# Methods that write configuration: garage.json (sources, models, settings) or an MCP
# client's config file, and ``InitDb``, which applies the SQL files of a caller-chosen
# ``schema_dir`` with the database role. Changing ``embedding.ollama_host`` through
# ``SetSetting`` widens the egress allowlist, and a schema directory of the caller's
# choosing runs its SQL against the corpus, so these are answered only for a caller the
# server can vouch for: one presenting the token, or one on the owner-only Unix socket. A
# server on a loopback TCP port with no token (``garage grpc serve`` by hand) refuses
# them with PERMISSION_DENIED, since any account on the machine can reach that port.
# ``RunGraphQuery`` is among them although it writes nothing: it runs the caller's openCypher
# with the database role, and Cypher can call a schema-qualified Postgres function, so it gets
# the same vouching (db/graph.py refuses such calls too).
CONFIG_CHANGING_METHODS = frozenset(
    {
        "InitDb",
        "AddSource",
        "RemoveSource",
        "ImportSourcesToConfig",
        "RegisterModel",
        "SetDefaultModel",
        "DropModel",
        "SetSetting",
        "McpInstall",
        "McpUninstall",
        "RunGraphQuery",
    }
)


def token_from_env() -> str | None:
    """The token in ``GARAGE_GRPC_TOKEN``, or None when it is unset or empty."""
    token = os.environ.get(TOKEN_ENV, "").strip()
    return token or None


def token_matches(presented: str | bytes | None, expected: str) -> bool:
    """Constant-time comparison of a presented token against the expected one."""
    if presented is None:
        return False
    presented_bytes = presented.encode() if isinstance(presented, str) else presented
    return hmac.compare_digest(presented_bytes, expected.encode())


def config_change_allowed(*, token_configured: bool, unix_socket: bool) -> bool:
    """Whether a server answers config-changing methods for its callers.

    With a token configured the interceptor authenticates every call. Without one, a
    server bound to the owner-only Unix socket (and to nothing else) hears only from
    processes of the same account, so the folder's mode is the check; a server on a TCP
    port can vouch for nobody. This is decided from how the server was bound, not from
    ``ServicerContext.peer()``: gRPC reports a Unix-socket client as ``unix:...`` on
    Linux but not reliably on macOS, where the app runs.
    """
    return token_configured or unix_socket
