"""Tests for the Documents & Chunks gRPC RPCs (ListDocuments, GetDocument)."""

from __future__ import annotations

from datetime import UTC, datetime
from unittest.mock import MagicMock, patch

import grpc
import pytest

from garage_rag.db.models import Chunk, CorpusClass, Document, Fact, IngestState, TrustTier
from garage_rag.proto.garage_pb2 import GetDocumentRequest, ListDocumentsRequest
from garage_rag.service.server import GarageRpcServicer


def _mock_document(doc_id=1, source_slug="notes", title="Doc Title", uri="/tmp/doc.md"):
    document = MagicMock()
    document.id = doc_id
    document.uri = uri
    document.title = title
    document.corpus_class = CorpusClass.DOCUMENT
    document.trust_tier = TrustTier.AUTHORED
    document.mime = "text/markdown"
    document.lang = "en"
    document.byte_size = 1234
    document.extractor = "markdown"
    document.extractor_version = "1"
    document.chunker = "heading"
    document.meta = {"k": "v"}
    document.state = IngestState.OK
    document.error = None
    document.ingested_at = datetime(2024, 1, 1, tzinfo=UTC)
    document.source = MagicMock(slug=source_slug)
    document.authors = []
    return document


def test_grpc_list_documents_empty_filters():
    servicer = GarageRpcServicer()
    mock_context = MagicMock()

    document = _mock_document()

    with patch("garage_rag.db.engine.session_scope") as mock_scope:
        mock_session = MagicMock()
        mock_scope.return_value.__enter__.return_value = mock_session

        document_query = MagicMock()
        joined = document_query.join.return_value
        joined.with_entities.return_value.scalar.return_value = 1
        joined.order_by.return_value.offset.return_value.limit.return_value.all.return_value = [document]
        # Separate source-slug lookup query, keyed by document id.
        joined.filter.return_value.all.return_value = [(document.id, "notes")]

        chunk_count_query = MagicMock()
        chunk_count_query.filter.return_value.group_by.return_value.all.return_value = [(document.id, 3)]

        fact_count_query = MagicMock()
        fact_count_query.filter.return_value.group_by.return_value.all.return_value = [(document.id, 5)]

        def query_side_effect(*entities):
            model = entities[0]
            if model is Document or model is Document.id:
                return document_query
            if model is Chunk.document_id:
                return chunk_count_query
            if model is Fact.document_id:
                return fact_count_query
            raise AssertionError(f"unexpected query entities: {entities}")

        mock_session.query.side_effect = query_side_effect

        response = servicer.ListDocuments(ListDocumentsRequest(), mock_context)

    assert response.total_count == 1
    assert len(response.documents) == 1
    summary = response.documents[0]
    assert summary.id == document.id
    assert summary.title == "Doc Title"
    assert summary.source_slug == "notes"
    assert summary.corpus_class == "document"
    assert summary.trust_tier == "authored"
    assert summary.chunk_count == 3
    assert summary.fact_count == 5


def test_grpc_get_document_found():
    servicer = GarageRpcServicer()
    mock_context = MagicMock()

    document = _mock_document()

    chunk = MagicMock()
    chunk.id = 55
    chunk.ord = 0
    chunk.text = "hello world"
    chunk.token_count = 2
    chunk.char_start = 0
    chunk.char_end = 11
    chunk.heading_path = "Intro"

    fact = MagicMock()
    fact.id = 77
    fact.ord = 0
    fact.fact = "The sky is blue."
    fact.fact_class = "fact"
    fact.attributes = {"confidence": "high"}
    fact.char_start = 0
    fact.char_end = 16
    fact.extractor = "langextract"

    source = MagicMock(slug="notes")

    chunk_query = MagicMock()
    chunk_query.filter.return_value.order_by.return_value.all.return_value = [chunk]

    fact_query = MagicMock()
    fact_query.filter.return_value.order_by.return_value.all.return_value = [fact]

    def query_side_effect(model):
        if model is Chunk:
            return chunk_query
        if model is Fact:
            return fact_query
        raise AssertionError(f"unexpected query for {model}")

    with patch("garage_rag.db.engine.session_scope") as mock_scope:
        mock_session = MagicMock()
        mock_scope.return_value.__enter__.return_value = mock_session
        mock_session.get.side_effect = lambda model, _id: document if model is Document else source
        mock_session.query.side_effect = query_side_effect

        response = servicer.GetDocument(GetDocumentRequest(document_id=document.id), mock_context)

    assert response.document.id == document.id
    assert response.document.title == "Doc Title"
    assert response.document.source_slug == "notes"
    assert len(response.chunks) == 1
    assert response.chunks[0].text == "hello world"
    assert response.chunks[0].heading_path == "Intro"
    assert response.chunks[0].token_count == 2
    assert len(response.facts) == 1
    assert response.facts[0].fact == "The sky is blue."
    assert response.facts[0].fact_class == "fact"
    assert response.facts[0].extractor == "langextract"


def test_grpc_get_document_not_found():
    servicer = GarageRpcServicer()
    mock_context = MagicMock()
    # A real ServicerContext.abort() raises and never returns; mirror that so the
    # handler cannot fall through to dereference the missing document.
    mock_context.abort.side_effect = grpc.RpcError("aborted")

    with patch("garage_rag.db.engine.session_scope") as mock_scope:
        mock_session = MagicMock()
        mock_scope.return_value.__enter__.return_value = mock_session
        mock_session.get.return_value = None

        with pytest.raises(grpc.RpcError):
            servicer.GetDocument(GetDocumentRequest(document_id=999), mock_context)

    mock_context.abort.assert_called_once()
    assert mock_context.abort.call_args.args[0] == grpc.StatusCode.NOT_FOUND


def test_grpc_list_facts_maps_the_page():
    from garage_rag.ops.facts import FactPage, FactRow
    from garage_rag.proto.garage_pb2 import ListFactsRequest

    servicer = GarageRpcServicer()
    row = FactRow(
        id=7,
        document_id=1,
        ord=0,
        fact="The heat pump was installed in March 2024.",
        fact_class="event",
        attributes={"when": "2024-03"},
        char_start=10,
        char_end=52,
        extractor="langextract",
        extractor_model="qwen3",
        created_at=datetime(2024, 1, 1, tzinfo=UTC),
        document_title="House",
        document_uri="/tmp/house.md",
        source_slug="notes",
        corpus_class="document",
        excerpt="Notes: The heat pump was installed in March 2024. More.",
        excerpt_start=3,
        distilled_fact_id=4,
        distilled_size=3,
        distilled_statement="The heat pump went in during March 2024.",
        distilled_generated=True,
    )
    ungrounded = FactRow(
        id=8,
        document_id=1,
        ord=1,
        fact="The house has a heat pump.",
        fact_class="fact",
        attributes={},
        char_start=None,
        char_end=None,
        extractor="langextract",
        extractor_model=None,
        created_at=None,
        document_title=None,
        document_uri="/tmp/house.md",
        source_slug="notes",
        corpus_class="document",
    )
    page = FactPage(facts=[row, ungrounded], total=12, classes=[("fact", 9), ("event", 3)])

    with (
        patch("garage_rag.db.engine.session_scope"),
        patch("garage_rag.ops.facts.list_facts", return_value=page) as list_facts,
    ):
        response = servicer.ListFacts(
            ListFactsRequest(
                query="heat",
                source="notes",
                fact_class="event",
                limit=50,
                offset=100,
                collapse=True,
                distilled_fact_id=4,
            ),
            MagicMock(),
        )

    kwargs = list_facts.call_args.kwargs
    assert kwargs == {
        "query": "heat",
        "source": "notes",
        "fact_class": "event",
        "corpus_class": "",
        "document_id": None,
        "limit": 50,
        "offset": 100,
        "collapse": True,
        "distilled_fact_id": 4,
    }
    assert response.total_count == 12
    assert [(c.fact_class, c.count) for c in response.classes] == [("fact", 9), ("event", 3)]
    first, second = response.facts
    assert first.id == 7
    assert first.document_title == "House"
    assert first.attributes_json == '{"when": "2024-03"}'
    assert first.HasField("char_start") and first.char_start == 10
    assert first.excerpt_start == 3
    assert first.extractor_model == "qwen3"
    assert first.created_at == "2024-01-01T00:00:00+00:00"
    assert not second.HasField("char_start")
    assert second.excerpt == ""
    assert second.attributes_json == ""
    assert (first.distilled_fact_id, first.distilled_size, first.distilled_generated) == (4, 3, True)
    assert first.distilled_statement == "The heat pump went in during March 2024."
    assert (second.distilled_fact_id, second.distilled_size, second.distilled_statement) == (0, 0, "")


def test_grpc_list_facts_defaults_the_page_size():
    from garage_rag.ops.facts import FactPage
    from garage_rag.proto.garage_pb2 import ListFactsRequest

    servicer = GarageRpcServicer()
    with (
        patch("garage_rag.db.engine.session_scope"),
        patch("garage_rag.ops.facts.list_facts", return_value=FactPage(facts=[], total=0)) as list_facts,
    ):
        response = servicer.ListFacts(ListFactsRequest(document_id=4), MagicMock())

    assert list_facts.call_args.kwargs["limit"] == 200
    assert list_facts.call_args.kwargs["document_id"] == 4
    assert response.total_count == 0


def test_grpc_get_fact_stats_maps_the_counts():
    from garage_rag.ops.facts import FactStats
    from garage_rag.proto.garage_pb2 import FactStatsRequest

    servicer = GarageRpcServicer()
    stats = FactStats(facts=12, documents=3, by_source={"notes": 9, "mail": 3}, by_class={"fact": 10, "event": 2})
    with (
        patch("garage_rag.db.engine.session_scope"),
        patch("garage_rag.ops.facts.fact_stats", return_value=stats) as fact_stats,
    ):
        response = servicer.GetFactStats(FactStatsRequest(corpus_class="communication"), MagicMock())

    assert fact_stats.call_args.kwargs == {
        "query": "",
        "source": "",
        "fact_class": "",
        "corpus_class": "communication",
        "document_id": None,
    }
    assert (response.facts, response.documents) == (12, 3)
    assert dict(response.facts_by_source) == {"notes": 9, "mail": 3}
    assert dict(response.facts_by_class) == {"fact": 10, "event": 2}
    assert response.formatted_output == "12 facts across 3 documents"


def test_grpc_get_fact_stats_rejects_an_unknown_corpus_class():
    from garage_rag.proto.garage_pb2 import FactStatsRequest

    servicer = GarageRpcServicer()
    context = MagicMock()
    context.abort.side_effect = grpc.RpcError()
    with patch("garage_rag.db.engine.session_scope"), pytest.raises(grpc.RpcError):
        servicer.GetFactStats(FactStatsRequest(corpus_class="memo"), context)
    assert context.abort.call_args.args[0] == grpc.StatusCode.INVALID_ARGUMENT


def test_grpc_list_sources_counts_documents_per_source():
    from types import SimpleNamespace

    from garage_rag.db.models import Source
    from garage_rag.proto.garage_pb2 import ListSourcesRequest

    sources = [
        SimpleNamespace(
            id=1,
            slug="notes",
            kind="filesystem",
            default_class=CorpusClass.DOCUMENT,
            default_trust=TrustTier.AUTHORED,
            enabled=True,
            root="/Users/rick/Notes",
            expected_elements=40,
        ),
        SimpleNamespace(
            id=2,
            slug="mail",
            kind="maildir",
            default_class=CorpusClass.COMMUNICATION,
            default_trust=TrustTier.RECEIVED,
            enabled=False,
            root="/Users/rick/Library/Mail",
            expected_elements=None,
        ),
    ]
    session = MagicMock()
    source_query = MagicMock()
    source_query.order_by.return_value.all.return_value = sources
    count_query = MagicMock()
    count_query.group_by.return_value.all.return_value = [(1, 37)]
    session.query.side_effect = lambda *entities: source_query if entities[0] is Source else count_query

    with patch("garage_rag.db.engine.session_scope") as mock_scope:
        mock_scope.return_value.__enter__.return_value = session
        response = GarageRpcServicer().ListSources(ListSourcesRequest(), MagicMock())

    assert response.formatted_output == "2 sources registered"
    notes, mail = response.sources
    assert (notes.slug, notes.kind, notes.corpus_class, notes.trust_tier) == (
        "notes",
        "filesystem",
        "document",
        "authored",
    )
    assert notes.enabled and notes.document_count == 37 and notes.expected_elements == 40
    assert notes.root == "/Users/rick/Notes"
    assert (mail.corpus_class, mail.trust_tier) == ("communication", "received")
    assert not mail.enabled
    # A source with no documents, and one whose scan never counted anything, report zeros.
    assert mail.document_count == 0 and mail.expected_elements == 0


def test_grpc_get_stats_counts_the_corpus_per_source_and_model():
    from types import SimpleNamespace

    from garage_rag.proto.garage_pb2 import StatsRequest

    session = MagicMock()
    # Documents, chunks, sources, in the order the handler counts them.
    session.query.return_value.scalar.side_effect = [1234, 56789, 2]
    session.query.return_value.outerjoin.return_value.group_by.return_value.all.return_value = [
        ("notes", 1234),
        ("empty", 0),
    ]
    models = [SimpleNamespace(slug="bge-m3"), SimpleNamespace(slug="nomic")]
    vectors = {"bge-m3": 56789, "nomic": 100}

    with (
        patch("garage_rag.db.engine.session_scope") as mock_scope,
        patch("garage_rag.db.emb_tables.list_models", return_value=models),
        patch("garage_rag.db.emb_tables.count_vectors", side_effect=lambda _session, m: vectors[m.slug]),
    ):
        mock_scope.return_value.__enter__.return_value = session
        response = GarageRpcServicer().GetStats(StatsRequest(), MagicMock())

    assert (response.documents, response.chunks, response.sources, response.models) == (1234, 56789, 2, 2)
    assert dict(response.documents_by_source) == {"notes": 1234, "empty": 0}
    assert dict(response.chunks_by_model) == {"bge-m3": 56789, "nomic": 100}
    assert response.formatted_output == "Corpus: 1,234 documents, 56,789 chunks across 2 sources, 2 embedding models"


def test_grpc_get_stats_on_an_empty_database_reports_zeros():
    from garage_rag.proto.garage_pb2 import StatsRequest

    session = MagicMock()
    session.query.return_value.scalar.return_value = None
    session.query.return_value.outerjoin.return_value.group_by.return_value.all.return_value = []

    with (
        patch("garage_rag.db.engine.session_scope") as mock_scope,
        patch("garage_rag.db.emb_tables.list_models", return_value=[]),
    ):
        mock_scope.return_value.__enter__.return_value = session
        response = GarageRpcServicer().GetStats(StatsRequest(), MagicMock())

    assert (response.documents, response.chunks, response.sources, response.models) == (0, 0, 0, 0)
    assert not response.chunks_by_model and not response.documents_by_source


def test_grpc_get_stats_database_outage_is_an_error_not_zeros():
    from garage_rag.proto.garage_pb2 import StatsRequest

    with (
        patch("garage_rag.db.engine.session_scope", side_effect=RuntimeError("connection refused")),
        pytest.raises(RuntimeError, match="connection refused"),
    ):
        GarageRpcServicer().GetStats(StatsRequest(), MagicMock())
