-- Support `spotlight` sources and linking existing documents to additional sources
-- (such as Spotlight observing a file already indexed by another source).
--
-- Idempotent: safe to re-run.

-- ---------------------------------------------------------------------------
-- Widen `sources.kind` to allow `spotlight`.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'sources_kind_check'
          AND conrelid = 'sources'::regclass
          AND pg_get_constraintdef(oid) LIKE '%spotlight%'
    ) THEN
        ALTER TABLE sources DROP CONSTRAINT IF EXISTS sources_kind_check;
        ALTER TABLE sources ADD CONSTRAINT sources_kind_check
            CHECK (kind IN (
                'filesystem', 'git', 'sqlite', 'maildir', 'feed',
                'dropbox', 'onedrive', 'outlook', 'google_drive', 'gmail',
                'claude', 'chatgpt', 'antigravity', 'spotlight'
            ));
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- Additional source links: lets a source (e.g. `spotlight`) link to and enrich
-- a document already owned by another source without duplicating chunks or vectors.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS document_sources (
    document_id bigint      NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    source_id   bigint      NOT NULL REFERENCES sources(id)   ON DELETE CASCADE,
    uri         text        NOT NULL,
    mtime       timestamptz,
    meta        jsonb       NOT NULL DEFAULT '{}'::jsonb,
    linked_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (document_id, source_id),
    CONSTRAINT document_sources_source_uri_unique UNIQUE (source_id, uri)
);

CREATE INDEX IF NOT EXISTS document_sources_source_idx ON document_sources (source_id);
