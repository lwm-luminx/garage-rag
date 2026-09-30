-- Anchored distilled facts: ground truth that fixes a group's centroid.
--
-- Some potential facts need no model: a mail's sender, recipients and subject,
-- a Messages thread's participants. `garage enrich-facts` writes them straight
-- from the document's metadata (`facts.extractor = 'metadata'`, the value's
-- exact key in `facts.attributes->>'key'`; garage_rag/enrich/metadata.py).
--
-- Each distinct (fact_class, key) is one anchored distilled fact
-- (`anchor_key`). Every metadata fact with that key links to it by the key, not
-- by its vector. Its centroid is the vector of its representative (the first
-- such fact) and never moves: inferred facts of the same class join it when
-- close enough, without re-centring it, and no model is asked to confirm it.
-- See garage_rag/enrich/clusters.py.
--
-- Idempotent: safe to re-run.

ALTER TABLE distilled_facts ADD COLUMN IF NOT EXISTS anchor_key text;
CREATE UNIQUE INDEX IF NOT EXISTS distilled_facts_anchor
    ON distilled_facts (fact_class, anchor_key) WHERE anchor_key IS NOT NULL;

CREATE INDEX IF NOT EXISTS facts_metadata_key
    ON facts (fact_class, (attributes->>'key')) WHERE extractor = 'metadata';
