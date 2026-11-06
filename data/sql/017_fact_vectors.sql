-- Potential-fact vectors get a table of their own beside each model's chunk table.
--
-- Every potential fact has a chunk (007_chunk_fact_link.sql), so the backfill has
-- embedded facts into the model's `emb_<slug>` table beside the content chunks.
-- They now live in `potential_fact_emb_<slug>`, keyed on `fact_id` (ON DELETE
-- CASCADE), with an index of their own: the fact-to-fact neighbour queries of
-- `garage cluster-facts` walk a graph of facts only, and passage search a graph
-- of passages only. See garage_rag/db/emb_tables.py.
--
-- For each registered model, this creates the table if it is missing (the
-- vector column typed as the chunk table's, and the chunk table's vector index
-- rebuilt on it) and moves any fact vectors across. Idempotent: safe to re-run.
-- A model registered later gets the table from register_model().

-- No format(): its placeholders would be read as bind parameters when the file
-- goes through SQLAlchemy's exec_driver_sql (garage_rag.db.migrate), so identifiers
-- are quoted with quote_ident() instead.
DO $$
DECLARE
    m          record;
    chunk_tbl  text;
    fact_tbl   text;
    coltype    text;
    idx        record;
BEGIN
    FOR m IN SELECT table_name FROM embedding_models ORDER BY id LOOP
        chunk_tbl := m.table_name;
        fact_tbl := left('potential_fact_' || chunk_tbl, 63);
        IF to_regclass('public.' || quote_ident(chunk_tbl)) IS NULL THEN
            CONTINUE;
        END IF;

        IF to_regclass('public.' || quote_ident(fact_tbl)) IS NULL THEN
            SELECT format_type(a.atttypid, a.atttypmod) INTO coltype
            FROM pg_attribute a
            WHERE a.attrelid = ('public.' || quote_ident(chunk_tbl))::regclass AND a.attname = 'embedding';

            EXECUTE 'CREATE TABLE ' || quote_ident(fact_tbl) || ' (
                    fact_id     bigint PRIMARY KEY REFERENCES facts(id) ON DELETE CASCADE,
                    embedding   ' || coltype || ' NOT NULL,
                    embedded_at timestamptz NOT NULL DEFAULT now()
                )';

            -- The chunk table's vector index (HNSW on the column, or on its binary
            -- quantization), rebuilt on the new table under the same naming.
            FOR idx IN
                SELECT c.relname AS name, pg_get_indexdef(i.indexrelid) AS def
                FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
                WHERE i.indrelid = ('public.' || quote_ident(chunk_tbl))::regclass AND NOT i.indisprimary
            LOOP
                EXECUTE regexp_replace(
                    idx.def,
                    '^CREATE INDEX \S+ ON \S+ ',
                    'CREATE INDEX IF NOT EXISTS '
                        || quote_ident(left(fact_tbl || substr(idx.name, length(chunk_tbl) + 1), 63))
                        || ' ON ' || quote_ident(fact_tbl) || ' ');
            END LOOP;
        END IF;

        EXECUTE 'INSERT INTO ' || quote_ident(fact_tbl) || ' (fact_id, embedding, embedded_at)
             SELECT c.fact_id, e.embedding, e.embedded_at
             FROM ' || quote_ident(chunk_tbl) || ' e JOIN chunks c ON c.id = e.chunk_id
             WHERE c.fact_id IS NOT NULL
             ON CONFLICT (fact_id) DO NOTHING';
        EXECUTE 'DELETE FROM ' || quote_ident(chunk_tbl)
            || ' e USING chunks c WHERE c.id = e.chunk_id AND c.fact_id IS NOT NULL';
    END LOOP;
END
$$;
