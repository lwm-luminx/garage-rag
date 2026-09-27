-- What each embedding model embeds: text, or images.
--
-- An image embedding model (a CLIP-style pair of towers, such as SigLIP 2) maps
-- pictures and short texts into one space: its table holds vectors of the image
-- documents, and a text query is embedded by its text tower to search them.
-- Backfill reads this column to pick the chunks a model gets: a text model never
-- sees image chunks (chunks.chunker = 'image'), an image model sees only those,
-- and embeds the file behind the chunk's document rather than the chunk's text.
--
-- Every model registered before this column existed embeds text, so that is
-- the default.
--
-- Idempotent: safe to re-run.

ALTER TABLE embedding_models ADD COLUMN IF NOT EXISTS modality text NOT NULL DEFAULT 'text';

DO $$
BEGIN
    ALTER TABLE embedding_models
        ADD CONSTRAINT embedding_models_modality_check
        CHECK (modality IN ('text', 'image'));
EXCEPTION
    WHEN duplicate_object THEN NULL;
END
$$;
