"""Browsing distilled facts: ``ops.facts.list_facts``/``fact_stats``, the ListFacts and
GetFactStats RPCs, and ``garage facts``.

The SQL itself runs against a real server in ``test_postgres.py``; here the query is
compiled for Postgres and inspected, and the database is mocked.
"""

from __future__ import annotations

import json
from datetime import UTC, datetime
from unittest.mock import MagicMock, patch

import grpc
import pytest
from sqlalchemy.dialects import postgresql
from typer.testing import CliRunner

from garage_rag.cli import app
from garage_rag.db.models import CorpusClass, TrustTier
from garage_rag.ops import facts as ops_facts
from garage_rag.ops.facts import FactFilters, FactPage, FactRow, FactStats, fact_stats, list_facts
from garage_rag.proto.garage_pb2 import FactFilter, FactStatsRequest, ListFactsRequest
from garage_rag.service.server import GarageRpcServicer

runner = CliRunner()


def _sql(stmt) -> str:
    """The statement as Postgres would run it, with its parameters inlined.

    Not ``literal_binds``: SQLAlchemy has no literal renderer for the REGCONFIG
    argument of websearch_to_tsquery.
    """
    compiled = stmt.compile(dialect=postgresql.dialect())
    sql = str(compiled)
    for key, value in compiled.params.items():
        sql = sql.replace(f"%({key})s", f"'{value}'" if isinstance(value, str) else str(value))
    return sql.replace("%%", "%")


def _row(**overrides) -> dict:
    row = {
        "id": 7,
        "document_id": 3,
        "ord": 0,
        "fact": "The sky is blue.",
        "fact_class": "fact",
        "attributes": {"confidence": "high"},
        "char_start": 10,
        "char_end": 26,
        "extractor": "langextract",
        "extractor_model": "gemma2-2b",
        "created_at": datetime(2026, 1, 2, tzinfo=UTC),
        "title": "Weather notes",
        "uri": "/notes/weather.md",
        "corpus_class": CorpusClass.DOCUMENT,
        "trust_tier": TrustTier.AUTHORED,
        "slug": "notes",
        "excerpt": None,
        "content_length": None,
    }
    row.update(overrides)
    return row


def _session_returning(total: int, rows: list[dict]) -> MagicMock:
    """A session whose first execute is the count and second the page."""
    session = MagicMock()
    count_result = MagicMock()
    count_result.scalar_one.return_value = total
    page_result = MagicMock()
    page_result.mappings.return_value = rows
    session.execute.side_effect = [count_result, page_result]
    return session


# ---------------------------------------------------------------------------
# The query
# ---------------------------------------------------------------------------


def test_filters_compile_into_the_where_clause():
    stmt = ops_facts._apply_fact_filters(
        ops_facts._joined(ops_facts.Fact.id),
        FactFilters(query="blue sky", source="notes", document_id=3, fact_class="fact", corpus_class="communication"),
    )
    sql = _sql(stmt)
    assert "facts.tsv @@ websearch_to_tsquery('english', 'blue sky')" in sql
    assert "facts.fact ILIKE '%' || 'blue sky' || '%'" in sql
    assert "sources.slug = 'notes'" in sql
    assert "facts.document_id = 3" in sql
    assert "facts.fact_class = 'fact'" in sql
    assert "documents.corpus_class = 'communication'" in sql


def test_empty_filters_add_no_where_clause():
    sql = _sql(ops_facts._apply_fact_filters(ops_facts._joined(ops_facts.Fact.id), FactFilters(query="   ")))
    assert "WHERE" not in sql
    assert "JOIN documents" in sql and "JOIN sources" in sql


def test_substring_match_escapes_like_wildcards():
    sql = _sql(ops_facts._apply_fact_filters(ops_facts._joined(ops_facts.Fact.id), FactFilters(query="50%_off")))
    assert "50/%/_off" in sql
    assert "ESCAPE '/'" in sql


@pytest.mark.parametrize(
    ("sort", "query", "expected"),
    [
        ("newest", None, "ORDER BY facts.created_at DESC, facts.id DESC"),
        ("document", None, "ORDER BY coalesce(nullif(documents.title, ''), documents.uri) ASC"),
        ("relevance", "blue", "ORDER BY ts_rank(facts.tsv, websearch_to_tsquery('english', 'blue')) DESC"),
        # Nothing to rank against: newest first.
        ("relevance", None, "ORDER BY facts.created_at DESC, facts.id DESC"),
    ],
)
def test_sort_orders(sort, query, expected):
    filters = FactFilters(query=query)
    stmt = ops_facts._joined(ops_facts.Fact.id).order_by(*ops_facts._fact_order(filters, sort))
    assert expected in _sql(stmt)


def test_unknown_sort_is_a_value_error():
    with pytest.raises(ValueError, match="unknown sort 'oldest'"):
        list_facts(MagicMock(), sort="oldest")


def test_unknown_corpus_class_is_a_value_error():
    with pytest.raises(ValueError, match="unknown corpus class 'email'"):
        list_facts(MagicMock(), FactFilters(corpus_class="email"))


def test_list_facts_clamps_the_page_and_counts_every_page():
    session = _session_returning(1234, [_row()])
    page = list_facts(session, limit=10_000, offset=-5)

    assert page.total == 1234
    assert page.limit == ops_facts.MAX_FACT_PAGE
    assert page.offset == 0
    assert len(page.facts) == 1
    page_sql = _sql(session.execute.call_args_list[1].args[0])
    assert f"LIMIT {ops_facts.MAX_FACT_PAGE}" in page_sql
    assert "substr(documents.content" in page_sql


def test_list_facts_zero_limit_means_the_default():
    session = _session_returning(0, [])
    page = list_facts(session, limit=0)
    assert page.limit == ops_facts.DEFAULT_FACT_PAGE
    assert page.message == "no facts"


def test_row_without_a_span_has_no_excerpt():
    fact = ops_facts._fact_row(_row(char_start=None, char_end=None), 200)
    assert fact.excerpt == ""
    assert fact.excerpt_span_start is None
    assert fact.evidence == ""
    assert fact.corpus_class == "document"
    assert fact.trust_tier == "authored"
    assert fact.source_slug == "notes"


def test_row_span_at_the_start_of_the_document():
    content = "The sky is blue. It rained later."
    # The window starts at 0 (span 0..16, context 5), so nothing is cut before.
    fact = ops_facts._fact_row(
        _row(char_start=0, char_end=16, excerpt=content[0:21], content_length=len(content)),
        5,
    )
    assert fact.excerpt == "The sky is blue. It r"
    assert (fact.excerpt_span_start, fact.excerpt_span_end) == (0, 16)
    assert fact.evidence == "The sky is blue."
    assert fact.excerpt_truncated_before is False
    assert fact.excerpt_truncated_after is True


def test_row_span_in_the_middle_of_the_document():
    content = "Preamble text. The sky is blue. Tail."
    start = content.index("The sky")
    end = start + len("The sky is blue.")
    context = 4
    window = max(start - context, 0)
    excerpt = content[window : end + context]
    fact = ops_facts._fact_row(
        _row(char_start=start, char_end=end, excerpt=excerpt, content_length=len(content)), context
    )
    assert fact.evidence == "The sky is blue."
    assert fact.excerpt_span_start == context
    assert fact.excerpt_truncated_before is True
    assert fact.excerpt_truncated_after is True


def test_row_span_past_the_end_of_stored_content_is_clamped():
    # A document re-extracted to shorter text than the span the fact was grounded to.
    fact = ops_facts._fact_row(_row(char_start=2, char_end=50, excerpt="abcdef", content_length=6), 200)
    assert fact.excerpt_span_end == len("abcdef")
    assert fact.evidence == "cdef"
    assert fact.excerpt_truncated_after is False


def test_fact_stats_maps_counts():
    session = MagicMock()
    totals = MagicMock()
    totals.one.return_value = (5, 2)
    by_source = MagicMock()
    by_source.all.return_value = [("mail", 3), ("notes", 2)]
    by_class = MagicMock()
    by_class.all.return_value = [("fact", 5)]
    session.execute.side_effect = [totals, by_source, by_class]

    stats = fact_stats(session, FactFilters(source="notes"))

    assert stats == FactStats(facts=5, documents=2, by_source={"mail": 3, "notes": 2}, by_class={"fact": 5})
    assert stats.message == "5 facts across 2 documents"
    assert "sources.slug = 'notes'" in _sql(session.execute.call_args_list[0].args[0])


def test_page_message():
    assert FactPage(facts=[], total=0, limit=50, offset=0).message == "no facts"
    fact = ops_facts._fact_row(_row(), 200)
    assert FactPage(facts=[fact], total=120, limit=50, offset=50).message == "facts 51-51 of 120"
    assert FactPage(facts=[], total=12, limit=50, offset=50).message == "no facts past 50 of 12"


# ---------------------------------------------------------------------------
# The RPCs
# ---------------------------------------------------------------------------


def _fact(**overrides) -> FactRow:
    values = {
        "id": 7,
        "document_id": 3,
        "ord": 1,
        "fact": "The sky is blue.",
        "fact_class": "fact",
        "attributes": {"confidence": "high"},
        "char_start": 10,
        "char_end": 26,
        "extractor": "langextract",
        "extractor_model": "gemma2-2b",
        "created_at": datetime(2026, 1, 2, tzinfo=UTC),
        "document_title": "Weather notes",
        "document_uri": "/notes/weather.md",
        "source_slug": "notes",
        "corpus_class": "communication",
        "trust_tier": "received",
        "excerpt": "Today: The sky is blue. Later",
        "excerpt_span_start": 7,
        "excerpt_span_end": 23,
        "excerpt_truncated_before": True,
        "excerpt_truncated_after": False,
    }
    values.update(overrides)
    return FactRow(**values)


def test_grpc_list_facts_presents_the_page():
    servicer = GarageRpcServicer()
    page = FactPage(
        facts=[
            _fact(),
            _fact(
                id=8,
                char_start=None,
                char_end=None,
                excerpt="",
                excerpt_span_start=None,
                excerpt_span_end=None,
                attributes={},
            ),
        ],
        total=42,
        limit=2,
        offset=10,
    )
    request = ListFactsRequest(
        filter=FactFilter(query="sky", source="notes", document_id=3, fact_class="fact", corpus_class="communication"),
        sort="relevance",
        limit=2,
        offset=10,
    )

    with (
        patch("garage_rag.db.engine.session_scope") as scope,
        patch("garage_rag.ops.facts.list_facts", return_value=page) as run,
    ):
        response = servicer.ListFacts(request, MagicMock())

    session = scope.return_value.__enter__.return_value
    run.assert_called_once_with(
        session,
        FactFilters(query="sky", source="notes", document_id=3, fact_class="fact", corpus_class="communication"),
        sort="relevance",
        limit=2,
        offset=10,
        context_chars=ops_facts.DEFAULT_CONTEXT_CHARS,
    )
    assert response.total_count == 42
    assert (response.limit, response.offset) == (2, 10)
    assert response.formatted_output == "facts 11-12 of 42"

    first, second = response.facts
    assert first.id == 7 and first.document_id == 3 and first.ord == 1
    assert first.fact == "The sky is blue."
    assert json.loads(first.attributes_json) == {"confidence": "high"}
    assert first.HasField("char_start") and first.char_start == 10 and first.char_end == 26
    assert first.extractor_model == "gemma2-2b"
    assert first.created_at == "2026-01-02T00:00:00+00:00"
    assert first.document_title == "Weather notes"
    assert first.source_slug == "notes"
    # Communications are listed like everything else: this is the local app, not egress.
    assert first.corpus_class == "communication"
    assert first.excerpt[first.excerpt_span_start : first.excerpt_span_end] == "The sky is blue."
    assert first.excerpt_truncated_before and not first.excerpt_truncated_after

    assert not second.HasField("char_start")
    assert not second.HasField("excerpt_span_start")
    assert second.attributes_json == ""


def test_grpc_list_facts_defaults():
    servicer = GarageRpcServicer()
    with (
        patch("garage_rag.db.engine.session_scope"),
        patch("garage_rag.ops.facts.list_facts", return_value=FactPage([], 0, 50, 0)) as run,
    ):
        response = servicer.ListFacts(ListFactsRequest(context_chars=40), MagicMock())

    _, kwargs = run.call_args
    assert run.call_args.args[1] == FactFilters()
    assert kwargs["sort"] == "newest"
    assert kwargs["context_chars"] == 40
    assert response.total_count == 0
    assert response.formatted_output == "no facts"


def test_grpc_list_facts_bad_sort_is_invalid_argument():
    servicer = GarageRpcServicer()
    context = MagicMock()
    context.abort.side_effect = grpc.RpcError("aborted")

    with patch("garage_rag.db.engine.session_scope"), pytest.raises(grpc.RpcError):
        servicer.ListFacts(ListFactsRequest(sort="sideways"), context)

    assert context.abort.call_args.args[0] == grpc.StatusCode.INVALID_ARGUMENT
    assert "unknown sort" in context.abort.call_args.args[1]


def test_grpc_get_fact_stats():
    servicer = GarageRpcServicer()
    stats = FactStats(facts=5, documents=2, by_source={"mail": 3, "notes": 2}, by_class={"fact": 5})
    with (
        patch("garage_rag.db.engine.session_scope"),
        patch("garage_rag.ops.facts.fact_stats", return_value=stats) as run,
    ):
        response = servicer.GetFactStats(FactStatsRequest(filter=FactFilter(source="mail")), MagicMock())

    assert run.call_args.args[1] == FactFilters(source="mail")
    assert response.facts == 5
    assert response.documents == 2
    assert dict(response.facts_by_source) == {"mail": 3, "notes": 2}
    assert dict(response.facts_by_class) == {"fact": 5}
    assert response.formatted_output == "5 facts across 2 documents"


# ---------------------------------------------------------------------------
# garage facts
# ---------------------------------------------------------------------------


def test_cli_facts_list_json():
    page = FactPage(facts=[_fact()], total=1, limit=50, offset=0)
    with (
        patch("garage_rag.cli.session_scope"),
        patch("garage_rag.ops.facts.list_facts", return_value=page) as run,
    ):
        result = runner.invoke(app, ["facts", "list", "-q", "sky", "--source", "notes", "--sort", "document", "--json"])

    assert result.exit_code == 0, result.output
    assert run.call_args.args[1] == FactFilters(query="sky", source="notes")
    assert run.call_args.kwargs["sort"] == "document"
    payload = json.loads(result.output)
    assert payload["total"] == 1
    assert payload["facts"][0]["fact"] == "The sky is blue."
    assert payload["facts"][0]["evidence"] == "The sky is blue."


def test_cli_facts_list_table_and_empty_hint():
    with (
        patch("garage_rag.cli.session_scope"),
        patch("garage_rag.ops.facts.list_facts", return_value=FactPage([_fact()], 1, 50, 0)),
    ):
        result = runner.invoke(app, ["facts", "list", "--evidence"])
    assert result.exit_code == 0, result.output
    assert "The sky is blue." in result.output
    assert "Weather notes" in result.output

    with (
        patch("garage_rag.cli.session_scope"),
        patch("garage_rag.ops.facts.list_facts", return_value=FactPage([], 0, 50, 0)),
    ):
        result = runner.invoke(app, ["facts", "list"])
    assert result.exit_code == 0
    assert "enrich-facts" in result.output


def test_cli_facts_list_bad_sort_exits_2():
    with patch("garage_rag.cli.session_scope"):
        result = runner.invoke(app, ["facts", "list", "--sort", "sideways"])
    assert result.exit_code == 2
    assert "unknown sort" in result.output


def test_cli_facts_stats_json():
    stats = FactStats(facts=5, documents=2, by_source={"notes": 5}, by_class={"fact": 5})
    with (
        patch("garage_rag.cli.session_scope"),
        patch("garage_rag.ops.facts.fact_stats", return_value=stats),
    ):
        result = runner.invoke(app, ["facts", "stats", "--json"])
    assert result.exit_code == 0, result.output
    assert json.loads(result.output) == {
        "facts": 5,
        "documents": 2,
        "by_source": {"notes": 5},
        "by_class": {"fact": 5},
    }
