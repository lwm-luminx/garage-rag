-- Core corpus tables: sources, authors, documents, chunks.
-- Idempotent: safe to re-run.

-- ---------------------------------------------------------------------------
-- Sources: registered roots that get walked.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sources (
    id                      bigserial PRIMARY KEY,
    slug                    text        NOT NULL UNIQUE,
    kind                    text        NOT NULL,
    root                    text        NOT NULL,
    default_class           corpus_class NOT NULL DEFAULT 'document',
    default_trust           trust_tier  NOT NULL,
    enabled                 boolean     NOT NULL DEFAULT true,
    expected_elements       bigint      NOT NULL DEFAULT 0,
    config                  jsonb       NOT NULL DEFAULT '{}'::jsonb,
    created_at              timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT sources_kind_check
        CHECK (kind IN ('filesystem', 'git', 'sqlite', 'maildir', 'feed', 'dropbox', 'onedrive', 'outlook'))
);

-- ---------------------------------------------------------------------------
-- Authors and identity resolution.
-- An author owns many identities (git emails, phone numbers, handles);
-- resolution is lookup-by-identity, create-on-miss.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS authors (
    id           bigserial PRIMARY KEY,
    display_name text        NOT NULL,
    is_self      boolean     NOT NULL DEFAULT false,
    notes        text,
    created_at   timestamptz NOT NULL DEFAULT now()
);

-- At most one self-author.
CREATE UNIQUE INDEX IF NOT EXISTS authors_one_self
    ON authors ((is_self)) WHERE is_self;

CREATE TABLE IF NOT EXISTS author_identities (
    id        bigserial PRIMARY KEY,
    author_id bigint NOT NULL REFERENCES authors(id) ON DELETE CASCADE,
    kind      text   NOT NULL,
    value     text   NOT NULL,
    CONSTRAINT author_identities_kind_check
        CHECK (kind IN ('email', 'git_email', 'git_name', 'phone',
                        'imessage_handle', 'handle')),
    CONSTRAINT author_identities_unique UNIQUE (kind, value)
);

CREATE INDEX IF NOT EXISTS author_identities_author
    ON author_identities (author_id);

-- ---------------------------------------------------------------------------
-- Documents: one row per logical document.
--
-- Two hashes, deliberately not redundant:
--   source_sha256  hash of raw bytes    -> cheap skip WITHOUT extracting
--   content_sha256 hash of extracted text -> decides whether to re-chunk, so an
--                  extractor upgrade that yields better text correctly triggers
--                  a rebuild even though the file on disk never changed.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS documents (
    id                bigserial PRIMARY KEY,
    source_id         bigint      NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
    uri               text        NOT NULL,
    corpus_class      corpus_class NOT NULL,
    trust_tier        trust_tier  NOT NULL,
    title             text,
    mime              text,
    lang              text,
    byte_size         bigint,
    mtime             timestamptz,
    source_sha256     bytea,
    content_sha256    bytea       NOT NULL,
    extractor         text        NOT NULL,
    extractor_version text        NOT NULL DEFAULT '1',
    chunker           text,
    content           text,
    meta              jsonb       NOT NULL DEFAULT '{}'::jsonb,
    state             ingest_state NOT NULL DEFAULT 'ok',
    error             text,
    ingested_at       timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT documents_uri_unique UNIQUE (source_id, uri)
);

CREATE INDEX IF NOT EXISTS documents_class    ON documents (corpus_class);
CREATE INDEX IF NOT EXISTS documents_trust    ON documents (trust_tier);
CREATE INDEX IF NOT EXISTS documents_class_trust ON documents (corpus_class, trust_tier);
CREATE INDEX IF NOT EXISTS documents_source   ON documents (source_id);
CREATE INDEX IF NOT EXISTS documents_state    ON documents (state) WHERE state <> 'ok';
CREATE INDEX IF NOT EXISTS documents_uri_trgm ON documents USING gin (uri gin_trgm_ops);

-- ---------------------------------------------------------------------------
-- Authorship: M:N with role and the evidence that produced it, so a
-- misattribution is diagnosable rather than mysterious.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS document_authors (
    document_id bigint      NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    author_id   bigint      NOT NULL REFERENCES authors(id)   ON DELETE CASCADE,
    role        author_role NOT NULL,
    confidence  real        NOT NULL DEFAULT 1.0,
    evidence    text,
    PRIMARY KEY (document_id, author_id, role)
);

CREATE INDEX IF NOT EXISTS document_authors_author ON document_authors (author_id);

-- ---------------------------------------------------------------------------
-- Chunks: the unit of embedding. Model-agnostic on purpose -- every embedding
-- model references these same rows, which is what makes re-indexing a backfill
-- rather than a re-ingest.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS chunks (
    id           bigserial PRIMARY KEY,
    document_id  bigint NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    ord          int    NOT NULL,
    text         text   NOT NULL,
    token_count  int,
    char_start   int,
    char_end     int,
    heading_path text,
    chunk_sha256 bytea  NOT NULL,
    chunker      text   NOT NULL,
    -- Keyword half of hybrid search, maintained by Postgres itself.
    tsv tsvector GENERATED ALWAYS AS (to_tsvector('english', text)) STORED,
    CONSTRAINT chunks_ord_unique UNIQUE (document_id, ord)
);

CREATE INDEX IF NOT EXISTS chunks_tsv_gin ON chunks USING gin (tsv);
CREATE INDEX IF NOT EXISTS chunks_doc     ON chunks (document_id);
CREATE INDEX IF NOT EXISTS chunks_sha     ON chunks (chunk_sha256);

-- ---------------------------------------------------------------------------
-- Ingest runs: coverage bookkeeping that makes deletion reconciliation safe.
-- Without this, an unmounted Dropbox would look like 13k deleted documents.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ingest_runs (
    id             bigserial PRIMARY KEY,
    source_id      bigint      NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
    started_at     timestamptz NOT NULL DEFAULT now(),
    finished_at    timestamptz,
    completed      boolean     NOT NULL DEFAULT false,
    seen_count     int         NOT NULL DEFAULT 0,
    indexed_count  int         NOT NULL DEFAULT 0,
    skipped_count  int         NOT NULL DEFAULT 0,
    failed_count   int         NOT NULL DEFAULT 0,
    -- Cloud-placeholder accounting. Materializing pulls bytes over the network,
    -- so a run reports what it downloaded and what it left alone.
    placeholder_count   int    NOT NULL DEFAULT 0,
    materialized_count  int    NOT NULL DEFAULT 0,
    materialized_bytes  bigint NOT NULL DEFAULT 0,
    error          text
);

CREATE INDEX IF NOT EXISTS ingest_runs_source ON ingest_runs (source_id, started_at DESC);

-- Per-run record of which documents were observed, so reconcile can delete
-- only what a *completed* scan genuinely failed to find.
CREATE TABLE IF NOT EXISTS ingest_seen (
    run_id bigint NOT NULL REFERENCES ingest_runs(id) ON DELETE CASCADE,
    uri    text   NOT NULL,
    PRIMARY KEY (run_id, uri)
);
