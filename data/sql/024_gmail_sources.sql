-- Gmail sources (kind 'gmail'): a Google account's mail read through the Gmail API.
-- `root` is a label by id or name ('/' for the whole mailbox but spam, trash, drafts and chats); each
-- message's document has the URI 'gmail:' and Gmail's id. See rust/garage-ingest/src/gmail.rs.
--
-- 003_core.sql names the kind for a new database; this widens the check on one made before.
-- Idempotent: safe to re-run.

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'sources_kind_check'
          AND conrelid = 'sources'::regclass
          AND pg_get_constraintdef(oid) LIKE '%gmail%'
    ) THEN
        ALTER TABLE sources DROP CONSTRAINT IF EXISTS sources_kind_check;
        ALTER TABLE sources ADD CONSTRAINT sources_kind_check
            CHECK (kind IN ('filesystem', 'git', 'sqlite', 'maildir', 'feed', 'dropbox', 'onedrive', 'outlook', 'google_drive', 'gmail'));
    END IF;
END
$$;
