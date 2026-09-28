-- Fact clusters: facts that state the same claim, grouped.
--
-- `garage cluster-facts` compares every fact's vector (its chunk in the
-- default model's emb_ table) with its nearest neighbours, groups the facts
-- whose cosine similarity clears a threshold (average linkage, so A~B and B~C
-- do not chain A and C together), splits any group whose members disagree on
-- numbers, dates or negation, and asks the local model to confirm each group
-- and state its claim once.
--
-- Clustering is an overlay: every member stays a fact of its own, with its
-- verbatim text and grounded span, so nothing is lost and a re-run (or a new
-- threshold) simply rebuilds the overlay. `statement` is the model's wording
-- and is not a quotation; `representative_fact_id` is the member whose own
-- text stands for the group when there is no statement (the longest one).
--
-- A fact belongs to at most one cluster. Re-extracting a document deletes its
-- facts, and with them their memberships; a cluster left with fewer than two
-- members is dropped on the next run.
--
-- Idempotent: safe to re-run.

CREATE TABLE IF NOT EXISTS fact_clusters (
    id                      bigserial   PRIMARY KEY,
    -- The embedding model whose vectors were compared, and the cosine
    -- similarity a pair had to reach.
    model_slug              text        NOT NULL,
    threshold               real        NOT NULL,
    fact_class              text        NOT NULL,
    -- The local model's one-sentence statement of the shared claim; NULL when
    -- the run had no model to ask (or could not send a member to it).
    statement               text,
    representative_fact_id  bigint      REFERENCES facts(id) ON DELETE SET NULL,
    -- sha256 over the sorted member fact ids: a re-run that finds the same
    -- group keeps the row (and its statement) instead of asking the model again.
    members_sha256          bytea       NOT NULL,
    distill_model           text,
    created_at              timestamptz NOT NULL DEFAULT now(),
    tsv tsvector GENERATED ALWAYS AS (to_tsvector('english', coalesce(statement, ''))) STORED
);

CREATE INDEX IF NOT EXISTS fact_clusters_tsv_gin ON fact_clusters USING gin (tsv);
CREATE INDEX IF NOT EXISTS fact_clusters_members_sha ON fact_clusters (model_slug, members_sha256);

CREATE TABLE IF NOT EXISTS fact_cluster_members (
    fact_id     bigint  PRIMARY KEY REFERENCES facts(id) ON DELETE CASCADE,
    cluster_id  bigint  NOT NULL REFERENCES fact_clusters(id) ON DELETE CASCADE,
    -- The member's average cosine similarity to the rest of its cluster.
    similarity  real    NOT NULL
);

CREATE INDEX IF NOT EXISTS fact_cluster_members_cluster ON fact_cluster_members (cluster_id);
