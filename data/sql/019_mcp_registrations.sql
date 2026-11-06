-- MCP registrations and the tokens that prove them (docs/plans/access-hooks.md,
-- "Registrations carry a token").
--
-- McpInstall mints a token for each client config it writes (`gmr_` and 32
-- random bytes, base64url) and puts it in the entry: GARAGE_MCP_TOKEN in the
-- `env` block for stdio, `Authorization: Bearer` in its `headers` for HTTP. Only
-- the token's SHA-256 is kept here. GarageService finds a `Corpus*` caller's
-- registration by hashing the token `garage-mcp` passes along, and an access
-- policy decides what that registration may see by its `id`.
--
-- `id` is random, never reused, and kept when the token is reset. A policy holds
-- it as a value, never as a foreign key: under v2's several corpora this table
-- moves to a catalog database of its own.
--
-- Idempotent: safe to re-run.

CREATE TABLE IF NOT EXISTS mcp_registrations (
    id           text PRIMARY KEY,
    name         text NOT NULL,             -- the server's name in the client's config
    client       text NOT NULL,             -- 'claude-desktop', 'cursor', 'custom', ...
    transport    text NOT NULL CHECK (transport IN ('stdio', 'http')),
    config_path  text NOT NULL,             -- the client config the entry was written to
    token_sha256 bytea NOT NULL UNIQUE CHECK (octet_length(token_sha256) = 32),
    created_at   timestamptz NOT NULL DEFAULT now(),
    last_seen_at timestamptz
);
