-- Outlook sources (kind 'outlook'): a Microsoft account's mail read through Microsoft Graph.
-- `root` is a mail folder by display-name path, well-known name or id ('/' for the whole mailbox but
-- Deleted Items, Junk Email, Drafts and the Outbox); each message's document has the URI 'outlook:' and
-- Graph's immutable id. See rust/garage-ingest/src/outlook.rs.
--
-- 003_core.sql names the kind for a new database; this widens the check on one made before.
-- Idempotent: safe to re-run.

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'sources_kind_check'
          AND conrelid = 'sources'::regclass
          AND pg_get_constraintdef(oid) LIKE '%outlook%'
    ) THEN
        ALTER TABLE sources DROP CONSTRAINT IF EXISTS sources_kind_check;
        ALTER TABLE sources ADD CONSTRAINT sources_kind_check
            CHECK (kind IN ('filesystem', 'git', 'sqlite', 'maildir', 'feed', 'dropbox', 'onedrive', 'outlook'));
    END IF;
END
$$;
