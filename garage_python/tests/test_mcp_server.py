"""Tests for MCP server tools, helpers, transports, and CLI serving."""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pytest
from typer.testing import CliRunner

from garage_rag.cli import app
from garage_rag.enrich.generation import ChatReply
from garage_rag.mcp_server.server import (
    _HOME,
    ASK_SYSTEM_PROMPT,
    AskResult,
    AuthorInfo,
    AuthorList,
    Citation,
    CorpusStats,
    DocumentResult,
    GenerateResult,
    Hit,
    ModelInfo,
    SearchResult,
    SourceInfo,
    SourceList,
    _as_list,
    _http_security,
    _log_startup,
    _tidy,
    _untidy,
    build_ask_messages,
    is_loopback,
    main,
    rag_ask,
    rag_generate,
    rag_get_document,
    rag_list_authors,
    rag_list_sources,
    rag_search,
    rag_stats,
    serve,
)


# ---------------------------------------------------------------------------
# Helper tests
# ---------------------------------------------------------------------------
class TestServerHelpers:
    def test_tidy_replaces_home_prefix(self) -> None:
        assert _tidy(f"{_HOME}/Documents/note.md") == "~/Documents/note.md"
        assert _tidy("/var/data/note.md") == "/var/data/note.md"
        assert _tidy("relative/path.md") == "relative/path.md"

    def test_as_list(self) -> None:
        assert _as_list("reference") == ["reference"]
        assert _as_list(["reference", "authored"]) == ["reference", "authored"]
        assert _as_list(None) is None
        assert _as_list(123) == 123

    def test_untidy_expands_only_a_leading_tilde(self) -> None:
        assert _untidy("~/docs/a~b.md") == f"{_HOME}/docs/a~b.md"
        assert _untidy("~") == _HOME
        assert _untidy("/srv/~backup/x.md") == "/srv/~backup/x.md"
        assert _untidy("~other/x.md") == "~other/x.md"

    def test_http_security_loopback_checks_the_host_header(self) -> None:
        settings = _http_security("127.0.0.1", 8787, None)
        assert settings.enable_dns_rebinding_protection is True
        assert set(settings.allowed_hosts) == {"127.0.0.1:8787", "localhost:8787"}
        assert settings.allowed_origins == []

    def test_http_security_brackets_ipv6_binds(self) -> None:
        settings = _http_security("::1", 8787, None)
        assert "[::1]:8787" in settings.allowed_hosts

    def test_http_security_remote_without_hosts_turns_the_check_off(self, caplog) -> None:
        """An exact-match allowlist nobody can satisfy is worse than no check."""
        with caplog.at_level(logging.WARNING, logger="garage_rag.mcp"):
            settings = _http_security("0.0.0.0", 8787, ["https://app.example"])
        assert settings.enable_dns_rebinding_protection is False
        assert settings.allowed_origins == ["https://app.example"]
        assert "Host header is not checked" in caplog.text

    def test_http_security_remote_with_hosts_keeps_the_check(self) -> None:
        settings = _http_security("0.0.0.0", 8787, None, ["rag.example.com:*", "10.0.0.5:8787"])
        assert settings.enable_dns_rebinding_protection is True
        assert {"rag.example.com:*", "10.0.0.5:8787", "localhost:8787"} <= set(settings.allowed_hosts)

    @pytest.mark.parametrize(
        ("host", "expected"),
        [
            ("127.0.0.1", True),
            ("::1", True),
            ("localhost", True),
            ("127.0.0.53", True),
            ("0.0.0.0", False),
            ("192.168.1.100", False),
            ("example.com", False),
            ("invalid-host-name", False),
        ],
    )
    def test_is_loopback(self, host: str, expected: bool) -> None:
        assert is_loopback(host) is expected


# ---------------------------------------------------------------------------
# Tool tests
# ---------------------------------------------------------------------------
@dataclass
class MockSearchHit:
    chunk_id: int = 1
    document_id: int = 10
    uri: str = f"{_HOME}/docs/guide.md"
    title: str = "User Guide"
    corpus_class: str = "document"
    trust_tier: str = "authored"
    heading_path: str = "Introduction > Getting Started"
    authors: list[str] = None
    matched_by: str = "hybrid"
    score: float = 0.87654321
    text: str = "Sample content"
    direction: str | None = None
    sender: str | None = None

    def __post_init__(self):
        if self.authors is None:
            self.authors = ["Rick Mark"]


@dataclass
class MockModelRow:
    slug: str
    dims: int = 768
    stored_dims: int = 768
    storage_kind: str = "halfvec"
    index_kind: str = "hnsw"
    is_default: bool = True
    table_name: str = "emb_bge_base"


class TestMcpTools:
    def test_rag_search_basic(self) -> None:
        mock_hit = MockSearchHit()
        mock_model = MockModelRow(slug="bge-base", is_default=True)

        with patch("garage_rag.mcp_server.server.session_scope") as mock_scope:
            mock_session = MagicMock()
            mock_scope.return_value.__enter__.return_value = mock_session
            with (
                patch("garage_rag.mcp_server.server.run_search", return_value=[mock_hit]) as mock_run_search,
                patch("garage_rag.mcp_server.server.list_models", return_value=[mock_model]),
            ):
                # A direct call bypasses the pydantic BeforeValidator at the MCP
                # boundary; the body must still turn a bare string into a
                # one-item list rather than iterating its characters.
                result = rag_search(
                    query="test query",
                    limit=5,
                    mode="hybrid",
                    corpus_class="document",
                    trust=["authored"],
                    source="notes",
                    author="Rick",
                    direction="sent",
                )

                mock_run_search.assert_called_once_with(
                    mock_session,
                    "test query",
                    limit=5,
                    mode="hybrid",
                    corpus_classes=["document"],
                    trust_tiers=["authored"],
                    sources=["notes"],
                    author="Rick",
                    direction="sent",
                )
                assert isinstance(result, SearchResult)
                assert result.query == "test query"
                assert result.mode == "hybrid"
                assert result.model == "bge-base"
                assert result.count == 1
                assert len(result.hits) == 1
                hit = result.hits[0]
                assert isinstance(hit, Hit)
                assert hit.chunk_id == 1
                assert hit.document_id == 10
                assert hit.location == "~/docs/guide.md"
                assert hit.title == "User Guide"
                assert hit.score == 0.876543
                assert hit.section == "Introduction > Getting Started"
                assert hit.authors == ["Rick Mark"]
                assert hit.direction is None
                assert hit.sender is None

    def test_rag_search_reports_a_message_hits_direction_and_sender(self) -> None:
        mock_hit = MockSearchHit(corpus_class="communication", direction="received", sender="+15551234567")
        with (
            patch("garage_rag.mcp_server.server.session_scope"),
            patch("garage_rag.mcp_server.server.run_search", return_value=[mock_hit]),
            patch("garage_rag.mcp_server.server.list_models", return_value=[]),
        ):
            hit = rag_search(query="dinner", direction="received").hits[0]
        assert (hit.direction, hit.sender) == ("received", "+15551234567")

    def test_rag_search_fts_mode_and_no_default_model(self) -> None:
        mock_hit = MockSearchHit()
        with patch("garage_rag.mcp_server.server.session_scope") as mock_scope:
            mock_session = MagicMock()
            mock_scope.return_value.__enter__.return_value = mock_session
            with (
                patch("garage_rag.mcp_server.server.run_search", return_value=[mock_hit]),
                patch("garage_rag.mcp_server.server.list_models", return_value=[]),
            ):
                result_fts = rag_search(query="fts query", mode="fts")
                assert result_fts.model == "n/a"

                result_vec = rag_search(query="vec query", mode="vector")
                assert result_vec.model == "none"

    def test_rag_get_document_requires_id_or_location(self) -> None:
        with pytest.raises(ValueError, match="pass either document_id or location"):
            rag_get_document()

    def test_rag_get_document_by_id_found(self) -> None:
        doc_obj = MagicMock(
            id=42,
            uri=f"{_HOME}/docs/report.pdf",
            title="Annual Report",
            corpus_class="document",
            trust_tier="reference",
            extractor="pypdf",
            byte_size=1024,
            content="A" * 100,
        )

        with patch("garage_rag.mcp_server.server.session_scope") as mock_scope:
            mock_session = MagicMock()
            mock_scope.return_value.__enter__.return_value = mock_session

            mock_session.query.return_value.filter.return_value.one_or_none.return_value = doc_obj
            author_query = mock_session.query.return_value.join.return_value.filter.return_value
            author_query.order_by.return_value.all.return_value = [
                ("Alice",),
                ("Bob",),
            ]
            mock_session.query.return_value.filter.return_value.scalar.return_value = 5

            result = rag_get_document(document_id=42, max_chars=500)
            assert isinstance(result, DocumentResult)
            assert result.document_id == 42
            assert result.location == "~/docs/report.pdf"
            assert result.title == "Annual Report"
            assert result.corpus_class == "document"
            assert result.trust_tier == "reference"
            assert result.authors == ["Alice", "Bob"]
            assert result.chunk_count == 5
            assert result.truncated is False
            assert len(result.content) == 100

    def test_rag_get_document_by_location_truncated(self) -> None:
        doc_obj = MagicMock(
            id=99,
            uri=f"{_HOME}/code/main.rs",
            title=None,
            corpus_class="code",
            trust_tier="authored",
            extractor="treesitter",
            byte_size=2048,
            content="X" * 1500,
        )

        with patch("garage_rag.mcp_server.server.session_scope") as mock_scope:
            mock_session = MagicMock()
            mock_scope.return_value.__enter__.return_value = mock_session

            mock_session.query.return_value.filter.return_value.one_or_none.return_value = doc_obj
            author_query = mock_session.query.return_value.join.return_value.filter.return_value
            author_query.order_by.return_value.all.return_value = []
            mock_session.query.return_value.filter.return_value.scalar.return_value = 12

            result = rag_get_document(location="~/code/main.rs", max_chars=1000)
            assert result.document_id == 99
            assert result.location == "~/code/main.rs"
            assert result.truncated is True
            assert len(result.content) == 1000

    def test_rag_get_document_not_found(self) -> None:
        with patch("garage_rag.mcp_server.server.session_scope") as mock_scope:
            mock_session = MagicMock()
            mock_scope.return_value.__enter__.return_value = mock_session
            mock_session.query.return_value.filter.return_value.one_or_none.return_value = None

            with pytest.raises(ValueError, match="no such document: 999"):
                rag_get_document(document_id=999)

    def test_rag_list_sources(self) -> None:
        # SimpleNamespace rather than MagicMock: the query labels a column ``cls``,
        # and ``cls`` is not a valid MagicMock constructor keyword.
        rows = [
            SimpleNamespace(
                slug="vault",
                kind="obsidian",
                cls="document",
                trust="authored",
                root=f"{_HOME}/Obsidian",
                documents=120,
                chunks=450,
            ),
            SimpleNamespace(
                slug="repo",
                kind="git",
                cls="code",
                trust="authored",
                root="/var/repo",
                documents=80,
                chunks=300,
            ),
        ]

        with patch("garage_rag.mcp_server.server.session_scope") as mock_scope:
            mock_session = MagicMock()
            mock_scope.return_value.__enter__.return_value = mock_session

            source_query = mock_session.query.return_value.outerjoin.return_value.outerjoin.return_value
            source_query.group_by.return_value.order_by.return_value.all.return_value = rows

            result = rag_list_sources()
            assert isinstance(result, SourceList)
            assert result.count == 2
            assert len(result.sources) == 2
            src1 = result.sources[0]
            assert isinstance(src1, SourceInfo)
            assert src1.slug == "vault"
            assert src1.root == "~/Obsidian"
            assert src1.documents == 120
            assert src1.chunks == 450

    def test_rag_list_authors(self) -> None:
        rows = [
            MagicMock(
                display_name="Rick Mark",
                is_self=True,
                documents=50,
                identities=["git_email:rickmark@outlook.com", "git_name:Rick Mark"],
            ),
            MagicMock(
                display_name="Ada Lovelace",
                is_self=False,
                documents=10,
                identities=[],
            ),
        ]

        with patch("garage_rag.mcp_server.server.session_scope") as mock_scope:
            mock_session = MagicMock()
            mock_scope.return_value.__enter__.return_value = mock_session

            author_query = mock_session.query.return_value.outerjoin.return_value.outerjoin.return_value
            author_query.group_by.return_value.order_by.return_value.limit.return_value.all.return_value = rows

            result = rag_list_authors(limit=10)
            assert isinstance(result, AuthorList)
            assert result.count == 2
            assert len(result.authors) == 2
            a1 = result.authors[0]
            assert isinstance(a1, AuthorInfo)
            assert a1.name == "Rick Mark"
            assert a1.is_self is True
            assert a1.documents == 50
            assert len(a1.identities) == 2

    def test_rag_stats(self) -> None:
        mock_model = MockModelRow(slug="bge-base", is_default=True, table_name="emb_bge_base")
        overview_data = [{"corpus_class": "document", "trust_tier": "authored", "documents": 10}]

        with patch("garage_rag.mcp_server.server.session_scope") as mock_scope:
            mock_session = MagicMock()
            mock_scope.return_value.__enter__.return_value = mock_session

            mock_session.query.return_value.filter.return_value.scalar.side_effect = [100, 3]
            mock_session.query.return_value.scalar.side_effect = [500, 8]

            with (
                patch("garage_rag.mcp_server.server.corpus_overview", return_value=overview_data),
                patch("garage_rag.mcp_server.server.list_models", return_value=[mock_model]),
                patch("garage_rag.mcp_server.server.count_vectors", return_value=450),
            ):
                stats = rag_stats()
                assert isinstance(stats, CorpusStats)
                assert stats.documents == 100
                assert stats.chunks == 500
                assert stats.authors == 8
                assert stats.placeholders_pending == 3
                assert stats.by_class_and_trust == overview_data
                assert len(stats.models) == 1
                m = stats.models[0]
                assert isinstance(m, ModelInfo)
                assert m.slug == "bge-base"
                assert m.vectors == 450
                assert m.pending == 50


# ---------------------------------------------------------------------------
# rag_ask / rag_generate: local generation over the retrieval above
# ---------------------------------------------------------------------------
def _fake_chat_model(reply: ChatReply) -> MagicMock:
    model = MagicMock()
    model.provider = "llama_xpc"
    model.model_ref = "gemma2-2b"
    model.host = "http://127.0.0.1:8790"
    model.complete.return_value = reply
    model.chat.return_value = reply.text
    return model


class TestAsk:
    def test_prompt_numbers_excerpts_and_ends_with_the_question(self) -> None:
        hits = [
            MockSearchHit(chunk_id=1, document_id=10, title="User Guide", text="Install with brew."),
            MockSearchHit(chunk_id=2, document_id=11, title=None, heading_path=None, text="x" * 5000),
        ]
        messages = build_ask_messages("how do I install?", hits)
        assert [m["role"] for m in messages] == ["system", "user"]
        assert messages[0]["content"] == ASK_SYSTEM_PROMPT
        user = messages[1]["content"]
        assert "[1] User Guide \u2014 ~/docs/guide.md \u00a7 Introduction > Getting Started\nInstall with brew." in user
        assert "[2] (untitled) \u2014 ~/docs/guide.md\n" in user
        assert user.endswith("\n\nQuestion: how do I install?")
        # Long excerpts are trimmed to ~1,200 characters, never sent whole.
        second = user.split("[2] ")[1].split("\n\nQuestion:")[0]
        assert len(second) < 1300
        assert second.endswith("\u2026")

    def test_prompt_without_hits_says_so(self) -> None:
        user = build_ask_messages("anything?", [])[1]["content"]
        assert "(no excerpts were retrieved)" in user
        assert user.endswith("Question: anything?")

    def test_rag_ask_runs_retrieval_then_the_model(self) -> None:
        hit = MockSearchHit(text="Widgets ship on Tuesdays. " * 20)
        chat_model = _fake_chat_model(ChatReply(text="Tuesdays [1].", prompt_tokens=90, completion_tokens=5))
        with (
            patch("garage_rag.mcp_server.server.session_scope") as mock_scope,
            patch("garage_rag.mcp_server.server.run_search", return_value=[hit]) as mock_run_search,
            patch("garage_rag.mcp_server.server.list_models", return_value=[MockModelRow(slug="bge-base")]),
            patch("garage_rag.mcp_server.server.LocalChatModel", return_value=chat_model),
        ):
            mock_session = MagicMock()
            mock_scope.return_value.__enter__.return_value = mock_session
            result = rag_ask(question="when do widgets ship?", limit=3, trust="authored", max_tokens=100)

        # Same retrieval rag_search does, same filter normalisation.
        mock_run_search.assert_called_once_with(
            mock_session,
            "when do widgets ship?",
            limit=3,
            mode="hybrid",
            corpus_classes=None,
            trust_tiers=["authored"],
            sources=None,
            author=None,
            direction=None,
        )
        messages = chat_model.complete.call_args.args[0]
        assert chat_model.complete.call_args.kwargs == {"max_tokens": 100, "temperature": 0.2}
        assert messages[0]["role"] == "system"
        assert "[1] User Guide" in messages[1]["content"]
        assert "Question: when do widgets ship?" in messages[1]["content"]

        assert isinstance(result, AskResult)
        assert result.answer == "Tuesdays [1]."
        assert result.model == "gemma2-2b"
        assert result.provider == "llama_xpc"
        assert result.question == "when do widgets ship?"
        assert result.prompt_tokens == 90
        assert result.completion_tokens == 5
        assert len(result.citations) == 1
        citation = result.citations[0]
        assert isinstance(citation, Citation)
        assert citation.n == 1
        assert citation.document_id == 10
        assert citation.title == "User Guide"
        assert citation.location == "~/docs/guide.md"
        assert citation.score == 0.876543
        assert len(citation.snippet) <= 240

    def test_rag_generate_is_a_raw_prompt(self) -> None:
        chat_model = _fake_chat_model(ChatReply(text="pong"))
        with patch("garage_rag.mcp_server.server.LocalChatModel", return_value=chat_model):
            result = rag_generate(prompt="ping", system="be terse", max_tokens=16, temperature=0.0)
        chat_model.chat.assert_called_once_with(
            [{"role": "system", "content": "be terse"}, {"role": "user", "content": "ping"}],
            max_tokens=16,
            temperature=0.0,
        )
        assert result == GenerateResult(text="pong", model="gemma2-2b", provider="llama_xpc")

    def test_rag_generate_without_system(self) -> None:
        chat_model = _fake_chat_model(ChatReply(text="pong"))
        with patch("garage_rag.mcp_server.server.LocalChatModel", return_value=chat_model):
            rag_generate(prompt="ping")
        assert chat_model.chat.call_args.args[0] == [{"role": "user", "content": "ping"}]

    def test_tools_are_registered(self) -> None:
        from garage_rag.mcp_server.server import mcp

        names = {tool.name for tool in mcp._tool_manager.list_tools()}
        assert {"rag_ask", "rag_generate", "rag_search"} <= names


# ---------------------------------------------------------------------------
# Server startup & transport tests
# ---------------------------------------------------------------------------
class TestServerLifecycle:
    def test_log_startup(self, caplog: pytest.LogCaptureFixture) -> None:
        with patch("garage_rag.mcp_server.server.session_scope") as mock_scope:
            mock_session = MagicMock()
            mock_scope.return_value.__enter__.return_value = mock_session
            mock_session.query.return_value.count.return_value = 7

            with caplog.at_level(logging.INFO):
                _log_startup()
                assert "database connection: postgresql+psycopg:///rag" in caplog.text
                assert "7 sources registered" in caplog.text

    def test_log_startup_survives_an_unreachable_database(self, caplog: pytest.LogCaptureFixture) -> None:
        with (
            patch("garage_rag.mcp_server.server.session_scope", side_effect=ConnectionRefusedError("refused")),
            caplog.at_level(logging.INFO),
        ):
            _log_startup()
        assert "could not query the database during start-up: refused" in caplog.text

    def test_serve_stdio(self) -> None:
        with (
            patch("garage_rag.mcp_server.server._log_startup"),
            patch("garage_rag.mcp_server.server.mcp.run") as mock_mcp_run,
        ):
            serve("stdio")
            mock_mcp_run.assert_called_once_with()

    def test_serve_stdio_answers_without_touching_the_database(self) -> None:
        """A stdio client waits on `initialize`; nothing may connect before the server runs."""
        with (
            patch("garage_rag.mcp_server.server.session_scope") as scope,
            patch("garage_rag.mcp_server.server.mcp.run") as mock_mcp_run,
        ):
            serve("stdio")
        scope.assert_not_called()
        mock_mcp_run.assert_called_once_with()

    def test_serve_unsupported_transport(self) -> None:
        with (
            patch("garage_rag.mcp_server.server._log_startup"),
            pytest.raises(ValueError, match="unsupported transport: 'custom'"),
        ):
            serve("custom")

    def test_serve_sse(self) -> None:
        with (
            patch("garage_rag.mcp_server.server._log_startup"),
            patch("garage_rag.mcp_server.server.mcp.run") as mock_mcp_run,
        ):
            serve(
                "sse",
                host="127.0.0.1",
                port=8000,
                path="/events",
                allowed_origins=["http://localhost:3000"],
            )
            mock_mcp_run.assert_called_once()
            call_args, call_kwargs = mock_mcp_run.call_args
            assert call_args[0] == "sse"
            assert call_kwargs["host"] == "127.0.0.1"
            assert call_kwargs["port"] == 8000
            assert call_kwargs["sse_path"] == "/events"
            sec = call_kwargs["transport_security"]
            assert sec.enable_dns_rebinding_protection is True
            assert "127.0.0.1:8000" in sec.allowed_hosts
            assert "http://localhost:3000" in sec.allowed_origins

    def test_serve_streamable_http(self) -> None:
        with (
            patch("garage_rag.mcp_server.server._log_startup"),
            patch("garage_rag.mcp_server.server.mcp.run") as mock_mcp_run,
        ):
            serve(
                "streamable-http",
                host="127.0.0.1",
                port=9000,
                path="/mcp",
                json_response=True,
                stateless=True,
            )
            mock_mcp_run.assert_called_once()
            call_args, call_kwargs = mock_mcp_run.call_args
            assert call_args[0] == "streamable-http"
            assert call_kwargs["host"] == "127.0.0.1"
            assert call_kwargs["port"] == 9000
            assert call_kwargs["streamable_http_path"] == "/mcp"
            assert call_kwargs["json_response"] is True
            assert call_kwargs["stateless_http"] is True

    def test_serve_non_loopback_logs_warning(self, caplog: pytest.LogCaptureFixture) -> None:
        with (
            patch("garage_rag.mcp_server.server._log_startup"),
            patch("garage_rag.mcp_server.server.mcp.run"),
            caplog.at_level(logging.WARNING),
        ):
            serve("streamable-http", host="0.0.0.0", port=9000)
            assert "listening on 0.0.0.0, which is reachable from other machines" in caplog.text

    def test_main_calls_serve_stdio(self) -> None:
        with patch("garage_rag.mcp_server.server.serve") as mock_serve:
            main([])
            mock_serve.assert_called_once_with("stdio")

    def test_main_loads_the_config_it_is_given(self, tmp_path: Path) -> None:
        """Clients spawn garage-mcp from anywhere, so registrations pass --config."""
        from garage_rag.config import get_settings, reset_settings

        cfg = tmp_path / "garage.json"
        cfg.write_text(json.dumps({"mcp": {"port": 9123}}))
        try:
            with patch("garage_rag.mcp_server.server.serve") as mock_serve:
                main(["--config", str(cfg)])
            mock_serve.assert_called_once_with("stdio")
            assert get_settings().mcp_port == 9123
        finally:
            reset_settings()

    def test_main_reports_a_bad_config_on_stderr(self, tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
        cfg = tmp_path / "garage.json"
        cfg.write_text(json.dumps({"no_such_section": {}}))
        with patch("garage_rag.mcp_server.server.serve") as mock_serve, pytest.raises(SystemExit) as exit_info:
            main(["--config", str(cfg)])
        assert exit_info.value.code == 2
        mock_serve.assert_not_called()
        captured = capsys.readouterr()
        assert captured.out == ""
        assert "config error" in captured.err


# ---------------------------------------------------------------------------
# CLI Command tests for mcp-serve, mcp-status, mcp-uninstall
# ---------------------------------------------------------------------------
runner = CliRunner()


class TestMcpCliCommands:
    def test_mcp_serve_defaults_to_http(self) -> None:
        """stdio belongs to `garage-mcp`; the CLI command is the long-running HTTP server."""
        with patch("garage_rag.mcp_server.server.serve") as mock_serve:
            result = runner.invoke(app, ["mcp-serve"])
            assert result.exit_code == 0, result.output
            assert mock_serve.call_args.args == ("streamable-http",)

    def test_mcp_serve_has_no_stdio(self) -> None:
        """stdio is `garage-mcp` only; the CLI refuses it rather than serving it."""
        with patch("garage_rag.mcp_server.server.serve") as mock_serve:
            result = runner.invoke(app, ["mcp-serve", "--stdio"])
        assert result.exit_code != 0
        assert "No such option" in result.output
        mock_serve.assert_not_called()

    def test_mcp_serve_conflicting_transports(self) -> None:
        result = runner.invoke(app, ["mcp-serve", "--sse", "--http"])
        assert result.exit_code != 0
        assert "choose one of --http or --sse" in result.output

    def test_mcp_serve_remote_without_allow_remote_fails(self) -> None:
        result = runner.invoke(app, ["mcp-serve", "--http", "--host", "0.0.0.0"])
        assert result.exit_code != 0
        assert "refusing to bind 0.0.0.0" in result.output
        assert "--allow-remote" in result.output

    def test_mcp_serve_remote_with_allow_remote_succeeds(self) -> None:
        with patch("garage_rag.mcp_server.server.serve") as mock_serve:
            result = runner.invoke(
                app,
                [
                    "mcp-serve",
                    "--http",
                    "--host",
                    "0.0.0.0",
                    "--port",
                    "8765",
                    "--path",
                    "/custom-mcp",
                    "--allow-remote",
                    "--json-response",
                    "--stateless",
                ],
            )
            assert result.exit_code == 0
            assert "Host header is not checked" in result.output
            mock_serve.assert_called_once_with(
                "streamable-http",
                host="0.0.0.0",
                port=8765,
                path="/custom-mcp",
                allowed_origins=None,
                allowed_hosts=None,
                json_response=True,
                stateless=True,
            )

    def test_mcp_serve_remote_passes_allowed_hosts(self) -> None:
        with patch("garage_rag.mcp_server.server.serve") as mock_serve:
            result = runner.invoke(
                app,
                [
                    "mcp-serve",
                    "--http",
                    "--host",
                    "0.0.0.0",
                    "--allow-remote",
                    "--allow-host",
                    "rag.example.com:*",
                    "--allow-host",
                    "10.0.0.5:8787",
                ],
            )
            assert result.exit_code == 0
            assert "Host header is not checked" not in result.output
            assert mock_serve.call_args.kwargs["allowed_hosts"] == ["rag.example.com:*", "10.0.0.5:8787"]

    def test_mcp_serve_sse_mode(self) -> None:
        with patch("garage_rag.mcp_server.server.serve") as mock_serve:
            result = runner.invoke(
                app,
                ["mcp-serve", "--sse", "--host", "127.0.0.1", "--port", "8888"],
            )
            assert result.exit_code == 0
            mock_serve.assert_called_once_with(
                "sse",
                host="127.0.0.1",
                port=8888,
                path="/mcp",
                allowed_origins=None,
                allowed_hosts=None,
                json_response=False,
                stateless=False,
            )

    def test_mcp_status_output(self) -> None:
        result = runner.invoke(app, ["mcp-status"])
        assert result.exit_code == 0
        assert "server command:" in result.output
        assert "claude-desktop" in result.output

    def test_mcp_uninstall_unknown_target_fails(self) -> None:
        result = runner.invoke(app, ["mcp-uninstall", "--target", "nonexistent"])
        assert result.exit_code != 0
        assert "unknown target" in result.output

    def test_mcp_uninstall_not_configured_shows_message(self, tmp_path: Path) -> None:
        cfg = tmp_path / "config.json"
        cfg.write_text("{}", encoding="utf-8")
        result = runner.invoke(app, ["mcp-uninstall", "--path", str(cfg)])
        assert result.exit_code == 0
        assert "was not configured" in result.output
