-- Search access rules (docs/plans/search-access-rules.md), in garage-rag's database beside the
-- tables it owns. The policy applies this itself, once per process, before its first answer;
-- garage-rag's migrations know nothing of it.
--
-- A rule hides or admits whole documents. Metadata rules (source, corpus_class, trust_tier,
-- author, path) are decided inline in the filter. Content rules (regex, term) are evaluated ahead
-- of the query into access_evaluations, one row per rule and document, holding the rule's version
-- and the document's content_sha256 it was evaluated at. A row that is missing or out of date is
-- pending, and a pending DENY hides: the rules fail closed.
--
-- Idempotent: safe to re-run.

CREATE TABLE IF NOT EXISTS access_rules (
    id         bigserial PRIMARY KEY,
    name       text NOT NULL UNIQUE,
    effect     text NOT NULL CHECK (effect IN ('allow', 'deny')),
    targets    text[] NOT NULL,          -- names and prefix patterns: app, mcp:<registration id>, door:*, *
    matcher    text NOT NULL,            -- source | corpus_class | trust_tier | author | path | regex | term
    spec       jsonb NOT NULL,           -- the rule's normalized `match` object
    version    text NOT NULL,            -- hash of matcher and spec: a new one makes old evaluations stale
    enabled    boolean NOT NULL DEFAULT true,
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- A target's default when no rule decides: an exact name, else the longest prefix pattern, else
-- '*'; none at all is ALLOW.
CREATE TABLE IF NOT EXISTS access_defaults (
    target text PRIMARY KEY,
    effect text NOT NULL CHECK (effect IN ('allow', 'deny'))
);

CREATE TABLE IF NOT EXISTS access_evaluations (
    rule_id        bigint NOT NULL REFERENCES access_rules (id) ON DELETE CASCADE,
    document_id    bigint NOT NULL REFERENCES documents (id) ON DELETE CASCADE,
    version        text NOT NULL,
    content_sha256 bytea NOT NULL,
    matched        boolean NOT NULL,
    evaluated_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (rule_id, document_id)
);
CREATE INDEX IF NOT EXISTS access_evaluations_document ON access_evaluations (document_id);

-- Rego policies (docs/plans/opa-access-policies.md): modules evaluated once per read over the caller,
-- with the rules and defaults above as their data. With none enabled that declares package
-- garage.access, the built-in policy (policy/rules.rego) decides exactly as the rules alone did.
CREATE TABLE IF NOT EXISTS access_policies (
    name       text PRIMARY KEY,
    module     text NOT NULL,            -- Rego v1 source
    enabled    boolean NOT NULL DEFAULT true,
    updated_at timestamptz NOT NULL DEFAULT now()
);
