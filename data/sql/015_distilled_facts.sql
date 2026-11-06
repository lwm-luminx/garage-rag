-- Distilled facts: the claims the corpus makes, each backed by the potential
-- facts that state it.
--
-- The rows of `facts` are potential facts: what one prompt extracted from one
-- document, each a verbatim, grounded quote. The same claim is often extracted
-- many times (a quoted mail thread, a draft and its final version, a summary
-- and its detail). `garage cluster-facts` groups the potential facts that state
-- the same claim and links every one of them to a distilled fact
-- (`facts.distilled_fact_id`):
--
-- * a potential fact nothing else restates gets a distilled fact of its own,
--   whose statement is its own text;
-- * a group gets one distilled fact, whose statement the local model wrote
--   after confirming the group states one claim (`statement_generated`), or,
--   when no model was asked, the text of its representative member.
--
-- Grouping compares the potential facts' vectors (their chunks, under the
-- default model) with their nearest neighbours, splits any group whose members
-- differ in numbers, dates or negation, and merges by average linkage; see
-- garage_rag/enrich/clusters.py.
--
-- Potential facts are never changed or removed by this; the distilled layer is
-- rebuilt on each run. A distilled fact whose members are unchanged keeps its
-- row (`members_sha256`), its statement and its vectors. Re-extracting a
-- document deletes its potential facts; a distilled fact left with none is
-- dropped on the next run.
--
-- Each embedding model also has a `fact_emb_<slug>` table of distilled-fact
-- vectors, created with the model (garage_rag/db/emb_tables.py), not here,
-- since its column width is the model's.
--
-- Idempotent: safe to re-run.

CREATE TABLE IF NOT EXISTS distilled_facts (
    id                      bigserial   PRIMARY KEY,
    fact_class              text        NOT NULL,
    statement               text        NOT NULL,
    -- True when the local model wrote `statement`; it is then not a quotation.
    statement_generated     boolean     NOT NULL DEFAULT false,
    -- The member whose own text is the statement when the model wrote none (the longest).
    representative_fact_id  bigint      REFERENCES facts(id) ON DELETE SET NULL,
    -- sha256 over the sorted member ids: a re-run that finds the same members
    -- keeps the row, its statement and its vectors.
    members_sha256          bytea       NOT NULL,
    -- The embedding model whose vectors grouped the members, and the cosine
    -- similarity a pair had to reach. NULL for a distilled fact of one member.
    model_slug              text,
    threshold               real,
    distill_model           text,
    created_at              timestamptz NOT NULL DEFAULT now(),
    tsv tsvector GENERATED ALWAYS AS (to_tsvector('english', statement)) STORED
);

CREATE INDEX IF NOT EXISTS distilled_facts_tsv_gin ON distilled_facts USING gin (tsv);
CREATE INDEX IF NOT EXISTS distilled_facts_members_sha ON distilled_facts (members_sha256);

ALTER TABLE facts ADD COLUMN IF NOT EXISTS distilled_fact_id bigint REFERENCES distilled_facts(id) ON DELETE SET NULL;
-- The potential fact's average cosine similarity to the rest of its group; NULL alone.
ALTER TABLE facts ADD COLUMN IF NOT EXISTS distilled_similarity real;
CREATE INDEX IF NOT EXISTS facts_distilled ON facts (distilled_fact_id);
