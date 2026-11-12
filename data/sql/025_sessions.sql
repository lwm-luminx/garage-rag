-- Common normalized schema for AI assistant sessions across Claude, ChatGPT /
-- Codex, and Antigravity.
--
-- Every provider's local `.jsonl` transcript and `.zip` / `conversations.json`
-- export maps onto four relational tables before synthesis into `documents` and
-- `chunks`:
--
--   sessions           -- one thread or subagent run (`provider`, `surface`,
--                         `workspace_path`, token totals, `parent_session_id`,
--                         and `document_id` pointing at its synthesized search
--                         document).
--   session_turns      -- every message/step node in the session graph, with
--                         `parent_turn_id` preserving edited prompts and
--                         regenerated replies and `active_ord` marking the
--                         active lineage synthesized into `documents`/`chunks`;
--                         `thinking` stays separate from `content` so chain-of-
--                         thought is queryable without diluting passage vectors.
--   session_tool_calls -- structured tool invocations (`tool_kind`,
--                         `target_path`, `command`, bounded `output_preview`)
--                         without flooding `chunks` with raw file-read dumps.
--   session_artifacts  -- deliverables attached to or produced by a session
--                         (Antigravity `brain/<id>/*.md`, Claude artifacts and
--                         attachments, ChatGPT Canvas/files), optionally linked
--                         to their own `documents` row (`document_id`).
--
-- `sessions.document_id` and `session_artifacts.document_id` are `ON DELETE SET
-- NULL`, so rebuilding or dropping a search document never destroys the stored
-- session history (including transcripts later aged out on disk by a client's
-- local retention policy). Each synthesized turn chunk points back to its
-- originating turn via `chunks.session_turn_id`.
--
-- Idempotent: safe to re-run.

-- ---------------------------------------------------------------------------
-- Widen `sources.kind` and `author_identities.kind`.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'sources_kind_check'
          AND conrelid = 'sources'::regclass
          AND pg_get_constraintdef(oid) LIKE '%antigravity%'
    ) THEN
        ALTER TABLE sources DROP CONSTRAINT IF EXISTS sources_kind_check;
        ALTER TABLE sources ADD CONSTRAINT sources_kind_check
            CHECK (kind IN (
                'filesystem', 'git', 'sqlite', 'maildir', 'feed',
                'dropbox', 'onedrive', 'outlook', 'google_drive', 'gmail',
                'claude', 'chatgpt', 'antigravity'
            ));
    END IF;
END
$$;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'author_identities_kind_check'
          AND conrelid = 'author_identities'::regclass
          AND pg_get_constraintdef(oid) LIKE '%ai_model%'
    ) THEN
        ALTER TABLE author_identities DROP CONSTRAINT IF EXISTS author_identities_kind_check;
        ALTER TABLE author_identities ADD CONSTRAINT author_identities_kind_check
            CHECK (kind IN (
                'email', 'git_email', 'git_name', 'phone',
                'imessage_handle', 'handle', 'ai_model'
            ));
    END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- Sessions: one thread or subagent run.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS sessions (
    id                  bigserial    PRIMARY KEY,
    source_id           bigint       NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
    provider            text         NOT NULL,
    surface             text         NOT NULL,
    -- Native session/conversation identifier (`sessionId`, conversation UUID,
    -- `brain/<uuid>`), unique per source so incremental `.jsonl` reads and
    -- repeated export `.zip` drops update the existing row in place.
    external_id         text         NOT NULL,
    -- Subagent hierarchy: `parent_external_id` keeps the raw parent UUID when a
    -- subagent transcript is read before its parent session.
    parent_session_id   bigint       REFERENCES sessions(id) ON DELETE SET NULL,
    parent_external_id  text,
    -- Synthesized `documents` row (`communication` / `received`) through which
    -- hybrid search, per-model embeddings, and fact extraction operate.
    document_id         bigint       REFERENCES documents(id) ON DELETE SET NULL,
    title               text,
    summary             text,
    -- Primary working directory (`cwd` / `workspacePaths[0]`) plus all attached
    -- workspace roots for multi-root sessions.
    workspace_path      text,
    workspace_paths     text[]       NOT NULL DEFAULT '{}'::text[],
    git_branch          text,
    git_commit          text,
    primary_model       text,
    started_at          timestamptz,
    updated_at          timestamptz,
    turn_count          int          NOT NULL DEFAULT 0,
    input_tokens        bigint,
    output_tokens       bigint,
    cache_read_tokens   bigint,
    origin_uri          text,
    synthesized_sha256  bytea,
    synthesized_at      timestamptz,
    meta                jsonb        NOT NULL DEFAULT '{}'::jsonb,
    created_at          timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT sessions_provider_check
        CHECK (provider IN ('claude', 'chatgpt', 'antigravity')),
    CONSTRAINT sessions_surface_check
        CHECK (surface IN (
            'claude_code', 'claude_cowork', 'claude_web',
            'codex', 'chatgpt_web',
            'antigravity'
        )),
    CONSTRAINT sessions_external_id_unique UNIQUE (source_id, external_id),
    CONSTRAINT sessions_document_unique    UNIQUE (document_id)
);

CREATE INDEX IF NOT EXISTS sessions_source
    ON sessions (source_id, updated_at DESC);
CREATE INDEX IF NOT EXISTS sessions_provider_external
    ON sessions (provider, external_id);
CREATE INDEX IF NOT EXISTS sessions_parent
    ON sessions (parent_session_id) WHERE parent_session_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS sessions_workspace
    ON sessions (workspace_path) WHERE workspace_path IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Session turns: every message/step node in the session tree.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS session_turns (
    id                  bigserial    PRIMARY KEY,
    session_id          bigint       NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    external_id         text         NOT NULL,
    -- Tree pointer (`mapping[id].parent` in ChatGPT, `parentUuid` in Claude
    -- Code) preserving prompt edits and regenerated assistant branches.
    parent_turn_id      bigint       REFERENCES session_turns(id) ON DELETE SET NULL,
    parent_external_id  text,
    ord                 int          NOT NULL,
    -- 0, 1, ... along the active branch synthesized into `documents`/`chunks`;
    -- NULL on abandoned edit branches and non-prose tool/system steps.
    active_ord          int,
    role                text         NOT NULL,
    direction           text,
    author_id           bigint       REFERENCES authors(id) ON DELETE SET NULL,
    model               text,
    content             text,
    -- Reasoning / chain-of-thought stored separately from visible `content`.
    thinking            text,
    input_tokens        int,
    output_tokens       int,
    cache_read_tokens   int,
    created_at          timestamptz,
    meta                jsonb        NOT NULL DEFAULT '{}'::jsonb,
    tsv                 tsvector GENERATED ALWAYS AS (
                            to_tsvector('english', coalesce(content, ''))
                        ) STORED,
    CONSTRAINT session_turns_role_check
        CHECK (role IN ('user', 'assistant', 'system', 'tool')),
    CONSTRAINT session_turns_direction_check
        CHECK (direction IN ('sent', 'received')),
    CONSTRAINT session_turns_external_unique UNIQUE (session_id, external_id)
);

CREATE INDEX IF NOT EXISTS session_turns_session_ord
    ON session_turns (session_id, ord);
CREATE INDEX IF NOT EXISTS session_turns_active_ord
    ON session_turns (session_id, active_ord) WHERE active_ord IS NOT NULL;
CREATE INDEX IF NOT EXISTS session_turns_parent
    ON session_turns (parent_turn_id) WHERE parent_turn_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS session_turns_author
    ON session_turns (author_id) WHERE author_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS session_turns_tsv_gin
    ON session_turns USING gin (tsv);

-- Link synthesized search chunks back to the turn they came from (one turn may
-- span multiple chunks when longer than `chunk_size`).
ALTER TABLE chunks
    ADD COLUMN IF NOT EXISTS session_turn_id bigint
    REFERENCES session_turns(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS chunks_session_turn
    ON chunks (session_turn_id) WHERE session_turn_id IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Session tool calls: normalized agent actions without raw file-dump bloat.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS session_tool_calls (
    id                bigserial    PRIMARY KEY,
    session_id        bigint       NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    turn_id           bigint       NOT NULL REFERENCES session_turns(id) ON DELETE CASCADE,
    result_turn_id    bigint       REFERENCES session_turns(id) ON DELETE SET NULL,
    ord               int          NOT NULL,
    external_call_id  text,
    tool_name         text         NOT NULL,
    tool_kind         text         NOT NULL DEFAULT 'other',
    target_path       text,
    command           text,
    status            text         NOT NULL DEFAULT 'ok',
    arguments         jsonb        NOT NULL DEFAULT '{}'::jsonb,
    output_preview    text,
    output_bytes      int,
    created_at        timestamptz,
    CONSTRAINT session_tool_calls_kind_check
        CHECK (tool_kind IN (
            'read', 'write', 'exec', 'search', 'mcp', 'subagent', 'browser', 'other'
        )),
    CONSTRAINT session_tool_calls_status_check
        CHECK (status IN ('ok', 'error', 'cancelled', 'pending')),
    CONSTRAINT session_tool_calls_turn_ord_unique UNIQUE (turn_id, ord)
);

CREATE INDEX IF NOT EXISTS session_tool_calls_session
    ON session_tool_calls (session_id);
CREATE INDEX IF NOT EXISTS session_tool_calls_target_path
    ON session_tool_calls (target_path) WHERE target_path IS NOT NULL;
CREATE INDEX IF NOT EXISTS session_tool_calls_tool_name
    ON session_tool_calls (tool_name);

-- ---------------------------------------------------------------------------
-- Session artifacts: plans, walkthroughs, Canvas docs, and attachments.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS session_artifacts (
    id              bigserial    PRIMARY KEY,
    session_id      bigint       NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
    turn_id         bigint       REFERENCES session_turns(id) ON DELETE SET NULL,
    external_id     text         NOT NULL,
    kind            text         NOT NULL DEFAULT 'document',
    title           text,
    mime            text,
    uri             text,
    -- Indexed prose/code artifacts also get their own `documents` row so their
    -- sections and code blocks are chunked independently of the chat turns.
    document_id     bigint       REFERENCES documents(id) ON DELETE SET NULL,
    content_sha256  bytea,
    meta            jsonb        NOT NULL DEFAULT '{}'::jsonb,
    created_at      timestamptz  NOT NULL DEFAULT now(),
    CONSTRAINT session_artifacts_kind_check
        CHECK (kind IN (
            'plan', 'walkthrough', 'document', 'code', 'attachment', 'image', 'other'
        )),
    CONSTRAINT session_artifacts_external_unique UNIQUE (session_id, external_id),
    CONSTRAINT session_artifacts_document_unique UNIQUE (document_id)
);

CREATE INDEX IF NOT EXISTS session_artifacts_session
    ON session_artifacts (session_id);
