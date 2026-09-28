-- Which way a message went, per chunk.
--
-- A Messages thread is one document holding both sides of the conversation,
-- one chunk per message (ingest/conversations.py). Trust is per document, so it
-- cannot say which of a thread's messages the owner wrote; these columns do,
-- for every message chunk:
--
--   direction  'sent' (the owner wrote it, is_from_me) or 'received';
--   sender     the handle that wrote it ('+15551234567', 'a@b.c'), or 'me'.
--
-- Both are NULL for every chunk that is not a message (files, code, facts), so
-- a direction filter in search keeps to messages. Plain columns rather than a
-- jsonb bag: search filters on direction in both engines' WHERE clauses, a
-- CHECK constraint keeps its values honest, and nothing else per-chunk needs a
-- home yet. Adding a nullable column with no default rewrites nothing.
--
-- Idempotent: safe to re-run.

ALTER TABLE chunks ADD COLUMN IF NOT EXISTS direction text;
ALTER TABLE chunks ADD COLUMN IF NOT EXISTS sender text;

DO $$
BEGIN
    ALTER TABLE chunks
        ADD CONSTRAINT chunks_direction_check
        CHECK (direction IN ('sent', 'received'));
EXCEPTION
    WHEN duplicate_object THEN NULL;
END
$$;
