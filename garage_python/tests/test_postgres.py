"""Tests against a real Postgres + pgvector server.

Everything else in this directory mocks the database, so SQL that only the
server can judge (the migrations, the per-model DDL and operator classes, the
search query, the egress filter on pending chunks) is checked here.

They run only when ``GARAGE_TEST_DATABASE_URL`` names a development server with
pgvector, reached as a superuser: each run creates a database, and pgvector is not
a trusted extension (see "Testing against Postgres" in CLAUDE.md). Each module run creates a throwaway ``garage_test_*``
database, applies ``data/sql`` to it and drops it afterwards; nothing else on the
server is touched. Unset, the module is skipped; set but unreachable, it fails.
"""

from __future__ import annotations

import hashlib
import json
import os
import uuid
from collections.abc import Iterator
from typing import ClassVar
from unittest.mock import MagicMock, patch

import pytest
from sqlalchemy import text
from sqlalchemy.engine import make_url
from sqlalchemy.orm import Session

from garage_rag.config import Settings, ensure_psycopg_database_url, reset_settings, set_settings
from garage_rag.db.emb_tables import get_model, register_model
from garage_rag.db.engine import reset_engine, session_scope
from garage_rag.db.migrate import _connect, apply_migrations, pending_migrations, sql_dir, to_psycopg_conninfo
from garage_rag.db.registry import ModelSpec
from garage_rag.embed.ollama import count_pending
from garage_rag.ingest.gateway import ChunkPayload, SqlAlchemyIngestStorageGateway
from garage_rag.ops.facts import EXCERPT_CONTEXT, fact_stats, list_facts
from garage_rag.search import SearchMode
from garage_rag.search.hybrid import search

TEST_URL_ENV = "GARAGE_TEST_DATABASE_URL"

pytestmark = pytest.mark.skipif(
    not os.environ.get(TEST_URL_ENV),
    reason=f"{TEST_URL_ENV} is not set; see 'Testing against Postgres' in CLAUDE.md",
)


@pytest.fixture(scope="module")
def database_url() -> Iterator[str]:
    """A freshly migrated throwaway database, dropped when the module finishes."""
    server = make_url(ensure_psycopg_database_url(os.environ[TEST_URL_ENV]))
    admin = to_psycopg_conninfo(server.render_as_string(hide_password=False))
    name = f"garage_test_{uuid.uuid4().hex[:12]}"
    with _connect(admin) as conn:
        conn.execute(f'CREATE DATABASE "{name}"')
    url = server.set(database=name).render_as_string(hide_password=False)
    set_settings(Settings(database_url=url))
    reset_engine()
    try:
        apply_migrations(database_url=url)
        yield url
    finally:
        reset_engine()
        reset_settings()
        with _connect(admin) as conn:
            conn.execute(f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE)')


@pytest.fixture
def db(database_url: str) -> Iterator[Session]:
    """A session on the test database, emptied again after each test."""
    with session_scope() as session:
        yield session
    with session_scope() as session:
        tables = session.execute(text("SELECT tablename FROM pg_tables WHERE tablename LIKE 'emb\\_%'")).scalars()
        for table in tables:
            session.execute(text(f'DROP TABLE "{table}"'))
        session.execute(text("TRUNCATE sources, authors, embedding_models RESTART IDENTITY CASCADE"))


def _source(session: Session, slug: str, *, config: dict | None = None) -> int:
    return session.execute(
        text(
            "INSERT INTO sources (slug, kind, root, default_trust, config) "
            "VALUES (:slug, 'filesystem', '/tmp', 'authored', CAST(:config AS jsonb)) RETURNING id"
        ),
        {"slug": slug, "config": json.dumps(config or {})},
    ).scalar_one()


def _chunk(session: Session, source_id: int, title: str, body: str, *, corpus_class: str = "document") -> int:
    digest = hashlib.sha256(body.encode()).digest()
    document_id = session.execute(
        text(
            "INSERT INTO documents (source_id, uri, corpus_class, trust_tier, title, content_sha256, extractor) "
            "VALUES (:source, :uri, CAST(:cc AS corpus_class), 'authored', :title, :sha, 'test') RETURNING id"
        ),
        {"source": source_id, "uri": f"test://{title}", "cc": corpus_class, "title": title, "sha": digest},
    ).scalar_one()
    return session.execute(
        text(
            "INSERT INTO chunks (document_id, ord, text, chunk_sha256, chunker) "
            "VALUES (:doc, 0, :body, :sha, 'test') RETURNING id"
        ),
        {"doc": document_id, "body": body, "sha": digest},
    ).scalar_one()


def _document(session: Session, source_id: int, title: str, content: str, *, corpus_class: str = "document") -> int:
    return session.execute(
        text(
            "INSERT INTO documents (source_id, uri, corpus_class, trust_tier, title, content, content_sha256, "
            "extractor) VALUES (:source, :uri, CAST(:cc AS corpus_class), 'authored', :title, :content, :sha, 'test') "
            "RETURNING id"
        ),
        {
            "source": source_id,
            "uri": f"test://{title}",
            "cc": corpus_class,
            "title": title,
            "content": content,
            "sha": hashlib.sha256(content.encode()).digest(),
        },
    ).scalar_one()


def _embed(session: Session, table: str, chunk_id: int, vector: list[float], kind: str = "vector") -> None:
    session.execute(
        text(f"INSERT INTO {table} (chunk_id, embedding) VALUES (:id, CAST(:v AS {kind}({len(vector)})))"),
        {"id": chunk_id, "v": json.dumps(vector)},
    )


def _halves(dims: int, sign: float) -> list[float]:
    """+sign on the first half, -sign on the second: far apart under every metric,
    and far apart after binary quantization too."""
    half = dims // 2
    return [sign] * half + [-sign] * (dims - half)


def _index_definition(session: Session, table: str) -> str:
    return session.execute(
        text("SELECT indexdef FROM pg_indexes WHERE tablename = :t AND indexname LIKE :n"),
        {"t": table, "n": f"{table}_hnsw%"},
    ).scalar_one()


class TestMigrations:
    def test_a_migrated_database_has_nothing_pending(self, database_url: str) -> None:
        assert pending_migrations(database_url=database_url) == []

    def test_every_migration_re_applies_cleanly(self, database_url: str) -> None:
        applied = apply_migrations(database_url=database_url)
        assert {p.split(".")[0] for p in applied} >= {path.stem for path in sql_dir().glob("0*.sql")} - {
            "001_extensions"
        }

    def test_008_moves_scan_data_out_of_config(self, db: Session) -> None:
        """The upgrade path: a pre-008 database still has `expected_items` and keeps
        scan results in `config`. A fresh 001-007 schema no longer has the column,
        so it is put back by hand."""
        db.execute(text("ALTER TABLE sources ADD COLUMN IF NOT EXISTS expected_items bigint"))
        _source(
            db,
            "docs",
            config={"include_code": False, "item_type": "documents", "scan_details": {"md": 3}, "scanned_at": 1.7e9},
        )
        _source(db, "odd", config={"item_type": "messages", "scan_details": "not an object", "scanned_at": "noon"})
        _source(db, "plain", config={"include_code": True})
        migration = (sql_dir() / "008_source_scan.sql").read_text(encoding="utf-8")
        db.connection().exec_driver_sql(migration)
        db.connection().exec_driver_sql(migration)  # and again: idempotent

        rows = {
            row["slug"]: row
            for row in db.execute(
                text("SELECT slug, config, scan_item_type, scan_details, scanned_at FROM sources")
            ).mappings()
        }
        assert rows["docs"]["config"] == {"include_code": False}
        assert rows["docs"]["scan_item_type"] == "documents"
        assert rows["docs"]["scan_details"] == {"md": 3}
        assert rows["docs"]["scanned_at"] is not None
        # Malformed values are dropped from config without being carried over.
        assert rows["odd"]["config"] == {}
        assert rows["odd"]["scan_item_type"] == "messages"
        assert rows["odd"]["scan_details"] == {}
        assert rows["odd"]["scanned_at"] is None
        assert rows["plain"]["config"] == {"include_code": True}
        assert rows["plain"]["scan_item_type"] is None
        columns = db.execute(
            text("SELECT column_name FROM information_schema.columns WHERE table_name = 'sources'")
        ).scalars()
        assert "expected_items" not in set(columns)

    def test_010_drops_the_cloud_enrichment_column(self, db: Session) -> None:
        """A pre-010 database still has `sources.allow_cloud_enrichment`; a fresh
        schema never creates it, so it is put back by hand."""
        db.execute(text("ALTER TABLE sources ADD COLUMN allow_cloud_enrichment boolean NOT NULL DEFAULT false"))
        _source(db, "docs")
        migration = (sql_dir() / "010_drop_cloud_enrichment.sql").read_text(encoding="utf-8")
        db.connection().exec_driver_sql(migration)
        db.connection().exec_driver_sql(migration)  # and again: idempotent

        columns = db.execute(
            text("SELECT column_name FROM information_schema.columns WHERE table_name = 'sources'")
        ).scalars()
        assert "allow_cloud_enrichment" not in set(columns)
        assert db.execute(text("SELECT slug FROM sources")).scalar_one() == "docs"

    def test_011_drops_empty_placeholder_documents(self, db: Session) -> None:
        """Older builds wrote an empty row for every placeholder, and flipped an indexed
        row to 'placeholder' once its file was evicted; only the empty rows go."""
        source_id = _source(db, "cloud")
        db.execute(
            text(
                "INSERT INTO documents (source_id, uri, corpus_class, trust_tier, title, content_sha256, extractor, "
                "state, error) VALUES (:s, '/stub.pdf', 'document', 'authored', 'stub', '', 'none', 'placeholder', "
                "'not materialized')"
            ),
            {"s": source_id},
        )
        chunk_id = _chunk(db, source_id, "Evicted", "Indexed before the sync client evicted it")
        db.execute(
            text(
                "UPDATE documents SET state = 'placeholder', error = 'not materialized' "
                "WHERE id = (SELECT document_id FROM chunks WHERE id = :c)"
            ),
            {"c": chunk_id},
        )
        migration = (sql_dir() / "011_drop_placeholder_documents.sql").read_text(encoding="utf-8")
        db.connection().exec_driver_sql(migration)
        db.connection().exec_driver_sql(migration)  # and again: idempotent

        rows = db.execute(text("SELECT title, state::text, error FROM documents")).all()
        assert [tuple(row) for row in rows] == [("Evicted", "ok", None)]

    def test_013_scopes_facts_by_prompt(self, db: Session) -> None:
        """A pre-013 database: facts unique on (document_id, ord), no prompt columns,
        no fact_runs. A fresh schema has all of 013, so it is taken back out by hand."""
        conn = db.connection()
        conn.exec_driver_sql("DROP TABLE fact_runs")
        conn.exec_driver_sql("ALTER TABLE facts DROP CONSTRAINT facts_prompt_ord_unique")
        conn.exec_driver_sql("ALTER TABLE facts DROP COLUMN prompt_name, DROP COLUMN prompt_sha256")
        conn.exec_driver_sql("ALTER TABLE facts ADD CONSTRAINT facts_ord_unique UNIQUE (document_id, ord)")
        document = _document(db, _source(db, "docs"), "memo", "Acme was founded in 1998.")
        db.execute(
            text("INSERT INTO facts (document_id, ord, fact) VALUES (:d, 0, 'Acme was founded in 1998.')"),
            {"d": document},
        )
        migration = (sql_dir() / "013_fact_prompts.sql").read_text(encoding="utf-8")
        conn.exec_driver_sql(migration)
        conn.exec_driver_sql(migration)  # and again: idempotent

        # The old facts came from the one built-in prompt; their hash is unknown.
        assert tuple(db.execute(text("SELECT prompt_name, prompt_sha256 FROM facts")).one()) == ("default", None)
        constraints = set(
            db.execute(text("SELECT conname FROM pg_constraint WHERE conrelid = 'facts'::regclass")).scalars()
        )
        assert "facts_prompt_ord_unique" in constraints and "facts_ord_unique" not in constraints
        assert db.execute(text("SELECT to_regclass('fact_runs') IS NOT NULL")).scalar_one()
        # ord now counts within a prompt: another prompt's fact 0 fits beside it.
        db.execute(
            text("INSERT INTO facts (document_id, ord, fact, prompt_name) VALUES (:d, 0, 'Acme.', 'people')"),
            {"d": document},
        )
        with pytest.raises(Exception, match="facts_prompt_ord_unique"):
            db.execute(text("INSERT INTO facts (document_id, ord, fact) VALUES (:d, 0, 'dup')"), {"d": document})

    def test_fact_runs_go_with_their_document(self, db: Session) -> None:
        document = _document(db, _source(db, "docs"), "memo", "Acme was founded in 1998.")
        db.execute(
            text(
                "INSERT INTO fact_runs (document_id, prompt_name, prompt_sha256, content_sha256, extractor_model) "
                "VALUES (:d, 'default', :h, :h, 'm')"
            ),
            {"d": document, "h": b"\x00"},
        )
        db.execute(text("DELETE FROM documents WHERE id = :d"), {"d": document})
        assert db.execute(text("SELECT count(*) FROM fact_runs")).scalar_one() == 0

    def test_009_defaults_and_checks_distance(self, db: Session) -> None:
        db.execute(
            text(
                "INSERT INTO embedding_models (slug, provider, model_ref, dims, stored_dims, storage_kind, "
                "index_kind, table_name) VALUES ('legacy', 'ollama', 'x', 3, 3, 'vector', 'hnsw', 'emb_legacy')"
            )
        )
        assert db.execute(text("SELECT distance FROM embedding_models")).scalar_one() == "cosine"
        with pytest.raises(Exception, match="embedding_models_distance_check"):
            db.execute(text("UPDATE embedding_models SET distance = 'manhattan'"))

    def test_014_adds_direction_and_sender_to_chunks(self, db: Session) -> None:
        """Re-applied, 014 leaves one column each and one check; only messages carry a value."""
        chunk = _chunk(db, _source(db, "sms"), "thread", "[2026-09-24 12:00 UTC] Me: on my way")
        migration = (sql_dir() / "014_chunk_direction.sql").read_text(encoding="utf-8")
        db.connection().exec_driver_sql(migration)
        db.connection().exec_driver_sql(migration)  # and again: idempotent

        assert db.execute(text("SELECT direction, sender FROM chunks WHERE id = :id"), {"id": chunk}).one() == (
            None,
            None,
        )
        db.execute(text("UPDATE chunks SET direction = 'sent', sender = 'me' WHERE id = :id"), {"id": chunk})
        with pytest.raises(Exception, match="chunks_direction_check"):
            db.execute(text("UPDATE chunks SET direction = 'sideways' WHERE id = :id"), {"id": chunk})


class TestIngestOutcomes:
    """The no-text and failed outcomes the pipeline remembers, through the SQL gateway."""

    def _gateway(self, db: Session) -> SqlAlchemyIngestStorageGateway:
        _source(db, "outcomes")
        db.commit()
        return SqlAlchemyIngestStorageGateway(session_factory=session_scope)

    def test_no_text_is_remembered_and_updated_in_place(self, db: Session) -> None:
        gateway = self._gateway(db)
        gateway.record_no_text(0, "outcomes", "/pics/photo.png", byte_size=10, mtime=1.7e9, source_sha256="ab" * 32)
        gateway.record_no_text(0, "outcomes", "/pics/photo.png", byte_size=12, mtime=1.8e9, source_sha256="cd" * 32)

        stat = gateway.check_stat("outcomes", "/pics/photo.png")
        assert (stat.exists, stat.state, stat.byte_size, stat.mtime, stat.source_sha256) == (
            True,
            "no_text",
            12,
            1.8e9,
            "cd" * 32,
        )
        assert db.execute(text("SELECT count(*) FROM ingest_outcomes")).scalar_one() == 1

    def test_failure_is_remembered_with_its_error(self, db: Session) -> None:
        gateway = self._gateway(db)
        gateway.record_extract_failed(
            0, "outcomes", "/docs/broken.pdf", "bad xref", byte_size=5, mtime=1.7e9, source_sha256="ef" * 32
        )

        assert gateway.check_stat("outcomes", "/docs/broken.pdf").state == "failed"
        row = db.execute(text("SELECT outcome, error, extractor_revision FROM ingest_outcomes")).one()
        assert tuple(row) == ("failed", "bad xref", "pdf:1")

    def test_an_outcome_from_another_extractor_version_is_ignored(self, db: Session) -> None:
        gateway = self._gateway(db)
        gateway.record_no_text(0, "outcomes", "/pics/photo.png", byte_size=10, mtime=1.7e9, source_sha256="ab" * 32)
        db.execute(text("UPDATE ingest_outcomes SET extractor_revision = 'image:0'"))
        db.commit()

        assert gateway.check_stat("outcomes", "/pics/photo.png").exists is False

    def test_indexing_the_file_forgets_its_outcome(self, db: Session) -> None:
        gateway = self._gateway(db)
        gateway.record_no_text(0, "outcomes", "/notes/a.md", byte_size=1, mtime=1.7e9, source_sha256="ab" * 32)
        with patch("garage_rag.attribute.resolver.ensure_self_author"):
            gateway.replace_document(
                0,
                "outcomes",
                "/notes/a.md",
                title="a",
                lang=None,
                byte_size=4,
                mtime=1.8e9,
                source_sha256="cd" * 32,
                content_sha256="ef" * 32,
                extractor="markdown",
                extractor_version="1",
                chunker=None,
                content="text",
                meta={},
                corpus_class="document",
                trust_tier="authored",
                authors=[],
                chunks=[],
            )

        assert db.execute(text("SELECT count(*) FROM ingest_outcomes")).scalar_one() == 0
        assert gateway.check_stat("outcomes", "/notes/a.md").state.upper() == "OK"


class TestReplaceDocument:
    """Replacing a document keeps the chunks that did not change, and so their vectors."""

    @staticmethod
    def _chunks(*texts: str, direction: str | None = None, sender: str | None = None) -> list[ChunkPayload]:
        return [
            ChunkPayload(
                ord=i,
                text=t,
                chunk_sha256=hashlib.sha256(t.encode()).hexdigest(),
                chunker="test",
                direction=direction,
                sender=sender,
            )
            for i, t in enumerate(texts)
        ]

    @staticmethod
    def _replace(gateway: SqlAlchemyIngestStorageGateway, chunks: list[ChunkPayload]) -> None:
        content = "\n".join(c.text for c in chunks)
        with patch("garage_rag.attribute.resolver.ensure_self_author"):
            gateway.replace_document(
                0,
                "replace",
                "/notes/a.md",
                title="a",
                lang=None,
                byte_size=len(content),
                mtime=1.8e9,
                source_sha256=hashlib.sha256(content.encode()).hexdigest(),
                content_sha256=hashlib.sha256(content.encode()).hexdigest(),
                extractor="markdown",
                extractor_version="1",
                chunker="test",
                content=content,
                meta={},
                corpus_class="document",
                trust_tier="authored",
                authors=[],
                chunks=chunks,
            )

    def _rows(self, db: Session) -> dict[int, tuple[int, str]]:
        db.expire_all()
        return {
            row.ord: (row.id, row.text) for row in db.execute(text("SELECT id, ord, text FROM chunks ORDER BY ord"))
        }

    def test_unchanged_chunks_keep_their_rows_and_vectors(self, db: Session) -> None:
        model = register_model(db, ModelSpec(slug="small", model_ref="small", dims=8))
        _source(db, "replace")
        db.commit()
        gateway = SqlAlchemyIngestStorageGateway(session_factory=session_scope)

        self._replace(gateway, self._chunks("first", "second", "third"))
        before = self._rows(db)
        for chunk_id, _ in before.values():
            _embed(db, model.table_name, chunk_id, _halves(8, 1.0))
        db.commit()

        self._replace(gateway, self._chunks("first", "changed", "third", "fourth"))
        after = self._rows(db)

        assert [t for _, t in after.values()] == ["first", "changed", "third", "fourth"]
        assert after[0][0] == before[0][0]
        assert after[2][0] == before[2][0]
        assert after[1][0] != before[1][0]
        embedded = set(db.execute(text(f"SELECT chunk_id FROM {model.table_name}")).scalars())
        assert embedded == {before[0][0], before[2][0]}

    def test_a_shorter_document_drops_the_chunks_past_its_end(self, db: Session) -> None:
        _source(db, "replace")
        db.commit()
        gateway = SqlAlchemyIngestStorageGateway(session_factory=session_scope)

        self._replace(gateway, self._chunks("first", "second"))
        first = self._rows(db)[0][0]
        self._replace(gateway, self._chunks("first"))

        assert self._rows(db) == {0: (first, "first")}

    def test_a_kept_chunk_takes_its_new_direction_and_sender(self, db: Session) -> None:
        """A message indexed before 014 has no direction; the rebuild fills it in on the same row."""
        _source(db, "replace")
        db.commit()
        gateway = SqlAlchemyIngestStorageGateway(session_factory=session_scope)

        self._replace(gateway, self._chunks("see you at 7"))
        before = self._rows(db)[0][0]
        self._replace(gateway, self._chunks("see you at 7", direction="received", sender="+15551234567"))

        db.expire_all()
        row = db.execute(text("SELECT id, direction, sender FROM chunks")).one()
        assert tuple(row) == (before, "received", "+15551234567")


class TestModelTables:
    @pytest.mark.parametrize(
        ("distance", "ops"),
        [("cosine", "vector_cosine_ops"), ("l2", "vector_l2_ops"), ("inner_product", "vector_ip_ops")],
    )
    def test_the_index_is_built_for_the_models_distance(self, db: Session, distance: str, ops: str) -> None:
        model = register_model(db, ModelSpec(slug="small", model_ref="small", dims=8, distance=distance))
        assert model.distance == distance
        assert ops in _index_definition(db, model.table_name)

    def test_a_model_wider_than_vector_indexes_as_halfvec(self, db: Session) -> None:
        model = register_model(db, ModelSpec(slug="wide", model_ref="wide", dims=3000, distance="l2"))
        assert (model.storage_kind, model.index_kind) == ("halfvec", "hnsw")
        assert "halfvec_l2_ops" in _index_definition(db, model.table_name)

    def test_a_non_mrl_model_beyond_halfvec_indexes_its_binary_quantization(self, db: Session) -> None:
        model = register_model(db, ModelSpec(slug="huge", model_ref="huge", dims=4096))
        assert (model.storage_kind, model.index_kind) == ("vector", "hnsw_bq")
        index = _index_definition(db, model.table_name)
        assert "binary_quantize(embedding)" in index
        assert "bit_hamming_ops" in index


class TestSearch:
    """Two documents whose vectors point in opposite directions and whose words do
    not overlap; the query matches the first in both engines."""

    def _corpus(self, db: Session, spec: ModelSpec, kind: str) -> tuple[str, int]:
        model = register_model(db, spec)
        source = _source(db, "notes")
        heat = _chunk(db, source, "heat-pumps", "Heat pumps lose efficiency in deep cold.")
        bread = _chunk(db, source, "sourdough", "A sourdough starter needs wild yeast and flour.")
        _embed(db, model.table_name, heat, _halves(model.stored_dims, 1.0), kind)
        _embed(db, model.table_name, bread, _halves(model.stored_dims, -1.0), kind)
        db.flush()
        return model.slug, model.stored_dims

    def _search(self, db: Session, slug: str, dims: int, mode: SearchMode = "hybrid") -> list[str]:
        embedder = MagicMock()
        embedder.embed.return_value = [_halves(dims, 1.0)]
        with patch("garage_rag.search.hybrid.get_embedder", return_value=embedder):
            hits = search(db, "heat pump efficiency", model_slug=slug, mode=mode)
        return [hit.title for hit in hits]

    @pytest.mark.parametrize("distance", ["cosine", "l2", "inner_product"])
    def test_hybrid_search_ranks_the_matching_document_first(self, db: Session, distance: str) -> None:
        slug, dims = self._corpus(db, ModelSpec(slug="m", model_ref="m", dims=8, distance=distance), "vector")
        assert self._search(db, slug, dims) == ["heat-pumps", "sourdough"]

    def test_halfvec_search_binds_a_halfvec_query(self, db: Session) -> None:
        slug, dims = self._corpus(db, ModelSpec(slug="wide", model_ref="wide", dims=3000), "halfvec")
        assert self._search(db, slug, dims, mode="vector") == ["heat-pumps", "sourdough"]

    def test_binary_quantized_search_re_ranks_on_the_exact_distance(self, db: Session) -> None:
        slug, dims = self._corpus(db, ModelSpec(slug="huge", model_ref="huge", dims=4096), "vector")
        assert self._search(db, slug, dims, mode="vector") == ["heat-pumps", "sourdough"]

    def test_keyword_search_needs_no_model(self, db: Session) -> None:
        source = _source(db, "notes")
        _chunk(db, source, "sourdough", "A sourdough starter needs wild yeast and flour.")
        hits = search(db, "wild yeast", mode="fts")
        assert [hit.title for hit in hits] == ["sourdough"]

    def test_direction_keeps_to_messages_that_went_that_way(self, db: Session) -> None:
        source = _source(db, "notes")
        _chunk(db, source, "sourdough", "A sourdough starter needs wild yeast and flour.")
        sent = _chunk(db, source, "thread", "Me: bring the sourdough", corpus_class="communication")
        document_id = db.execute(text("SELECT document_id FROM chunks WHERE id = :id"), {"id": sent}).scalar_one()
        db.execute(text("UPDATE chunks SET direction = 'sent', sender = 'me' WHERE id = :id"), {"id": sent})
        db.execute(
            text(
                "INSERT INTO chunks (document_id, ord, text, chunk_sha256, chunker, direction, sender) "
                "VALUES (:doc, 1, 'friend: sourdough again?', :sha, 'test', 'received', 'friend@example.com')"
            ),
            {"doc": document_id, "sha": hashlib.sha256(b"received").digest()},
        )

        everything = search(db, "sourdough", mode="fts")
        assert len(everything) == 3
        assert {(h.direction, h.sender) for h in everything} == {
            (None, None),
            ("sent", "me"),
            ("received", "friend@example.com"),
        }
        assert [(h.text, h.sender) for h in search(db, "sourdough", mode="fts", direction="sent")] == [
            ("Me: bring the sourdough", "me")
        ]
        assert [h.sender for h in search(db, "sourdough", mode="fts", direction="received")] == ["friend@example.com"]
        with pytest.raises(ValueError, match="direction must be one of sent, received"):
            search(db, "sourdough", mode="fts", direction="sideways")


class TestEgress:
    def test_off_box_backfill_counts_leave_out_communications(self, db: Session) -> None:
        """What an off-box provider may embed excludes communication chunks, checked
        by the server rather than by looking at the SQL string."""
        model = register_model(db, ModelSpec(slug="m", model_ref="m", dims=8))
        source = _source(db, "mixed")
        _chunk(db, source, "memo", "A memo about the roof.")
        _chunk(db, source, "email", "An email about the roof.", corpus_class="communication")
        db.flush()
        row = get_model(db, model.slug)
        assert count_pending(db, row, include_communications=True) == 2
        assert count_pending(db, row, include_communications=False) == 1


class TestFacts:
    """The listing behind the app's Facts page."""

    def _document(
        self, db: Session, source_id: int, title: str, content: str, *, corpus_class: str = "document"
    ) -> int:
        return db.execute(
            text(
                "INSERT INTO documents (source_id, uri, corpus_class, trust_tier, title, content, content_sha256, "
                "extractor) VALUES (:source, :uri, CAST(:cc AS corpus_class), 'authored', :title, :content, :sha, "
                "'test') RETURNING id"
            ),
            {
                "source": source_id,
                "uri": f"test://{title}",
                "cc": corpus_class,
                "title": title,
                "content": content,
                "sha": hashlib.sha256(content.encode()).digest(),
            },
        ).scalar_one()

    def _fact(self, db: Session, document_id: int, ord: int, fact: str, *, fact_class: str = "fact", span=None) -> None:
        start, end = span or (None, None)
        db.execute(
            text(
                "INSERT INTO facts (document_id, ord, fact, fact_class, char_start, char_end) "
                "VALUES (:doc, :ord, :fact, :cls, :start, :end)"
            ),
            {"doc": document_id, "ord": ord, "fact": fact, "cls": fact_class, "start": start, "end": end},
        )

    def _corpus(self, db: Session) -> tuple[int, int, str]:
        notes = _source(db, "notes")
        mail = _source(db, "mail")
        body = "x" * 300 + "The heat pump was installed in March 2024." + "y" * 300
        start = body.index("The heat pump")
        house = self._document(db, notes, "house", body)
        self._fact(
            db, house, 0, "The heat pump was installed in March 2024.", fact_class="event", span=(start, start + 42)
        )
        self._fact(db, house, 1, "The house has a heat pump.")
        email = self._document(db, mail, "email", "Dinner is at eight.", corpus_class="communication")
        self._fact(db, email, 0, "Dinner is at eight o'clock.")
        db.flush()
        return house, email, body

    def test_lists_every_fact_with_its_document(self, db: Session) -> None:
        self._corpus(db)
        page = list_facts(db)
        assert page.total == 3
        assert {(f.document_title, f.source_slug, f.corpus_class) for f in page.facts} == {
            ("house", "notes", "document"),
            ("email", "mail", "communication"),
        }
        assert dict(page.classes) == {"fact": 2, "event": 1}

    def test_query_matches_stemmed_words_and_substrings(self, db: Session) -> None:
        self._corpus(db)
        assert [f.fact for f in list_facts(db, query="installing heat pumps").facts] == [
            "The heat pump was installed in March 2024."
        ]
        assert [f.fact for f in list_facts(db, query="o'cl").facts] == ["Dinner is at eight o'clock."]
        assert list_facts(db, query="100%").total == 0

    def test_filters_narrow_the_facts_and_the_class_counts_ignore_the_class_filter(self, db: Session) -> None:
        house, _, _ = self._corpus(db)
        assert list_facts(db, source="mail").total == 1
        assert list_facts(db, corpus_class="communication").total == 1
        assert list_facts(db, document_id=house).total == 2
        page = list_facts(db, fact_class="event")
        assert [f.fact_class for f in page.facts] == ["event"]
        assert dict(page.classes) == {"fact": 2, "event": 1}

    def test_a_grounded_fact_carries_its_span_in_context(self, db: Session) -> None:
        _, _, body = self._corpus(db)
        grounded = next(f for f in list_facts(db).facts if f.fact_class == "event")
        assert grounded.char_start is not None and grounded.char_end is not None
        assert grounded.excerpt_start == grounded.char_start - EXCERPT_CONTEXT
        assert grounded.excerpt == body[grounded.excerpt_start : grounded.char_end + EXCERPT_CONTEXT]
        span = grounded.excerpt[
            grounded.char_start - grounded.excerpt_start : grounded.char_end - grounded.excerpt_start
        ]
        assert span == "The heat pump was installed in March 2024."
        ungrounded = next(f for f in list_facts(db).facts if f.fact == "The house has a heat pump.")
        assert ungrounded.excerpt is None

    def test_limit_and_offset_page_through_the_facts(self, db: Session) -> None:
        self._corpus(db)
        first = list_facts(db, limit=2)
        rest = list_facts(db, limit=2, offset=2)
        assert first.total == rest.total == 3
        assert len(first.facts) == 2 and len(rest.facts) == 1
        assert {f.id for f in first.facts}.isdisjoint(f.id for f in rest.facts)

    def test_stats_count_per_source_and_class_under_the_filters(self, db: Session) -> None:
        self._corpus(db)
        stats = fact_stats(db)
        assert (stats.facts, stats.documents) == (3, 2)
        assert stats.by_source == {"notes": 2, "mail": 1}
        assert stats.by_class == {"fact": 2, "event": 1}
        narrowed = fact_stats(db, query="heat pump", fact_class="fact")
        assert (narrowed.facts, narrowed.documents, narrowed.by_source) == (1, 1, {"notes": 1})
        assert fact_stats(db, corpus_class="communication").by_source == {"mail": 1}


class TestFactPrompts:
    """enrich-facts with more than one prompt: per-prompt replacement and stale detection, in real SQL.

    The model is faked (``extract_facts``); everything else -- the egress check,
    the deletes, ``fact_runs`` and the fact chunks -- runs against the server.
    """

    PEOPLE: ClassVar[dict] = {
        "name": "people",
        "description": "List every person named.",
        "corpus_classes": ["document"],
        "examples": [{"text": "Jane met Bob.", "extractions": [{"class": "person", "text": "Jane"}]}],
    }

    @pytest.fixture
    def enrich(self, database_url: str, monkeypatch) -> Iterator:
        from garage_rag.enrich import langextract as lx
        from garage_rag.ops.facts import enrich_facts

        calls: list[str] = []

        def fake_extract_facts(text_: str, *, prompt, **kwargs):
            calls.append(prompt.name)
            word = text_.split()[0]
            return [
                lx.data.Extraction(
                    extraction_class="person" if prompt.name == "people" else "fact",
                    extraction_text=f"{prompt.name}:{word}:{len(calls)}",
                    char_interval=lx.data.CharInterval(start_pos=0, end_pos=len(word)),
                )
            ]

        monkeypatch.setattr("garage_rag.enrich.facts.extract_facts", fake_extract_facts)

        def run(prompts_config: list[dict], *, model: str = "gemma2:2b", **kwargs):
            set_settings(
                Settings(
                    database_url=database_url,
                    fact_provider="ollama",
                    ollama_host="http://127.0.0.1:11434",
                    fact_prompts=prompts_config,
                )
            )
            calls.clear()
            summary = enrich_facts(model=model, **kwargs)
            return summary, list(calls)

        try:
            yield run
        finally:
            set_settings(Settings(database_url=database_url))

    def _facts(self, db: Session) -> list[tuple]:
        db.expire_all()
        return [
            tuple(row)
            for row in db.execute(
                text(
                    "SELECT d.title, f.prompt_name, f.ord, f.fact, f.prompt_sha256 IS NOT NULL, c.id IS NOT NULL "
                    "FROM facts f JOIN documents d ON d.id = f.document_id LEFT JOIN chunks c ON c.fact_id = f.id "
                    "ORDER BY d.title, f.prompt_name, f.ord"
                )
            )
        ]

    def test_prompts_run_per_scope_and_replace_only_their_own_facts(self, db: Session, enrich) -> None:
        source = _source(db, "docs")
        _document(db, source, "memo", "Acme was founded in 1998.")
        _document(db, source, "text", "Hi from Jane.", corpus_class="communication")
        db.commit()

        summary, ran = enrich([self.PEOPLE])
        assert summary.prompts == ["default", "people"]
        assert (summary.total, summary.enriched, summary.facts, summary.failed) == (2, 2, 3, 0)
        # people is scoped to documents, so the communication gets only the default prompt.
        assert ran == ["default", "people", "default"]
        before = self._facts(db)
        assert [row[:3] for row in before] == [("memo", "default", 0), ("memo", "people", 0), ("text", "default", 0)]
        assert all(row[4] and row[5] for row in before)  # hashed, and queued for embedding

        # One prompt again: its facts are replaced, the other prompt's are untouched.
        summary, ran = enrich([self.PEOPLE], prompts=["people"], source="docs")
        assert ran == ["people"]
        assert summary.skipped == 1  # the communication: people does not apply to it
        after = self._facts(db)
        assert after[0] == before[0] and after[2] == before[2]
        assert after[1][3] != before[1][3]
        runs = db.execute(text("SELECT prompt_name, facts FROM fact_runs ORDER BY document_id, prompt_name"))
        assert [tuple(row) for row in runs] == [("default", 1), ("people", 1), ("default", 1)]

    def test_stale_only_redoes_what_changed(self, db: Session, enrich) -> None:
        source = _source(db, "docs")
        memo = _document(db, source, "memo", "Acme was founded in 1998.")
        _document(db, source, "note", "Bob likes tea.")
        db.commit()

        enrich([self.PEOPLE])
        summary, ran = enrich([self.PEOPLE], stale_only=True)
        assert ran == [] and summary.skipped == 2 and summary.enriched == 0

        # A reworded prompt is stale everywhere it applies; the default is not.
        reworded = {**self.PEOPLE, "description": "List every person mentioned by name."}
        _, ran = enrich([reworded], stale_only=True)
        assert ran == ["people", "people"]

        # Changed content makes every prompt stale for that one document.
        db.execute(
            text("UPDATE documents SET content = 'Acme moved.', content_sha256 = :h WHERE id = :d"),
            {"d": memo, "h": b"\x01"},
        )
        db.commit()
        _, ran = enrich([reworded], stale_only=True)
        assert ran == ["default", "people"]

        # And so does another model.
        _, ran = enrich([reworded], stale_only=True, prompts=["default"], model="qwen2.5:7b")
        assert ran == ["default", "default"]

    def test_a_disabled_default_runs_only_when_named(self, db: Session, enrich) -> None:
        _document(db, _source(db, "docs"), "memo", "Acme was founded in 1998.")
        db.commit()
        disabled = [{"name": "default", "enabled": False}, self.PEOPLE]
        _, ran = enrich(disabled)
        assert ran == ["people"]
        _, ran = enrich(disabled, prompts=["default"])
        assert ran == ["default"]
        with pytest.raises(LookupError, match="unknown fact prompt"):
            enrich(disabled, prompts=["nope"])


class TestAge:
    """Apache AGE, which 001 creates wherever the server has it (always in the app)."""

    def test_a_cypher_graph_round_trips(self, db: Session) -> None:
        if not db.execute(text("SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'age')")).scalar_one():
            pytest.skip("this server has no Apache AGE")
        conn = db.connection()
        # The app preloads AGE and puts ag_catalog last on search_path when it starts
        # Postgres; a development server may do neither.
        conn.exec_driver_sql("LOAD 'age'")
        conn.exec_driver_sql("""SET LOCAL search_path = "$user", public, ag_catalog""")
        conn.exec_driver_sql("SELECT create_graph('garage_test_graph')")
        try:
            conn.exec_driver_sql(
                "SELECT * FROM cypher('garage_test_graph', $$ "
                "CREATE (:Person {name: 'Ada'})-[:WROTE]->(:Document {title: 'Notes'}) "
                "$$) AS (result agtype)"
            )
            rows = conn.exec_driver_sql(
                "SELECT name::text, title::text FROM cypher('garage_test_graph', $$ "
                "MATCH (p:Person)-[:WROTE]->(d:Document) RETURN p.name, d.title "
                "$$) AS (name agtype, title agtype)"
            ).all()
            assert [tuple(row) for row in rows] == [("Ada", "Notes")]
        finally:
            conn.exec_driver_sql("SELECT drop_graph('garage_test_graph', true)")
