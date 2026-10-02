"""Tests for CLI serve and version commands."""

from __future__ import annotations

from typer.testing import CliRunner

from garage_rag.cli import app, main_cli

runner = CliRunner()


def test_cli_version():
    result = runner.invoke(app, ["version"])
    assert result.exit_code == 0
    assert "garage v" in result.output


def test_cli_serve_help():
    result = runner.invoke(app, ["serve", "--help"])
    assert result.exit_code == 0
    assert "--host" in result.output
    assert "--port" in result.output
    assert "--xpc" not in result.output


def test_main_cli_returns_exit_code(monkeypatch):
    import sys

    monkeypatch.setattr(sys, "argv", ["garage", "version"])
    code = main_cli()
    assert code == 0

    monkeypatch.setattr(sys, "argv", ["garage", "--help"])
    code = main_cli()
    assert code == 0


def test_cli_ingest_no_sources(monkeypatch):
    from unittest.mock import MagicMock, patch

    mock_session = MagicMock()
    # '*' walks only enabled sources, so the CLI filters before ordering.
    enabled_query = mock_session.query.return_value.filter_by.return_value
    enabled_query.order_by.return_value.all.return_value = []
    mock_factory = MagicMock()
    mock_factory.return_value.__enter__.return_value = mock_session

    with patch("garage_rag.db.engine.get_session_factory", return_value=mock_factory):
        result = runner.invoke(app, ["ingest"])
        assert result.exit_code == 0
        assert "no sources registered to ingest" in result.output
        mock_session.query.return_value.filter_by.assert_called_once_with(enabled=True)


def test_cli_ingest_missing_source(monkeypatch):
    from unittest.mock import MagicMock, patch

    mock_session = MagicMock()
    mock_session.query.return_value.filter_by.return_value.one_or_none.return_value = None
    mock_factory = MagicMock()
    mock_factory.return_value.__enter__.return_value = mock_session

    with patch("garage_rag.db.engine.get_session_factory", return_value=mock_factory):
        result = runner.invoke(app, ["ingest", "--source", "non-existent"])
        assert result.exit_code == 1
        assert "no such source" in result.output


# ---------------------------------------------------------------------------
# garage config set / get
# ---------------------------------------------------------------------------
def test_config_set_then_get(tmp_path):
    import json

    cfg = tmp_path / "garage.json"
    # --config insists the file exists, so create it first (no --config yet).
    result = runner.invoke(app, ["config", "init", "--path", str(cfg)])
    assert result.exit_code == 0, result.output

    result = runner.invoke(app, ["--config", str(cfg), "config", "set", "facts.provider", "ollama"])
    assert result.exit_code == 0, result.output
    assert "facts.provider = ollama" in result.output
    assert json.loads(cfg.read_text())["facts"]["provider"] == "ollama"

    result = runner.invoke(app, ["--config", str(cfg), "config", "set", "placeholders.materialize", "yes"])
    assert result.exit_code == 0, result.output
    assert "placeholders.materialize = true" in result.output

    result = runner.invoke(app, ["--config", str(cfg), "config", "get", "facts.provider"])
    assert result.exit_code == 0
    assert result.output.strip() == "ollama"

    result = runner.invoke(app, ["--config", str(cfg), "config", "get", "placeholders.materialize"])
    assert result.output.strip() == "true"

    result = runner.invoke(app, ["--config", str(cfg), "config", "get", "facts.model"])
    assert result.output.strip() == "gemma-4-e4b"


def test_config_set_creates_the_default_file_when_none_exists(tmp_path, monkeypatch):
    import json
    from pathlib import Path

    monkeypatch.chdir(tmp_path)
    monkeypatch.setattr(Path, "home", classmethod(lambda cls: tmp_path))
    result = runner.invoke(app, ["config", "set", "facts.model", "phi-4-mini"])
    assert result.exit_code == 0, result.output
    written = tmp_path / ".garage.json"
    assert written.is_file()
    assert json.loads(written.read_text())["facts"]["model"] == "phi-4-mini"
    assert "facts.model = phi-4-mini" in result.output


def test_config_set_unknown_key_lists_valid_keys(tmp_path):
    cfg = tmp_path / "garage.json"
    cfg.write_text("{}")
    result = runner.invoke(app, ["--config", str(cfg), "config", "set", "facts.modle", "x"])
    assert result.exit_code == 2
    assert "unknown key" in result.output
    assert "facts.model" in result.output
    assert cfg.read_text() == "{}"


def test_config_set_rejects_bad_value(tmp_path):
    cfg = tmp_path / "garage.json"
    cfg.write_text("{}")
    result = runner.invoke(app, ["--config", str(cfg), "config", "set", "chunking.size", "big"])
    assert result.exit_code == 2
    assert "expected an integer" in result.output


def test_config_get_reflects_environment_override(tmp_path, monkeypatch):
    cfg = tmp_path / "garage.json"
    cfg.write_text("{}")
    monkeypatch.setenv("GARAGE_DATABASE_URL", "postgresql://u:p@localhost/x")
    result = runner.invoke(app, ["--config", str(cfg), "config", "get", "database.url"])
    assert result.output.strip() == "postgresql+psycopg://u:p@localhost/x"


# ---------------------------------------------------------------------------
# garage ask
# ---------------------------------------------------------------------------
def _ask_result():
    from garage_rag.mcp_server.server import AskResult, Citation

    return AskResult(
        answer="Widgets ship on Tuesdays [1].",
        model="gemma2-2b",
        provider="llama_xpc",
        question="when do widgets ship?",
        citations=[
            Citation(n=1, document_id=7, title="Ops notes", location="~/notes/ops.md", snippet="ship Tue", score=0.5)
        ],
        prompt_tokens=120,
        completion_tokens=9,
    )


def test_ask_prints_answer_and_citations(tmp_path):
    from unittest.mock import patch

    cfg = tmp_path / "garage.json"
    cfg.write_text("{}")
    with patch("garage_rag.mcp_server.server.rag_ask", return_value=_ask_result()) as mock_ask:
        result = runner.invoke(app, ["--config", str(cfg), "ask", "when do widgets ship?", "--limit", "3"])
    assert result.exit_code == 0, result.output
    assert "Widgets ship on Tuesdays [1]." in result.output
    assert "Ops notes" in result.output
    assert "llama_xpc/gemma2-2b" in result.output
    kwargs = mock_ask.call_args.kwargs
    assert kwargs["question"] == "when do widgets ship?"
    assert kwargs["limit"] == 3
    assert "max_tokens" not in kwargs  # unset options leave the tool's defaults alone


def test_ask_json_is_the_dataclass(tmp_path):
    import json
    from unittest.mock import patch

    cfg = tmp_path / "garage.json"
    cfg.write_text("{}")
    with patch("garage_rag.mcp_server.server.rag_ask", return_value=_ask_result()):
        result = runner.invoke(
            app, ["--config", str(cfg), "ask", "q", "--json", "--max-tokens", "64", "--temperature", "0"]
        )
    assert result.exit_code == 0, result.output
    payload = json.loads(result.output)
    assert payload["answer"] == "Widgets ship on Tuesdays [1]."
    assert payload["model"] == "gemma2-2b"
    assert payload["provider"] == "llama_xpc"
    assert payload["citations"][0] == {
        "n": 1,
        "document_id": 7,
        "title": "Ops notes",
        "location": "~/notes/ops.md",
        "snippet": "ship Tue",
        "score": 0.5,
    }
    assert payload["prompt_tokens"] == 120


def test_ask_raw_uses_rag_generate(tmp_path):
    import json
    from unittest.mock import patch

    from garage_rag.mcp_server.server import GenerateResult

    cfg = tmp_path / "garage.json"
    cfg.write_text("{}")
    with patch(
        "garage_rag.mcp_server.server.rag_generate",
        return_value=GenerateResult(text="hello", model="gemma2-2b", provider="llama_xpc"),
    ) as mock_generate:
        result = runner.invoke(app, ["--config", str(cfg), "ask", "--raw", "say hello", "--json"])
    assert result.exit_code == 0, result.output
    assert json.loads(result.output) == {"text": "hello", "model": "gemma2-2b", "provider": "llama_xpc"}
    assert mock_generate.call_args.kwargs == {"prompt": "say hello"}


def test_ask_reports_an_unavailable_model(tmp_path):
    from unittest.mock import patch

    from garage_rag.enrich.generation import LocalModelUnavailable

    cfg = tmp_path / "garage.json"
    cfg.write_text("{}")
    with patch(
        "garage_rag.mcp_server.server.rag_ask",
        side_effect=LocalModelUnavailable("local model 'gemma2-2b' is not available from the app's LlamaXPCService"),
    ):
        result = runner.invoke(app, ["--config", str(cfg), "ask", "q"])
    assert result.exit_code == 1
    assert "model unavailable" in result.output
    assert "LlamaXPCService" in result.output


def test_database_errors_are_reported_not_raised(monkeypatch, capsys):
    """A driver error reaching main_cli prints a message and exits 1."""
    import psycopg

    def boom():
        raise psycopg.OperationalError("connection refused")

    monkeypatch.setattr("garage_rag.cli.app", boom)
    assert main_cli() == 1
    assert "database error" in capsys.readouterr().out


def test_pgvector_hint_keys_on_the_sqlstate():
    from garage_rag.cli import _pgvector_library_hint

    class Missing(Exception):
        sqlstate = "58P01"

    wrapped = RuntimeError("outer")
    wrapped.__cause__ = Missing("could not access file vector")
    assert "pgvector" in _pgvector_library_hint(wrapped)
    assert _pgvector_library_hint(RuntimeError("other")) is None


def _prompts_config(tmp_path):
    import json

    cfg = tmp_path / "garage.json"
    people = {
        "name": "people",
        "description": "List every person named.",
        "corpus_classes": ["document"],
        "examples": [{"text": "Jane met Bob.", "extractions": [{"class": "person", "text": "Jane"}]}],
    }
    cfg.write_text(json.dumps({"facts": {"prompts": [{"name": "default", "enabled": False}, people]}}))
    return cfg


def test_facts_prompts_list_shows_the_default_and_configured_prompts(tmp_path):
    import json

    cfg = _prompts_config(tmp_path)
    result = runner.invoke(app, ["--config", str(cfg), "facts", "prompts", "list", "--json"])
    assert result.exit_code == 0, result.output
    prompts = json.loads(result.output)
    assert [(p["name"], p["enabled"], p["builtin"], p["customized"]) for p in prompts] == [
        ("default", False, True, True),
        ("people", True, False, False),
    ]
    assert prompts[0]["description"].startswith("Extract every standalone fact")
    assert len(prompts[1]["sha256"]) == 64

    table = runner.invoke(app, ["--config", str(cfg), "facts", "prompts", "list"])
    assert table.exit_code == 0 and "people" in table.output and "default" in table.output


def test_facts_prompts_show(tmp_path):
    cfg = _prompts_config(tmp_path)
    result = runner.invoke(app, ["--config", str(cfg), "facts", "prompts", "show", "people"])
    assert result.exit_code == 0, result.output
    assert "List every person named." in result.output
    assert "[person] Jane" in result.output

    missing = runner.invoke(app, ["--config", str(cfg), "facts", "prompts", "show", "nope"])
    assert missing.exit_code == 1
    assert "unknown fact prompt" in missing.output


def test_config_get_prints_prompts_as_json(tmp_path):
    import json

    cfg = _prompts_config(tmp_path)
    result = runner.invoke(app, ["--config", str(cfg), "config", "get", "facts.prompts"])
    assert result.exit_code == 0, result.output
    assert [p["name"] for p in json.loads(result.output)] == ["default", "people"]


def test_enrich_facts_passes_prompts_and_stale_only(tmp_path, monkeypatch):
    from garage_rag.ops.facts import EnrichSummary

    received = {}

    def fake(**kwargs):
        received.update(kwargs)
        return EnrichSummary("m", "ollama", total=1, enriched=0, facts=0, failed=0, skipped=1, prompts=["people"])

    monkeypatch.setattr("garage_rag.ops.facts.enrich_facts", fake)
    cfg = _prompts_config(tmp_path)
    result = runner.invoke(
        app, ["--config", str(cfg), "enrich-facts", "--prompt", "people", "-p", "default", "--stale-only"]
    )
    assert result.exit_code == 0, result.output
    assert received["prompts"] == ["people", "default"] and received["stale_only"] is True
    assert "1 skipped" in result.output and "prompts: people" in result.output
