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
# client's config file. Changing ``embedding.ollama_host`` through ``SetSetting`` widens
# the egress allowlist, so these are answered only for a caller the server can vouch
# for: one presenting the token, or one on the owner-only Unix socket. A server on a
# loopback TCP port with no token (``garage grpc serve`` by hand) refuses them with
# PERMISSION_DENIED, since any account on the machine can reach that port.
CONFIG_CHANGING_METHODS = frozenset(
    {
        "AddSource",
        "RemoveSource",
        "ImportSourcesToConfig",
        "RegisterModel",
        "SetDefaultModel",
        "DropModel",
        "SetSetting",
        "McpInstall",
        "McpUninstall",
    }
)

# ``ServicerContext.peer()`` for a caller on a Unix-domain socket (``unix:`` followed by
# the client's own path, usually none); TCP callers read ``ipv4:...`` / ``ipv6:...``.
UNIX_PEER_PREFIX = "unix:"


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


def peer_is_on_unix_socket(peer: str | None) -> bool:
    """Whether ``peer`` (a ``ServicerContext.peer()`` string) came in over a Unix-domain socket."""
    return bool(peer) and peer.startswith(UNIX_PEER_PREFIX)


def config_change_allowed(peer: str | None, *, token_configured: bool) -> bool:
    """Whether a config-changing method may run for this caller.

    With a token configured the interceptor has already authenticated the call;
    without one, only a caller on the owner-only Unix socket is trusted.
    """
    return token_configured or peer_is_on_unix_socket(peer)
