"""Tests against a real Postgres + pgvector server.

Everything else in this directory mocks the database, so SQL that only the
server can judge (the migrations, the per-model DDL and operator classes, the
search query, the egress filter on pending chunks, the fact browser's query) is
checked here.

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
from garage_rag.ops.facts import FactFilters, fact_stats, list_facts
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


def _document(session: Session, source_id: int, title: str, content: str, *, corpus_class: str = "document") -> int:
    return session.execute(
        text(
            "INSERT INTO documents (source_id, uri, corpus_class, trust_tier, title, content_sha256, extractor, "
            "content) VALUES (:source, :uri, CAST(:cc AS corpus_class), 'authored', :title, :sha, 'test', :content) "
            "RETURNING id"
        ),
        {
            "source": source_id,
            "uri": f"test://{title}",
            "cc": corpus_class,
            "title": title,
            "sha": hashlib.sha256(content.encode()).digest(),
            "content": content,
        },
    ).scalar_one()


def _fact(session: Session, document_id: int, ord_: int, claim: str, *, content: str, minutes_ago: int) -> int:
    """A fact grounded to where ``claim`` sits in ``content``, or ungrounded when it is not there."""
    start = content.find(claim)
    return session.execute(
        text(
            "INSERT INTO facts (document_id, ord, fact, char_start, char_end, created_at) "
            "VALUES (:doc, :ord, :fact, :start, :end, now() - make_interval(mins => :minutes)) RETURNING id"
        ),
        {
            "doc": document_id,
            "ord": ord_,
            "fact": claim,
            "start": start if start >= 0 else None,
            "end": start + len(claim) if start >= 0 else None,
            "minutes": minutes_ago,
        },
    ).scalar_one()


class TestFacts:
    """Browsing facts: the full-text and substring match on the generated tsvector,
    the joins and sorts, and the excerpt cut in SQL."""

    ROOF = "Intro. The roof was replaced in 2019 by Acme. Other things happened afterwards."
    # Multi-byte and astral characters before the span: offsets are code points on both sides.
    CAFE = "Café ☕ 🏠 notes: The café opens at seven. Bye."
    EMAIL = "Hi! The invoice is due Friday. Thanks."

    def _corpus(self, db: Session) -> dict[str, int]:
        notes = _source(db, "notes")
        mail = _source(db, "mail")
        roof = _document(db, notes, "Roof", self.ROOF)
        cafe = _document(db, notes, "Cafe", self.CAFE)
        email = _document(db, mail, "Invoice", self.EMAIL, corpus_class="communication")
        ids = {
            "roof_doc": roof,
            "roof": _fact(db, roof, 0, "The roof was replaced in 2019 by Acme.", content=self.ROOF, minutes_ago=30),
            "cafe": _fact(db, cafe, 0, "The café opens at seven.", content=self.CAFE, minutes_ago=20),
            "email": _fact(db, email, 0, "The invoice is due Friday.", content=self.EMAIL, minutes_ago=10),
            "ungrounded": _fact(db, roof, 1, "Acme is a roofing company.", content=self.ROOF, minutes_ago=0),
        }
        db.execute(text("UPDATE facts SET fact_class = 'date' WHERE id = :id"), {"id": ids["email"]})
        db.flush()
        return ids

    def test_filters_sorts_and_pages(self, db: Session) -> None:
        ids = self._corpus(db)

        page = list_facts(db)
        assert page.total == 4
        assert [f.id for f in page.facts] == [ids["ungrounded"], ids["email"], ids["cafe"], ids["roof"]]
        second = list_facts(db, limit=2, offset=2)
        assert second.total == 4
        assert [f.id for f in second.facts] == [ids["cafe"], ids["roof"]]

        def matching(**filters: object) -> set[int]:
            return {f.id for f in list_facts(db, FactFilters(**filters)).facts}

        # Stemmed full text: "replacing" finds "replaced".
        assert matching(query="replacing") == {ids["roof"]}
        # Substring, for a partial word the parser never produces.
        assert matching(query="nvoic") == {ids["email"]}
        # LIKE wildcards in the query are literal.
        assert matching(query="%") == set()
        assert matching(source="mail") == {ids["email"]}
        assert matching(corpus_class="communication") == {ids["email"]}
        assert matching(fact_class="date") == {ids["email"]}
        assert matching(document_id=ids["roof_doc"]) == {ids["roof"], ids["ungrounded"]}

        by_document = list_facts(db, sort="document").facts
        assert [f.document_title for f in by_document] == ["Cafe", "Invoice", "Roof", "Roof"]
        assert [f.id for f in by_document[-2:]] == [ids["roof"], ids["ungrounded"]]
        assert [f.id for f in list_facts(db, FactFilters(query="roof or 2019"), sort="relevance").facts] == [
            ids["roof"],
            ids["ungrounded"],
        ]

        email = list_facts(db, FactFilters(source="mail")).facts[0]
        assert (email.source_slug, email.corpus_class, email.trust_tier) == ("mail", "communication", "authored")

    def test_the_excerpt_is_cut_around_the_span(self, db: Session) -> None:
        ids = self._corpus(db)

        roof = {f.id: f for f in list_facts(db, FactFilters(document_id=ids["roof_doc"]), context_chars=6).facts}
        grounded = roof[ids["roof"]]
        assert grounded.evidence == "The roof was replaced in 2019 by Acme."
        start = self.ROOF.index("The roof")
        end = start + len(grounded.evidence)
        assert grounded.excerpt == self.ROOF[start - 6 : end + 6]
        assert grounded.excerpt_truncated_before and grounded.excerpt_truncated_after
        ungrounded = roof[ids["ungrounded"]]
        assert ungrounded.excerpt == "" and ungrounded.excerpt_span_start is None

        cafe = list_facts(db, FactFilters(query="café"), context_chars=500).facts
        assert [f.id for f in cafe] == [ids["cafe"]]
        assert cafe[0].excerpt == self.CAFE
        assert cafe[0].evidence == "The café opens at seven."
        assert not cafe[0].excerpt_truncated_before and not cafe[0].excerpt_truncated_after

    def test_stats(self, db: Session) -> None:
        self._corpus(db)
        stats = fact_stats(db)
        assert (stats.facts, stats.documents) == (4, 3)
        assert stats.by_source == {"mail": 1, "notes": 3}
        assert stats.by_class == {"date": 1, "fact": 3}
        assert fact_stats(db, FactFilters(source="notes")).by_class == {"fact": 3}

    def test_the_rpcs_present_real_rows(self, db: Session) -> None:
        """ListFacts / GetFactStats over the in-process servicer, which opens its own session."""
        from garage_rag.proto.garage_pb2 import FactFilter, FactStatsRequest, ListFactsRequest
        from garage_rag.service.client import GarageClient

        ids = self._corpus(db)
        db.commit()

        client = GarageClient(in_process=True)
        response = client.list_facts(ListFactsRequest(filter=FactFilter(query="café"), context_chars=500))
        assert response.total_count == 1
        (entry,) = response.facts
        assert entry.id == ids["cafe"]
        assert entry.document_title == "Cafe" and entry.source_slug == "notes"
        assert entry.created_at
        assert entry.excerpt[entry.excerpt_span_start : entry.excerpt_span_end] == "The café opens at seven."

        stats = client.get_fact_stats(FactStatsRequest(filter=FactFilter(corpus_class="communication")))
        assert (stats.facts, dict(stats.facts_by_source)) == (1, {"mail": 1})


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
