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
import math
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
from garage_rag.db.emb_tables import get_model, potential_fact_table_name, register_model
from garage_rag.db.engine import reset_engine, session_scope
from garage_rag.db.migrate import _connect, apply_migrations, pending_migrations, sql_dir, to_psycopg_conninfo
from garage_rag.db.registry import ModelSpec
from garage_rag.embed.ollama import count_pending
from garage_rag.ingest.gateway import AuthorPayload, ChunkPayload, SqlAlchemyIngestStorageGateway
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
        tables = session.execute(
            text(
                "SELECT tablename FROM pg_tables WHERE tablename LIKE 'emb\\_%' OR tablename LIKE 'fact\\_emb\\_%' "
                "OR tablename LIKE 'potential\\_fact\\_emb\\_%'"
            )
        ).scalars()
        for table in tables:
            session.execute(text(f'DROP TABLE "{table}"'))
        session.execute(
            text(
                "TRUNCATE sources, authors, embedding_models, distilled_facts, fact_cluster_state "
                "RESTART IDENTITY CASCADE"
            )
        )


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


def _embed_fact(session: Session, model_table: str, fact_id: int, vector: list[float], kind: str = "vector") -> None:
    """A potential fact's vector, in the model's potential-fact table (017_fact_vectors.sql)."""
    session.execute(
        text(
            f"INSERT INTO {potential_fact_table_name(model_table)} (fact_id, embedding) "
            f"VALUES (:id, CAST(:v AS {kind}({len(vector)})))"
        ),
        {"id": fact_id, "v": json.dumps(vector)},
    )


def _fact_chunk(session: Session, document_id: int, fact: str) -> tuple[int, int]:
    """A potential fact of ``document_id`` and its chunk: ``(fact_id, chunk_id)``."""
    ord = session.execute(
        text("SELECT count(*) FROM facts WHERE document_id = :doc"), {"doc": document_id}
    ).scalar_one()
    fact_id = session.execute(
        text("INSERT INTO facts (document_id, ord, fact) VALUES (:doc, :ord, :fact) RETURNING id"),
        {"doc": document_id, "ord": ord, "fact": fact},
    ).scalar_one()
    chunk_id = session.execute(
        text(
            "INSERT INTO chunks (document_id, ord, text, chunk_sha256, chunker, fact_id) "
            "VALUES (:doc, :ord, :fact, :sha, 'facts:test', :fact_id) RETURNING id"
        ),
        {
            "doc": document_id,
            "ord": 1000 + ord,
            "fact": fact,
            "sha": hashlib.sha256(fact.encode()).digest(),
            "fact_id": fact_id,
        },
    ).scalar_one()
    return fact_id, chunk_id


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

    @pytest.mark.parametrize("dims", [8, 4096])
    def test_017_moves_fact_vectors_to_their_own_table(self, db: Session, dims: int) -> None:
        """A model registered before 017 kept fact vectors in its chunk table; re-applied,
        017 moves them once and rebuilds the chunk table's vector index beside them."""
        model = register_model(db, ModelSpec(slug="old", model_ref="old", dims=dims))
        facts = potential_fact_table_name(model.table_name)
        db.execute(text(f"DROP TABLE {facts}"))
        source = _source(db, "notes")
        content = _chunk(db, source, "heat-pumps", "Heat pumps lose efficiency in deep cold.")
        fact_id, fact_chunk = _fact_chunk(db, _document(db, source, "roof", "The roof is slate."), "The roof is slate.")
        _embed(db, model.table_name, content, _halves(dims, 1.0))
        _embed(db, model.table_name, fact_chunk, _halves(dims, -1.0))
        db.flush()

        migration = (sql_dir() / "017_fact_vectors.sql").read_text(encoding="utf-8")
        db.connection().exec_driver_sql(migration)
        db.connection().exec_driver_sql(migration)  # and again: idempotent

        assert list(db.execute(text(f"SELECT chunk_id FROM {model.table_name}")).scalars()) == [content]
        assert list(db.execute(text(f"SELECT fact_id FROM {facts}")).scalars()) == [fact_id]
        chunk_index = _index_definition(db, model.table_name)
        fact_index = _index_definition(db, facts)
        assert fact_index == chunk_index.replace(model.table_name, facts)
        assert (
            db.execute(
                text(
                    "SELECT format_type(atttypid, atttypmod) FROM pg_attribute WHERE attrelid = CAST(:t AS regclass) "
                    "AND attname = 'embedding'"
                ),
                {"t": facts},
            ).scalar_one()
            == f"vector({dims})"
        )

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

    @pytest.mark.parametrize(
        ("dims", "ops"), [(8, "vector_cosine_ops"), (3000, "halfvec_cosine_ops"), (4096, "bit_hamming_ops")]
    )
    def test_potential_facts_get_a_table_and_index_of_their_own(self, db: Session, dims: int, ops: str) -> None:
        model = register_model(db, ModelSpec(slug="m", model_ref="m", dims=dims))
        table = potential_fact_table_name(model.table_name)
        assert ops in _index_definition(db, table)
        key = db.execute(
            text(
                "SELECT a.attname, cf.relname FROM pg_constraint k "
                "JOIN pg_attribute a ON a.attrelid = k.conrelid AND a.attnum = k.conkey[1] "
                "JOIN pg_class cf ON cf.oid = k.confrelid WHERE k.conrelid = CAST(:t AS regclass) AND k.contype = 'f'"
            ),
            {"t": table},
        ).one()
        assert tuple(key) == ("fact_id", "facts")


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

    @pytest.mark.parametrize("dims", [8, 4096])
    def test_vector_search_finds_potential_facts_in_their_own_table(self, db: Session, dims: int) -> None:
        model = register_model(db, ModelSpec(slug="m", model_ref="m", dims=dims))
        source = _source(db, "notes")
        bread = _chunk(db, source, "sourdough", "A sourdough starter needs wild yeast and flour.")
        heat = _document(db, source, "heat-pumps", "Heat pumps lose efficiency in deep cold.")
        fact_id, _ = _fact_chunk(db, heat, "Heat pumps lose efficiency in deep cold.")
        _embed(db, model.table_name, bread, _halves(dims, -1.0))
        _embed_fact(db, model.table_name, fact_id, _halves(dims, 1.0))
        db.flush()
        assert self._search(db, model.slug, dims, mode="vector") == ["heat-pumps", "sourdough"]

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


class TestMessageAuthors:
    """Messages authors first named after a phone number take the contact name when it arrives."""

    @staticmethod
    def _thread(gateway: SqlAlchemyIngestStorageGateway, uri: str, authors: list[AuthorPayload]) -> None:
        content = f"thread {uri} " + " ".join(a.name for a in authors)
        with patch("garage_rag.attribute.resolver.ensure_self_author"):
            gateway.replace_document(
                0,
                "sms",
                uri,
                title=uri,
                lang=None,
                byte_size=len(content),
                mtime=1.8e9,
                source_sha256=None,
                content_sha256=hashlib.sha256(content.encode()).hexdigest(),
                extractor="messages",
                extractor_version="1",
                chunker="test",
                content=content,
                meta={},
                corpus_class="communication",
                trust_tier="received",
                authors=authors,
                chunks=[ChunkPayload(ord=0, text=content, chunk_sha256=hashlib.sha256(content.encode()).hexdigest())],
            )

    @staticmethod
    def _handle(handle: str, name: str | None = None) -> AuthorPayload:
        kind = "email" if "@" in handle else "phone"
        return AuthorPayload(name=name or handle, role="sender", identities={kind: handle}, evidence="imessage-handle")

    def _authors(self, db: Session) -> dict[str, set[str]]:
        db.expire_all()
        rows = db.execute(
            text(
                "SELECT a.display_name, ai.value FROM authors a JOIN author_identities ai ON ai.author_id = a.id "
                "ORDER BY a.id, ai.value"
            )
        )
        found: dict[str, set[str]] = {}
        for name, value in rows:
            found.setdefault(name, set()).add(value)
        return found

    def test_a_handle_named_author_is_renamed_and_its_other_handle_merged(self, db: Session) -> None:
        _source(db, "sms")
        db.commit()
        gateway = SqlAlchemyIngestStorageGateway(session_factory=session_scope)
        self._thread(gateway, "a", [self._handle("+15551234567")])
        self._thread(gateway, "b", [self._handle("alex@example.com")])
        assert self._authors(db) == {"+15551234567": {"+15551234567"}, "alex@example.com": {"alex@example.com"}}

        self._thread(gateway, "a", [self._handle("+15551234567", "Alex Doe")])
        self._thread(gateway, "c", [self._handle("alex@example.com", "Alex Doe")])
        assert self._authors(db) == {"Alex Doe": {"+15551234567", "alex@example.com"}}
        # Thread b was not rebuilt, yet its link followed the merged author.
        linked = db.execute(
            text(
                "SELECT d.uri, a.display_name FROM document_authors da JOIN documents d ON d.id = da.document_id "
                "JOIN authors a ON a.id = da.author_id ORDER BY d.uri"
            )
        ).all()
        assert [tuple(row) for row in linked] == [("a", "Alex Doe"), ("b", "Alex Doe"), ("c", "Alex Doe")]

        # The author filter finds the threads by name and still by number.
        by_name = {hit.title for hit in search(db, "thread", mode="fts", author="alex doe")}
        by_number = {hit.title for hit in search(db, "thread", mode="fts", author="5551234567")}
        assert by_name == {"a", "b", "c"}
        assert by_number == {"a", "b", "c"}

    def test_a_named_author_is_not_renamed_by_a_handle(self, db: Session) -> None:
        _source(db, "sms")
        db.commit()
        gateway = SqlAlchemyIngestStorageGateway(session_factory=session_scope)
        self._thread(gateway, "a", [self._handle("+15551234567", "Alex Doe")])
        self._thread(gateway, "b", [self._handle("+15551234567")])
        self._thread(gateway, "c", [self._handle("+15551234567", "Alexander")])
        assert self._authors(db) == {"Alex Doe": {"+15551234567"}}


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


class TestDistilledFacts:
    """cluster-facts over real vectors: restatements per document, groups across the corpus, the model's
    say, incremental placement, and the distilled layer's vectors."""

    @staticmethod
    def _direction(angle_degrees: float, axis: int = 0) -> list[float]:
        """A unit vector in the plane of ``axis`` and ``axis + 1``; the cosine of two is the cosine of their angle."""
        import math

        vector = [0.0] * 8
        vector[axis] = math.cos(math.radians(angle_degrees))
        vector[axis + 1] = math.sin(math.radians(angle_degrees))
        return vector

    def _setup(self, db: Session):
        model = register_model(db, ModelSpec(slug="m", model_ref="m", dims=8))
        self._source_id = _source(db, "notes")
        self._documents = 0
        return model

    def _doc(self, db: Session, *, corpus_class: str = "document") -> int:
        self._documents += 1
        title = f"doc{self._documents}"
        return _document(db, self._source_id, title, f"The {title} notes.", corpus_class=corpus_class)

    def _fact(
        self, db: Session, model, document_id: int, fact: str, vector: list[float] | None, *, table: str | None = None
    ) -> int:
        fact_id, _ = _fact_chunk(db, document_id, fact)
        if vector is not None:
            _embed_fact(db, table or model.table_name, fact_id, vector)
        return fact_id

    def _groups(self, db: Session) -> list[list[str]]:
        """The potential facts behind each distilled fact that has more than one."""
        rows = db.execute(
            text(
                "SELECT f.distilled_fact_id, f.fact FROM facts f WHERE f.distilled_fact_id IN "
                "(SELECT distilled_fact_id FROM facts GROUP BY 1 HAVING count(*) > 1) ORDER BY 1, f.id"
            )
        ).all()
        grouped: dict[int, list[str]] = {}
        for distilled_id, fact in rows:
            grouped.setdefault(distilled_id, []).append(fact)
        return list(grouped.values())

    def _run(self, db: Session, model, distiller=None, *, full: bool = False, **overrides):
        from garage_rag.enrich.clusters import ClusterParams, cluster_facts

        params = {
            "threshold": 0.9,
            "neighbors": 10,
            "seed_threshold": 0.95,
            "max_drift": 0.05,
            "tight_similarity": 0.97,
            "restate_threshold": 0.92,
            **overrides,
        }
        return cluster_facts(db, model, ClusterParams(**params), full=full, distiller=distiller)

    def _distiller(self, answer) -> MagicMock:
        distiller = MagicMock()
        distiller.model_id = "llama_xpc/test"
        distiller.may_send.return_value = True
        distiller.distill.side_effect = answer
        return distiller

    def _ids(self, db: Session) -> list[int]:
        return sorted(db.execute(text("SELECT id FROM distilled_facts")).scalars())

    def test_a_documents_restatements_point_at_its_representative(self, db: Session) -> None:
        model = self._setup(db)
        doc = self._doc(db)
        rep = self._fact(db, model, doc, "The heat pump was installed in 2024.", self._direction(0))
        self._fact(db, model, doc, "In 2024 the heat pump was installed.", self._direction(5))
        self._fact(db, model, doc, "A heat pump went in during 2024.", self._direction(10))
        # Close in vector space, but the number or the negation differs.
        self._fact(db, model, doc, "The heat pump was installed in 2023.", self._direction(3))
        self._fact(db, model, doc, "The heat pump was not installed in 2024.", self._direction(4))
        self._fact(db, model, doc, "The roof is slate.", self._direction(0, axis=4))
        # No vector yet, but the same text as the representative.
        same = self._fact(db, model, doc, "the heat pump was installed in 2024!", None)
        db.flush()

        state = self._run(db, model)

        assert (state.facts, state.unembedded, state.restatements) == (7, 1, 3)
        assert self._groups(db) == [
            [
                "The heat pump was installed in 2024.",
                "In 2024 the heat pump was installed.",
                "A heat pump went in during 2024.",
                "the heat pump was installed in 2024!",
            ]
        ]
        rows = db.execute(
            text("SELECT restates_fact_id, restates_similarity, dedup_key FROM facts WHERE id = :id"), {"id": same}
        ).one()
        assert rows == (rep, 1.0, None)
        assert db.execute(text("SELECT count(*) FROM facts WHERE dedup_key = 'm;t=0.92'")).scalar_one() == 6
        # One document has no corpus-level groups: four distilled facts, each a single node.
        assert (state.clusters, state.distilled_facts) == (0, 4)
        assert db.execute(text("SELECT count(*) FROM facts WHERE distilled_fact_id IS NULL")).scalar_one() == 0
        assert db.execute(text("SELECT count(*) FROM fact_emb_m WHERE seed IS NOT NULL")).scalar_one() == 4

    def test_restatements_across_documents_grow_into_one_tight_group(self, db: Session) -> None:
        model = self._setup(db)
        self._fact(db, model, self._doc(db), "Ada wrote the notes.", self._direction(0))
        self._fact(db, model, self._doc(db), "The notes were written by Ada.", self._direction(5))
        self._fact(db, model, self._doc(db), "Ada is the author of the notes.", self._direction(10))
        self._fact(db, model, self._doc(db), "The roof is slate.", self._direction(0, axis=4))
        db.flush()

        distiller = self._distiller(None)
        state = self._run(db, model, distiller)

        assert state.full
        assert (state.clusters, state.clustered_facts, state.distilled_facts, state.accepted) == (1, 3, 2, 1)
        # Tight enough to keep without asking.
        assert distiller.distill.call_count == 0
        nodes, spread, drift, statement = db.execute(
            text("SELECT nodes, spread, drift, statement FROM distilled_facts WHERE model_slug = 'm'")
        ).one()
        assert nodes == 3 and 0 < spread < 0.01 and drift < 0.01
        assert statement == "Ada is the author of the notes."
        assert db.execute(text("SELECT count(*) FROM fact_emb_m WHERE seed IS NOT NULL")).scalar_one() == 2

    def test_a_loose_group_is_shown_to_the_model(self, db: Session) -> None:
        model = self._setup(db)
        # cos(20°) ≈ 0.94 to the middle one, cos(40°) ≈ 0.77 end to end.
        for angle, fact in ((0, "Alpha one."), (20, "Alpha two."), (40, "Alpha three.")):
            self._fact(db, model, self._doc(db), fact, self._direction(angle))
        db.flush()

        distiller = self._distiller(lambda facts: (False, None))
        state = self._run(db, model, distiller)
        assert (state.candidates, state.to_distill, state.accepted) == (1, 1, 0)
        assert distiller.distill.call_count == 1
        assert (state.dissolved, state.clusters, state.distilled_facts) == (1, 0, 3)

    def test_the_model_states_or_rejects_each_group_and_reruns_keep_what_it_said(self, db: Session) -> None:
        model = self._setup(db)
        self._fact(db, model, self._doc(db), "Ada wrote the notes.", self._direction(0))
        self._fact(db, model, self._doc(db), "The notes were written by Ada.", self._direction(5))
        self._fact(db, model, self._doc(db), "Bob owns the car.", self._direction(0, axis=4))
        self._fact(db, model, self._doc(db), "Bob drives the car.", self._direction(5, axis=4))
        db.flush()

        distiller = self._distiller(
            lambda facts: (True, "Ada wrote the notes.") if "Ada" in facts[0] else (False, None)
        )
        state = self._run(db, model, distiller, tight_similarity=1.0)
        assert (state.clusters, state.dissolved, state.distilled_facts) == (1, 1, 3)
        assert db.execute(
            text("SELECT statement, statement_generated, distill_model FROM distilled_facts WHERE model_slug = 'm'")
        ).one() == ("Ada wrote the notes.", True, "llama_xpc/test")
        first_ids = self._ids(db)

        # Nothing new: an incremental run asks nothing and changes nothing.
        distiller = self._distiller(lambda facts: (True, "changed"))
        state = self._run(db, model, distiller, tight_similarity=1.0)
        assert not state.full and distiller.distill.call_count == 0
        assert self._ids(db) == first_ids

        # A full run finds Ada's group again and keeps it by its members; only Bob's is asked about.
        distiller = self._distiller(lambda facts: (False, None) if "Bob" in facts[0] else (True, "changed"))
        state = self._run(db, model, distiller, full=True, tight_similarity=1.0)
        assert state.full and distiller.distill.call_count == 1
        assert (state.kept, state.clusters) == (1, 1)
        assert self._ids(db) == first_ids
        assert db.execute(text("SELECT statement FROM distilled_facts WHERE model_slug = 'm'")).scalar_one() == (
            "Ada wrote the notes."
        )

    def test_a_loose_group_of_communications_is_not_sent_off_the_machine(self, db: Session) -> None:
        model = self._setup(db)
        self._fact(db, model, self._doc(db, corpus_class="communication"), "Dinner is at eight.", self._direction(0))
        self._fact(
            db, model, self._doc(db, corpus_class="communication"), "Dinner starts at eight.", self._direction(5)
        )
        db.flush()

        distiller = self._distiller(None)
        distiller.may_send.return_value = False
        state = self._run(db, model, distiller, tight_similarity=1.0)
        assert distiller.distill.call_count == 0
        assert list(distiller.may_send.call_args.args[0]) == ["communication", "communication"]
        # Not kept unconfirmed: the two stay apart.
        assert (state.withheld, state.clusters, state.distilled_facts) == (1, 0, 2)

    def test_an_incremental_run_attaches_new_facts_to_groups_and_single_facts(self, db: Session) -> None:
        model = self._setup(db)
        self._fact(db, model, self._doc(db), "Ada wrote the notes.", self._direction(0))
        self._fact(db, model, self._doc(db), "The notes were written by Ada.", self._direction(5))
        self._fact(db, model, self._doc(db), "The roof is slate.", self._direction(0, axis=4))
        db.flush()
        self._run(db, model)
        group = db.execute(text("SELECT id FROM distilled_facts WHERE model_slug = 'm'")).scalar_one()
        roof = db.execute(text("SELECT id FROM distilled_facts WHERE model_slug IS NULL")).scalar_one()

        self._fact(db, model, self._doc(db), "Ada authored the notes.", self._direction(3))
        self._fact(db, model, self._doc(db), "The roof is made of slate.", self._direction(3, axis=4))
        self._fact(db, model, self._doc(db), "The dog is called Rex.", self._direction(0, axis=2))
        db.flush()
        state = self._run(db, model)

        assert not state.full
        assert (state.nodes, state.attached) == (3, 2)
        assert db.execute(text("SELECT nodes FROM distilled_facts WHERE id = :id"), {"id": group}).scalar_one() == 3
        # The single fact became a group, keeping its id.
        assert db.execute(text("SELECT nodes, model_slug FROM distilled_facts WHERE id = :id"), {"id": roof}).one() == (
            2,
            "m",
        )
        assert state.distilled_facts == 3

    def test_losing_nodes_re_centres_a_group_and_then_leaves_a_single_fact(self, db: Session) -> None:
        model = self._setup(db)
        first = self._fact(db, model, self._doc(db), "Ada wrote the notes.", self._direction(0))
        second = self._fact(db, model, self._doc(db), "The notes were written by Ada.", self._direction(5))
        self._fact(db, model, self._doc(db), "Ada is the author of the notes.", self._direction(10))
        db.flush()
        self._run(db, model)
        (group,) = self._ids(db)

        db.execute(text("DELETE FROM facts WHERE id = :id"), {"id": first})
        state = self._run(db, model)
        assert state.clusters == 1
        assert db.execute(text("SELECT nodes FROM distilled_facts WHERE id = :id"), {"id": group}).scalar_one() == 2

        db.execute(text("DELETE FROM facts WHERE id = :id"), {"id": second})
        state = self._run(db, model)
        assert (state.clusters, state.distilled_facts) == (0, 1)
        assert db.execute(text("SELECT id, statement, model_slug, nodes FROM distilled_facts")).one() == (
            group,
            "Ada is the author of the notes.",
            None,
            1,
        )

    def test_list_facts_collapses_and_reports_distilled_facts(self, db: Session) -> None:
        model = self._setup(db)
        self._fact(db, model, self._doc(db), "Ada wrote the notes.", self._direction(0))
        doc = self._doc(db)
        written = self._fact(db, model, doc, "The notes were written by Ada.", self._direction(5))
        again = self._fact(db, model, doc, "the notes were written by Ada", None)
        self._fact(db, model, self._doc(db), "The roof is slate.", self._direction(0, axis=4))
        db.flush()
        self._run(db, model)

        page = list_facts(db)
        assert page.total == 4
        assert sorted(f.distilled_size for f in page.facts) == [1, 3, 3, 3]
        assert next(f for f in page.facts if f.id == again).restates_fact_id == written
        assert next(f for f in page.facts if f.id == written).restates_fact_id is None

        collapsed = list_facts(db, collapse=True)
        assert collapsed.total == 2
        assert {f.fact for f in collapsed.facts} == {"The notes were written by Ada.", "The roof is slate."}

        grouped = next(f for f in page.facts if f.distilled_size == 3)
        assert list_facts(db, distilled_fact_id=grouped.distilled_fact_id).total == 3
        stats = fact_stats(db)
        assert (stats.distilled, stats.clusters, stats.clustered_facts) == (2, 1, 3)

    def test_backfill_averages_each_group_under_other_models(self, db: Session) -> None:
        from garage_rag.embed.ollama import BackfillProgress, backfill_distilled

        model = self._setup(db)
        other = register_model(db, ModelSpec(slug="m2", model_ref="m2", dims=8))
        ada = self._fact(db, model, self._doc(db), "Ada wrote the notes.", self._direction(0))
        written = self._fact(db, model, self._doc(db), "The notes were written by Ada.", self._direction(5))
        roof = self._fact(db, model, self._doc(db), "The roof is slate.", self._direction(0, axis=4))
        for fact_id, vector in ((ada, self._direction(0, axis=2)), (roof, self._direction(0, axis=6))):
            _embed_fact(db, other.table_name, fact_id, vector)
        db.flush()
        self._run(db, model)

        def distilled(embedding_model) -> int:
            state = BackfillProgress()
            backfill_distilled(db, embedding_model, state)
            return state.distilled

        # The clustering model already has every distilled fact's vector.
        assert distilled(model) == 0
        # The group waits until both its nodes have a vector under m2.
        assert distilled(other) == 1
        _embed_fact(db, other.table_name, written, self._direction(10, axis=2))
        db.flush()
        assert distilled(other) == 1
        assert distilled(other) == 0

        vectors = dict(
            db.execute(
                text(
                    "SELECT df.statement, fe.embedding::text FROM fact_emb_m2 fe "
                    "JOIN distilled_facts df ON df.id = fe.distilled_fact_id"
                )
            ).all()
        )
        assert vectors["The roof is slate."] == "[0,0,0,0,0,0,1,0]"
        # The normalized mean of 0° and 10°: 5° on the same axis.
        mean = [float(x) for x in vectors["The notes were written by Ada."].strip("[]").split(",")]
        assert mean == pytest.approx(self._direction(5, axis=2), abs=1e-6)

    # -- anchors: metadata facts are ground truth ---------------------------------------

    def _metadata(
        self,
        db: Session,
        model,
        document_id: int,
        fact: str,
        key: str,
        vector: list[float] | None,
        *,
        fact_class: str = "sender",
        table: str | None = None,
    ) -> int:
        ord = db.execute(
            text("SELECT count(*) FROM facts WHERE document_id = :doc AND prompt_name = 'metadata'"),
            {"doc": document_id},
        ).scalar_one()
        fact_id = db.execute(
            text(
                "INSERT INTO facts (document_id, ord, fact, fact_class, attributes, extractor, prompt_name) "
                "VALUES (:doc, :ord, :fact, :cls, CAST(:attrs AS jsonb), 'metadata', 'metadata') RETURNING id"
            ),
            {"doc": document_id, "ord": ord, "fact": fact, "cls": fact_class, "attrs": json.dumps({"key": key})},
        ).scalar_one()
        db.execute(
            text(
                "INSERT INTO chunks (document_id, ord, text, chunk_sha256, chunker, fact_id) "
                "VALUES (:doc, :ord, :fact, :sha, 'facts:metadata:1', :id)"
            ),
            {
                "doc": document_id,
                "ord": 2000 + ord,
                "fact": fact,
                "sha": hashlib.sha256(fact.encode()).digest(),
                "id": fact_id,
            },
        )
        if vector is not None:
            _embed_fact(db, table or model.table_name, fact_id, vector)
        return fact_id

    def _sender_fact(self, db: Session, model, fact: str, vector: list[float]) -> int:
        """An inferred fact of the ``sender`` class, as an entity prompt might extract."""
        fact_id = self._fact(db, model, self._doc(db), fact, vector)
        db.execute(text("UPDATE facts SET fact_class = 'sender' WHERE id = :id"), {"id": fact_id})
        return fact_id

    def _anchor(self, db: Session, fact_id: int) -> tuple:
        return db.execute(
            text(
                "SELECT df.id, df.anchor_key, df.statement, df.nodes, df.drift, fe.embedding::text, fe.seed::text "
                "FROM facts f JOIN distilled_facts df ON df.id = f.distilled_fact_id "
                "LEFT JOIN fact_emb_m fe ON fe.distilled_fact_id = df.id WHERE f.id = :id"
            ),
            {"id": fact_id},
        ).one()

    def test_metadata_facts_link_to_one_anchor_by_their_key(self, db: Session) -> None:
        model = self._setup(db)
        first = self._metadata(db, model, self._doc(db), "Ada <ada@example.com>", "author:1", self._direction(0))
        # Far apart by vector, and one with no vector yet: the key decides, not the embedding.
        again = self._metadata(db, model, self._doc(db), "ada@example.com", "author:1", self._direction(60))
        unembedded = self._metadata(db, model, self._doc(db), "Ada", "author:1", None)
        other = self._metadata(db, model, self._doc(db), "Bob <bob@example.com>", "author:2", self._direction(1))
        db.flush()
        state = self._run(db, model)

        anchor = self._anchor(db, first)
        assert anchor[1:5] == ("author:1", "Ada <ada@example.com>", 3, 0)
        assert self._anchor(db, again)[0] == self._anchor(db, unembedded)[0] == anchor[0]
        # Bob is 1 degree from Ada but another value: his own anchor.
        assert self._anchor(db, other)[1] == "author:2"
        assert anchor[5] == anchor[6] == "[1,0,0,0,0,0,0,0]"
        assert state.anchors == 2
        # Metadata facts take no part in level 1.
        assert db.execute(text("SELECT count(*) FROM facts WHERE restates_fact_id IS NOT NULL")).scalar_one() == 0

    @pytest.mark.parametrize("full", [False, True])
    def test_an_inferred_fact_joins_an_anchor_without_moving_it(self, db: Session, full: bool) -> None:
        model = self._setup(db)
        ada = self._metadata(db, model, self._doc(db), "Ada Lovelace", "author:1", self._direction(0))
        db.flush()
        self._run(db, model)
        close = self._sender_fact(db, model, "Ada Lovelace (Analytical Engine)", self._direction(10))
        far = self._sender_fact(db, model, "Charles Babbage", self._direction(40))
        # Another inferred fact close to the one that joins, but past the anchor's threshold.
        self._sender_fact(db, model, "Countess Lovelace", self._direction(28))
        db.flush()
        state = self._run(db, model, full=full)

        anchor = self._anchor(db, ada)
        assert self._anchor(db, close)[0] == anchor[0]
        assert self._anchor(db, far)[0] != anchor[0]
        # Fixed: the centroid is still Ada's own vector, nothing drifted, no model was asked.
        assert anchor[5] == anchor[6] == "[1,0,0,0,0,0,0,0]"
        assert (anchor[3], anchor[4]) == (2, 0)
        assert state.anchored == 1
        similarity = db.execute(text("SELECT distilled_similarity FROM facts WHERE id = :id"), {"id": close}).scalar()
        assert similarity == pytest.approx(math.cos(math.radians(10)), abs=1e-5)

    def test_a_full_run_keeps_each_anchor(self, db: Session) -> None:
        model = self._setup(db)
        ada = self._metadata(db, model, self._doc(db), "Ada", "author:1", self._direction(0))
        db.flush()
        self._run(db, model)
        before = self._anchor(db, ada)[0]
        self._run(db, model, full=True)
        assert self._anchor(db, ada)[0] == before

    def test_an_anchor_goes_with_the_last_fact_stating_its_value(self, db: Session) -> None:
        model = self._setup(db)
        ada = self._metadata(db, model, self._doc(db), "Ada", "author:1", self._direction(0))
        joined = self._sender_fact(db, model, "Ada L.", self._direction(5))
        db.flush()
        self._run(db, model)
        assert self._anchor(db, joined)[0] == self._anchor(db, ada)[0]

        db.execute(text("DELETE FROM facts WHERE id = :id"), {"id": ada})
        db.flush()
        state = self._run(db, model)
        assert state.anchors == 0
        # The fact that had joined it stands alone again.
        assert self._anchor(db, joined)[1:4] == (None, "Ada L.", 1)

    def test_a_new_representative_refixes_the_anchor(self, db: Session) -> None:
        model = self._setup(db)
        first = self._metadata(db, model, self._doc(db), "Ada <ada@example.com>", "author:1", self._direction(0))
        second = self._metadata(db, model, self._doc(db), "ada@example.com", "author:1", self._direction(20))
        db.flush()
        self._run(db, model)
        anchor_id = self._anchor(db, first)[0]
        db.execute(text("DELETE FROM facts WHERE id = :id"), {"id": first})
        db.flush()
        self._run(db, model)
        anchor = self._anchor(db, second)
        assert anchor[0] == anchor_id
        assert anchor[2] == "ada@example.com"
        assert [float(x) for x in anchor[5].strip("[]").split(",")] == pytest.approx(self._direction(20), abs=1e-6)

    def test_backfill_gives_an_anchor_its_representatives_vector(self, db: Session) -> None:
        from garage_rag.embed.ollama import BackfillProgress, backfill_distilled

        model = self._setup(db)
        other = register_model(db, ModelSpec(slug="m2", model_ref="m2", dims=8))
        first = self._metadata(db, model, self._doc(db), "Ada", "author:1", self._direction(0))
        second = self._metadata(db, model, self._doc(db), "Ada L", "author:1", self._direction(1))
        _embed_fact(db, other.table_name, first, self._direction(0, axis=2))
        _embed_fact(db, other.table_name, second, self._direction(60, axis=2))
        db.flush()
        self._run(db, model)
        backfill_distilled(db, other, BackfillProgress())
        vector = db.execute(text("SELECT embedding::text FROM fact_emb_m2")).scalar_one()
        assert vector == "[0,0,1,0,0,0,0,0]"

    def test_enrich_writes_a_mails_metadata_facts(self, db: Session) -> None:
        from garage_rag.db.models import Document
        from garage_rag.enrich.metadata import store_metadata_facts

        source = _source(db, "mail")
        content = (
            "Subject: Re: Roof quote\nFrom: Ada Lovelace <ada@example.com>\n"
            "To: bob@example.com, Carol <carol@example.com>\n\nThe quote is attached."
        )
        document_id = _document(db, source, "Re: Roof quote", content, corpus_class="communication")
        meta = {
            "email_from": "Ada Lovelace <ada@example.com>",
            "email_to": "bob@example.com, Carol <carol@example.com>",
        }
        db.execute(
            text("UPDATE documents SET meta = CAST(:meta AS jsonb) WHERE id = :id"),
            {"meta": json.dumps(meta), "id": document_id},
        )
        author = db.execute(
            text("INSERT INTO authors (display_name) VALUES ('Ada Lovelace') RETURNING id")
        ).scalar_one()
        db.execute(
            text("INSERT INTO author_identities (author_id, kind, value) VALUES (:a, 'email', 'Ada@Example.com')"),
            {"a": author},
        )
        db.flush()
        document = db.get(Document, document_id)
        store_metadata_facts(db, document)
        store_metadata_facts(db, document)  # and again: replaced, not added
        db.flush()

        rows = db.execute(
            text(
                "SELECT f.fact_class, f.fact, f.attributes->>'key', substr(d.content, f.char_start + 1, "
                "f.char_end - f.char_start), c.chunker FROM facts f JOIN documents d ON d.id = f.document_id "
                "JOIN chunks c ON c.fact_id = f.id ORDER BY f.ord"
            )
        ).all()
        assert [tuple(r) for r in rows] == [
            (
                "sender",
                "Ada Lovelace <ada@example.com>",
                f"author:{author}",
                "Ada Lovelace <ada@example.com>",
                "facts:metadata:1",
            ),
            ("recipient", "bob@example.com", "email:bob@example.com", "bob@example.com", "facts:metadata:1"),
            (
                "recipient",
                "Carol <carol@example.com>",
                "email:carol@example.com",
                "Carol <carol@example.com>",
                "facts:metadata:1",
            ),
            ("subject", "Re: Roof quote", "subject:roof quote", "Re: Roof quote", "facts:metadata:1"),
        ]
        run = db.execute(text("SELECT facts, extractor_model FROM fact_runs WHERE prompt_name = 'metadata'")).one()
        assert tuple(run) == (4, "metadata")

    def test_the_configured_graph_projects_classes_and_relations(self, db: Session) -> None:
        """The projection's selects over real rows (AGE itself is not needed to run them)."""
        from garage_rag.config.fact_prompts import FactPrompt, effective_prompts, graph_schema
        from garage_rag.db.graph import EDGES, VERTICES, projection

        model = self._setup(db)
        doc = self._doc(db)

        def fact(text_: str, fact_class: str, attributes: dict) -> int:
            fact_id = self._fact(db, model, doc, text_, None)
            db.execute(
                text("UPDATE facts SET fact_class = :c, attributes = CAST(:a AS jsonb) WHERE id = :id"),
                {"c": fact_class, "a": json.dumps(attributes), "id": fact_id},
            )
            return fact_id

        jane = fact("Jane", "person", {"name": "Jane Doe"})
        acme = fact("Acme Corp", "organization", {})
        works = fact(
            "Jane works at Acme Corp.",
            "relation",
            {"subject": "Jane Doe", "object": "acme corp", "predicate": "works at"},
        )
        likes = fact(
            "Jane likes Acme Corp.", "relation", {"subject": "Jane", "object": "Acme Corp", "predicate": "likes"}
        )
        fact("Jane met Bob.", "relation", {"subject": "Jane", "object": "Bob", "predicate": "works at"})
        db.flush()
        self._run(db, model)
        distilled = dict(db.execute(text("SELECT id, distilled_fact_id FROM facts")).all())

        prompt = FactPrompt.model_validate(
            {
                "name": "entities",
                "description": "Extract.",
                "examples": [{"text": "x", "extractions": [{"text": "x"}]}],
                "graph": {
                    "vertices": [
                        {"class": "person", "label": "Person", "title": "name"},
                        {"class": "organization", "label": "Organization"},
                    ],
                    "edges": [
                        {
                            "class": "relation",
                            "source": "subject",
                            "source_class": "person",
                            "target": "object",
                            "target_class": "organization",
                            "label_attribute": "predicate",
                            "labels": ["WORKS_AT"],
                        }
                    ],
                },
            }
        )
        vertices, edges = projection(graph_schema(effective_prompts([prompt])))

        def rows(select: str, params: dict) -> list[tuple]:
            return [tuple(r) for r in db.execute(text(select), params).all()]

        by_label = {v.label: rows(v.select, v.params) for v in vertices if v.label not in ("Document", "Chunk")}
        person = by_label["Person"]
        assert [(rid, p["title"], p["statement"]) for rid, p in person] == [(distilled[jane], "Jane Doe", "Jane")]
        assert [rid for rid, _ in by_label["Organization"]] == [distilled[acme]]
        # Neither is a Fact vertex any more; the relations still are.
        fact_ids = {rid for rid, _ in by_label["Fact"]}
        assert distilled[jane] not in fact_ids and distilled[acme] not in fact_ids and distilled[works] in fact_ids

        relation_edges = {e.label: rows(e.select, e.params) for e in edges if e.label not in EDGES}
        # Resolved in the fact's document by the person's title and the organization's text, case-folded;
        # an unknown predicate takes the fallback; an end that names nothing is left out.
        assert [(s_, t, p["fact_id"], p["predicate"]) for s_, t, p in relation_edges["WORKS_AT"] if t is not None] == [
            (distilled[jane], distilled[acme], works, "works at")
        ]
        assert [(s_, t, p["fact_id"]) for s_, t, p in relation_edges["RELATED_TO"]] == [
            (distilled[jane], distilled[acme], likes)
        ]
        supports = [(e.target, rows(e.select, e.params)) for e in edges if e.label == "SUPPORTS"]
        assert {t: sorted(r[0] for r in found) for t, found in supports if t != "Fact"} == {
            "Person": [jane],
            "Organization": [acme],
        }
        assert not {jane, acme} & {r[0] for t, found in supports if t == "Fact" for r in found}
        assert set(VERTICES) <= {v.label for v in vertices}

    def test_dropping_a_model_drops_its_distilled_fact_table(self, db: Session) -> None:
        from garage_rag.db.emb_tables import drop_model

        register_model(db, ModelSpec(slug="m", model_ref="m", dims=8))
        assert db.execute(text("SELECT to_regclass('fact_emb_m') IS NOT NULL")).scalar_one()
        drop_model(db, "m")
        assert not db.execute(text("SELECT to_regclass('fact_emb_m') IS NOT NULL")).scalar_one()

    def test_the_graph_projects_documents_chunks_authors_and_both_kinds_of_fact(self, db: Session) -> None:
        from garage_rag.db.graph import age_available, rebuild_graph, use_age

        if not age_available(db):
            pytest.skip("this server has no Apache AGE")
        model = self._setup(db)
        doc = self._doc(db)
        db.execute(
            text("INSERT INTO chunks (document_id, ord, text, chunk_sha256, chunker) VALUES (:d, 0, 'x', :s, 't')"),
            {"d": doc, "s": b"x"},
        )
        author = db.execute(text("INSERT INTO authors (display_name) VALUES ('Ada') RETURNING id")).scalar_one()
        db.execute(
            text("INSERT INTO document_authors (document_id, author_id, role) VALUES (:d, :a, 'author')"),
            {"d": doc, "a": author},
        )
        self._fact(db, model, doc, "The notes were written by Ada.", self._direction(0))
        self._fact(db, model, doc, "the notes were written by Ada", self._direction(5))
        db.flush()
        self._run(db, model)

        summary = rebuild_graph(db)
        assert summary.vertices == {"Document": 1, "Chunk": 1, "Author": 1, "PotentialFact": 2, "Fact": 1}
        # The restatement backs the fact through its representative, the one SUPPORTS edge.
        assert summary.edges == {
            "HAS_CHUNK": 1,
            "WROTE": 1,
            "RECEIVED": 0,
            "STATES": 2,
            "RESTATES": 1,
            "SUPPORTS": 1,
        }
        # Re-projecting replaces the graph rather than adding to it.
        assert rebuild_graph(db).vertices == summary.vertices

        use_age(db)
        rows = (
            db.connection()
            .exec_driver_sql(
                "SELECT name::text, statement::text FROM ag_catalog.cypher('garage', $$ "
                "MATCH (a:Author)-[:WROTE]->(:Document)-[:STATES]->(:PotentialFact)-[:SUPPORTS]->(f:Fact) "
                "RETURN DISTINCT a.display_name, f.statement $$) "
                "AS (name ag_catalog.agtype, statement ag_catalog.agtype)"
            )
            .all()
        )
        # agtype strings cast to text with their JSON quotes in some AGE releases and without in others.
        assert [tuple(v.strip('"') for v in r) for r in rows] == [("Ada", "The notes were written by Ada.")]

    def test_the_graph_is_read_back_by_label_search_and_neighbourhood(self, db: Session) -> None:
        """What the app's Graph page calls: labels with counts, a title search, and a walk with filters."""
        from garage_rag.db.graph import age_available, find_vertices, graph_labels, neighborhood, rebuild_graph

        if not age_available(db):
            pytest.skip("this server has no Apache AGE")
        model = self._setup(db)
        doc = self._doc(db)
        author = db.execute(text("INSERT INTO authors (display_name) VALUES ('Ada') RETURNING id")).scalar_one()
        db.execute(
            text("INSERT INTO document_authors (document_id, author_id, role) VALUES (:d, :a, 'author')"),
            {"d": doc, "a": author},
        )
        first = self._fact(db, model, doc, "Ada wrote the notes.", self._direction(0))
        # In another document, so the two are grouped across the corpus rather than as a restatement.
        self._fact(db, model, self._doc(db), "The notes were written by Ada.", self._direction(5))
        db.flush()
        self._run(db, model)
        rebuild_graph(db)

        labels = graph_labels(db)
        assert labels.available
        assert labels.vertices == {"Author": 1, "Chunk": 0, "Document": 2, "Fact": 1, "PotentialFact": 2}
        assert labels.edges["STATES"] == 2 and labels.edges["SUPPORTS"] == 2

        found = find_vertices(db, "ada")
        distilled = db.execute(text("SELECT id FROM distilled_facts")).scalar_one()
        assert {(v.label, v.key, v.title) for v in found} == {
            ("Author", author, "Ada"),
            ("Fact", distilled, "The notes were written by Ada."),
            ("PotentialFact", first, "Ada wrote the notes."),
            ("PotentialFact", first + 1, "The notes were written by Ada."),
        }
        assert [v.key for v in find_vertices(db, str(doc), label="Document")] == [doc]

        # From the potential fact: its document and its distilled fact, one hop each way.
        walk = neighborhood(db, label="PotentialFact", key=first)
        assert walk.center is not None and walk.center.key == first
        assert sorted(v.label for v in walk.vertices) == ["Document", "Fact", "PotentialFact"]
        assert sorted(e.label for e in walk.edges) == ["STATES", "SUPPORTS"]
        assert "similarity" in next(e for e in walk.edges if e.label == "SUPPORTS").properties
        # Two hops reach the author and the sibling statement; without STATES edges only the fact side is walked.
        two = neighborhood(db, label="PotentialFact", key=first, depth=2)
        assert sorted(v.label for v in two.vertices) == ["Author", "Document", "Fact", "PotentialFact", "PotentialFact"]
        facts_only = neighborhood(db, label="PotentialFact", key=first, depth=2, edge_labels=["SUPPORTS"])
        assert sorted(v.label for v in facts_only.vertices) == ["Fact", "PotentialFact", "PotentialFact"]
        with pytest.raises(LookupError):
            neighborhood(db, label="Document", key=doc + 1000)

        # What the page does: list vertices with no query, then walk from one by its graph id.
        listed = find_vertices(db, "")
        assert {v.label for v in listed} >= {"Author", "Document", "Fact", "PotentialFact"}
        picked = next(v for v in listed if v.label == "PotentialFact" and v.key == first)
        by_id = neighborhood(db, vertex_id=picked.id)
        assert by_id.center is not None and by_id.center.id == picked.id
        assert sorted(v.label for v in by_id.vertices) == ["Document", "Fact", "PotentialFact"]
