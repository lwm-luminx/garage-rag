-- Dropbox sources (kind 'dropbox'): read through Dropbox's HTTP API rather than a synced folder.
-- `root` is the folder in the Dropbox ('/' for all of it); each file's document has the URI
-- 'dropbox:' and its path. See rust/garage-ingest/src/dropbox.rs.
--
-- 003_core.sql names the kind for a new database; this widens the check on one made before.
-- Idempotent: safe to re-run.

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'sources_kind_check'
          AND conrelid = 'sources'::regclass
          AND pg_get_constraintdef(oid) LIKE '%dropbox%'
    ) THEN
        ALTER TABLE sources DROP CONSTRAINT IF EXISTS sources_kind_check;
        ALTER TABLE sources ADD CONSTRAINT sources_kind_check
            CHECK (kind IN ('filesystem', 'git', 'sqlite', 'maildir', 'feed', 'dropbox'));
    END IF;
END
$$;
