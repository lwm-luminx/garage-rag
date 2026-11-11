-- Google Drive sources (kind 'google_drive'): a folder of My Drive read through the Drive API.
-- `root` is a folder in My Drive by its path of names ('/' for all of it); each file's document has
-- the URI 'google_drive:' and Drive's file id. See rust/garage-ingest/src/google_drive.rs.
--
-- 003_core.sql names the kind for a new database; this widens the check on one made before.
-- Idempotent: safe to re-run.

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'sources_kind_check'
          AND conrelid = 'sources'::regclass
          AND pg_get_constraintdef(oid) LIKE '%google_drive%'
    ) THEN
        ALTER TABLE sources DROP CONSTRAINT IF EXISTS sources_kind_check;
        ALTER TABLE sources ADD CONSTRAINT sources_kind_check
            CHECK (kind IN ('filesystem', 'git', 'sqlite', 'maildir', 'feed', 'dropbox', 'onedrive', 'outlook', 'google_drive'));
    END IF;
END
$$;
