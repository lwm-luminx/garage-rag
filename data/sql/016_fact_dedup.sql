-- Two-level fact dedup: restatements within a document, then distinct claims
-- across the corpus. See garage_rag/enrich/clusters.py.
--
-- Level 1, per document: potential facts of one document that state the same
-- claim (a compound claim beside its parts, two prompts on one span, a quoted
-- reply) point at the document's representative of that claim
-- (`facts.restates_fact_id`). A restatement is kept verbatim; it just stops
-- being a node of the corpus pass, and backs whatever its representative backs.
--
-- Level 2, per corpus: the representatives are grouped by growing each group
-- around a seed and stopping at the first neighbour that is too far from the
-- group's centroid or would pull the centroid too far from the seed. Each
-- group records how varied it is (`distilled_facts.spread`, `.drift`,
-- `.radius`), and its centroid and seed live in the clustering model's
-- `fact_emb_<slug>` table (the `seed` column; garage_rag/db/emb_tables.py).
--
-- Idempotent: safe to re-run.

ALTER TABLE facts ADD COLUMN IF NOT EXISTS restates_fact_id bigint REFERENCES facts(id) ON DELETE SET NULL;
-- Cosine similarity to the representative (1 for the same normalized text).
ALTER TABLE facts ADD COLUMN IF NOT EXISTS restates_similarity real;
-- The model and threshold the document's level-1 pass ran with; NULL until it
-- has run on this fact with a vector, so a fact embedded later is looked at again.
ALTER TABLE facts ADD COLUMN IF NOT EXISTS dedup_key text;
CREATE INDEX IF NOT EXISTS facts_restates ON facts (restates_fact_id) WHERE restates_fact_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS facts_dedup_pending ON facts (document_id) WHERE dedup_key IS NULL;

-- Representatives behind the distilled fact (restatements not counted).
ALTER TABLE distilled_facts ADD COLUMN IF NOT EXISTS nodes integer;
-- Mean cosine distance from each representative to the group's centroid.
ALTER TABLE distilled_facts ADD COLUMN IF NOT EXISTS spread real;
-- Cosine distance from the group's seed (the centroid of its tightest core) to its centroid.
ALTER TABLE distilled_facts ADD COLUMN IF NOT EXISTS drift real;
-- Largest cosine distance from a representative to the centroid.
ALTER TABLE distilled_facts ADD COLUMN IF NOT EXISTS radius real;

-- The parameters the corpus pass last ran with; a change means a full re-run.
CREATE TABLE IF NOT EXISTS fact_cluster_state (
    id          smallint    PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    model_slug  text        NOT NULL,
    params      text        NOT NULL,
    updated_at  timestamptz NOT NULL DEFAULT now()
);
