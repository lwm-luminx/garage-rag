from __future__ import annotations

import hashlib
import json
import sys
import threading
from collections.abc import Iterator
from http.server import BaseHTTPRequestHandler, HTTPServer
from unittest.mock import MagicMock

import pytest

from garage_rag.config import Settings, reset_settings, set_settings
from garage_rag.config.fact_prompts import (
    DEFAULT_DESCRIPTION,
    FactExample,
    FactExtractionExample,
    FactPrompt,
    effective_prompts,
)
from garage_rag.db.models import Chunk, CorpusClass, Document, Fact, FactRun
from garage_rag.enrich import langextract as lx
from garage_rag.enrich.facts import (
    DEFAULT_MODEL_ID,
    GPT_OSS_SYSTEM_PROMPT,
    OLLAMA_RESPONSE_FORMAT,
    chunk_for_fact,
    extract_and_store_facts,
    extract_facts,
    facts_from_extractions,
    facts_language_model,
    is_stale,
    refuse_cloud_model_id,
)
from garage_rag.enrich.local_provider import LocalLanguageModel
from garage_rag.inference import BackendKind, ChatResult, InferenceHTTPError, InferenceUnreachable
from garage_rag.net.egress import EgressBlocked
from garage_rag.xpc.llama_xpc import LlamaXPCClient


def _extraction(text: str, *, start: int, end: int, attributes: dict | None = None) -> lx.data.Extraction:
    return lx.data.Extraction(
        extraction_class="fact",
        extraction_text=text,
        char_interval=lx.data.CharInterval(start_pos=start, end_pos=end),
        attributes=attributes,
    )


def test_extract_facts_stays_local_and_drops_ungrounded(monkeypatch) -> None:
    captured: dict = {}

    grounded = _extraction("Acme Corp was founded in 1998.", start=0, end=31)
    ungrounded = lx.data.Extraction(extraction_class="fact", extraction_text="not in the text")

    class Result:
        extractions = [grounded, ungrounded]

    def fake_extract(**kwargs):
        captured.update(kwargs)
        return Result()

    monkeypatch.setattr("garage_rag.enrich.facts.lx.extract", fake_extract)
    set_settings(Settings(ollama_host="http://127.0.0.1:11434"))
    try:
        extractions = extract_facts("Acme Corp was founded in 1998.")
    finally:
        reset_settings()

    assert extractions == [grounded]
    model = captured["model"]
    assert isinstance(model, LocalLanguageModel)
    assert model.model_id == DEFAULT_MODEL_ID
    assert model.client.kind is BackendKind.OLLAMA
    assert model.client.base_url == "http://127.0.0.1:11434"
    assert captured["prompt_description"]
    assert captured["examples"]


@pytest.mark.parametrize(
    "model_id", ["gemini-2.5-flash", "Gemini-Pro", "gpt-4o", "gpt-5", "gpt-3.5-turbo", "o1-mini", "o3", "claude-x"]
)
@pytest.mark.parametrize("provider", ["ollama", "llama_xpc", "lmstudio"])
def test_cloud_model_id_is_refused(monkeypatch, model_id: str, provider: str) -> None:
    """``--model gemini-2.5-flash`` is a clear error, never a request to anything."""

    def fail(**kwargs):
        raise AssertionError("extract must not run for a cloud model id")

    monkeypatch.setattr("garage_rag.enrich.facts.lx.extract", fail)
    with pytest.raises(ValueError, match="cloud-hosted model"):
        extract_facts("some text", model_id=model_id, provider=provider)


@pytest.mark.parametrize("model_id", [DEFAULT_MODEL_ID, "gemma2-2b", "gpt-oss:20b", "llama3.2:1b", "qwen2.5:7b"])
def test_local_model_ids_are_accepted(model_id: str) -> None:
    refuse_cloud_model_id(model_id)


def test_upstream_langextract_is_never_imported() -> None:
    """The vendored subset stands alone; upstream's package routes to Google and OpenAI."""
    import garage_rag.enrich.facts  # noqa: F401

    assert not [name for name in sys.modules if name == "langextract" or name.startswith("langextract.")]


# ---- end to end, against fake local servers ---------------------------------

_DOCUMENT = "Acme Corp was founded in 1998 by Jane Doe. The company is headquartered in Austin, Texas."
_ANSWER = json.dumps(
    {
        "extractions": [
            {"fact": "Acme Corp was founded in 1998 by Jane Doe."},
            {"fact": "The company is headquartered in Austin, Texas."},
            {"fact": "Something the document never says."},
        ]
    }
)


@pytest.fixture
def local_model_server() -> Iterator[tuple[str, list[tuple[str, dict]]]]:
    """A loopback server answering ``/v1/chat/completions`` like Ollama, LM Studio and llama-server do."""
    requests: list[tuple[str, dict]] = []

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args) -> None:
            pass

        def do_POST(self) -> None:
            body = json.loads(self.rfile.read(int(self.headers["content-length"])))
            requests.append((self.path, body))
            if self.path == "/v1/chat/completions":
                status, reply = 200, {"choices": [{"message": {"role": "assistant", "content": _ANSWER}}]}
            else:
                status, reply = 404, {"error": f"unknown route {self.path}"}
            data = json.dumps(reply).encode()
            self.send_response(status)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

    server = HTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    url = f"http://127.0.0.1:{server.server_port}"
    set_settings(Settings(ollama_host=url, llama_host=url, lmstudio_host=f"{url}/v1"))
    try:
        yield url, requests
    finally:
        reset_settings()
        server.shutdown()
        server.server_close()


@pytest.mark.parametrize(
    ("provider", "model_id"),
    [
        ("ollama", DEFAULT_MODEL_ID),
        ("ollama", "gpt-oss:20b"),
        ("llama_xpc", "gemma2-2b"),
        ("lmstudio", "google/gemma-3-4b"),
    ],
)
def test_extract_facts_end_to_end(local_model_server, provider: str, model_id: str) -> None:
    """A real run through the vendored LangExtract: prompt, parse, align, ground."""
    _, requests = local_model_server

    extractions = extract_facts(_DOCUMENT, model_id=model_id, provider=provider)

    assert [(e.extraction_text, e.char_interval.start_pos, e.char_interval.end_pos) for e in extractions] == [
        ("Acme Corp was founded in 1998 by Jane Doe.", 0, 42),
        ("The company is headquartered in Austin, Texas.", 43, 89),
    ]
    assert [path for path, _ in requests] == ["/v1/chat/completions"]
    body = requests[0][1]
    assert body["model"] == model_id
    prompt = body["messages"][-1]["content"]
    assert prompt.startswith("Extract every standalone fact stated in this document.")
    assert prompt.rstrip().endswith("A:") and _DOCUMENT in prompt
    if provider != "ollama":
        # LM Studio refuses json_object, and llama_xpc never had it: prompt-only, server defaults.
        assert "response_format" not in body and "temperature" not in body
        assert [m["role"] for m in body["messages"]] == ["user"]
    elif model_id.startswith("gpt-oss"):
        # JSON mode conflicts with GPT-OSS's response format; a system instruction replaces it.
        assert "response_format" not in body
        assert body["messages"][0] == {"role": "system", "content": GPT_OSS_SYSTEM_PROMPT}
        assert body["temperature"] == 0.1
    else:
        assert body["response_format"] == {"type": "json_object"}
        assert body["temperature"] == 0.1


def test_a_missing_model_is_an_inference_error_naming_the_server() -> None:
    client = MagicMock()
    client.backend.label = "Ollama"
    client.chat.side_effect = InferenceHTTPError("model 'missing:1b' not found", status_code=404)
    model = LocalLanguageModel("missing:1b", client)
    with pytest.raises(lx.exceptions.InferenceRuntimeError, match="Ollama inference failed: model 'missing:1b'"):
        list(model.infer(["prompt"]))


def test_extract_facts_routes_to_llama_xpc_when_requested(monkeypatch) -> None:
    captured: dict = {}

    grounded = _extraction("Acme Corp was founded in 1998.", start=0, end=31)

    class Result:
        extractions = [grounded]

    def fake_extract(**kwargs):
        captured.update(kwargs)
        return Result()

    monkeypatch.setattr("garage_rag.enrich.facts.lx.extract", fake_extract)

    extractions = extract_facts("Acme Corp was founded in 1998.", model_id="gemma2-2b", provider="llama_xpc")

    assert extractions == [grounded]
    assert isinstance(captured["model"], LocalLanguageModel)
    assert isinstance(captured["model"].client, LlamaXPCClient)
    assert captured["model"].model_id == "gemma2-2b"
    assert "model_id" not in captured
    assert "model_url" not in captured


def test_extract_facts_rejects_unknown_provider() -> None:
    try:
        extract_facts("text", provider="bogus")
    except ValueError as exc:
        assert "bogus" in str(exc)
    else:
        raise AssertionError("expected ValueError for an unknown provider")


def test_facts_language_model_per_provider() -> None:
    set_settings(Settings())
    try:
        llama = facts_language_model("llama_xpc", "gemma2-2b")
        ollama = facts_language_model("ollama", "gemma2:2b")
        gpt_oss = facts_language_model("ollama", "gpt-oss:20b")
        lmstudio = facts_language_model("lmstudio", "google/gemma-3-4b")
        override = facts_language_model("ollama", "gemma2:2b", "http://127.0.0.1:11500")
    finally:
        reset_settings()

    assert isinstance(llama.client, LlamaXPCClient)
    assert llama.client.base_url == "http://127.0.0.1:8790"
    # Each backend keeps the request settings it had before: Ollama what
    # LangExtract's own Ollama provider sent, the others prompt-only.
    assert (llama._temperature, llama._response_format, llama._system_prompt) == (None, None, None)
    assert (ollama._temperature, ollama._response_format) == (0.1, OLLAMA_RESPONSE_FORMAT)
    assert ollama.client.base_url == "http://localhost:11434"
    assert (gpt_oss._response_format, gpt_oss._system_prompt) == (None, GPT_OSS_SYSTEM_PROMPT)
    # LM Studio answers HTTP 400 to response_format json_object.
    assert (lmstudio._temperature, lmstudio._response_format) == (None, None)
    assert lmstudio.client.base_url == "http://localhost:1234"
    assert override.client.base_url == "http://127.0.0.1:11500"


def test_local_language_model_infers_via_chat() -> None:
    fake_client = MagicMock()
    fake_client.chat.return_value = ChatResult(text='{"extractions": []}')

    model = LocalLanguageModel("gemma2:2b", fake_client, temperature=0.1, response_format={"a": 1}, system_prompt="S")
    results = list(model.infer(["prompt one", "prompt two"]))

    assert len(results) == 2
    assert results[0][0].output == '{"extractions": []}'
    assert fake_client.chat.call_count == 2
    first = fake_client.chat.call_args_list[0]
    assert first.args == (
        [{"role": "system", "content": "S"}, {"role": "user", "content": "prompt one"}],
        "gemma2:2b",
    )
    assert first.kwargs == {"temperature": 0.1, "response_format": {"a": 1}}


def test_local_language_model_failure_names_the_server() -> None:
    fake_client = MagicMock()
    fake_client.backend.label = "LM Studio"
    fake_client.chat.side_effect = InferenceUnreachable("cannot reach LM Studio at http://localhost:1234")
    model = LocalLanguageModel("m", fake_client)
    with pytest.raises(lx.exceptions.InferenceRuntimeError, match="LM Studio inference failed: cannot reach"):
        list(model.infer(["p"]))


def test_facts_from_extractions_preserves_order_and_grounding() -> None:
    extractions = [
        _extraction("First fact.", start=0, end=11, attributes={"topic": "a"}),
        _extraction("Second fact.", start=12, end=24),
    ]

    facts = facts_from_extractions(document_id=7, extractions=extractions, model_id="gemma2:2b")

    assert [f.ord for f in facts] == [0, 1]
    assert [f.fact for f in facts] == ["First fact.", "Second fact."]
    assert facts[0].attributes == {"topic": "a"}
    assert facts[1].attributes == {}
    assert facts[0].char_start == 0 and facts[0].char_end == 11
    assert all(f.document_id == 7 for f in facts)
    assert all(f.extractor == "langextract" for f in facts)
    assert all(f.extractor_model == "gemma2:2b" for f in facts)


def test_chunk_for_fact_builds_an_embeddable_chunk_row() -> None:
    fact = Fact(id=42, document_id=7, fact="Acme Corp was founded in 1998.")

    chunk = chunk_for_fact(fact, ord=5, model_id="gemma2:2b")

    assert isinstance(chunk, Chunk)
    assert chunk.document_id == 7
    assert chunk.ord == 5
    assert chunk.text == "Acme Corp was founded in 1998."
    assert chunk.fact_id == 42
    assert chunk.chunker == "facts:langextract:gemma2:2b"
    assert chunk.chunk_sha256 == hashlib.sha256(b"Acme Corp was founded in 1998.").digest()


def test_extract_and_store_facts_queues_chunks_after_existing_ones(monkeypatch) -> None:
    document = Document(id=9, content="Acme Corp was founded in 1998. It is public.")
    extraction = _extraction("Acme Corp was founded in 1998.", start=0, end=31)

    monkeypatch.setattr(
        "garage_rag.enrich.facts.extract_facts",
        lambda text, **kwargs: [extraction],
    )

    session = MagicMock()
    # Shared by the facts-delete query and the max(ord) lookup; only the
    # latter's .scalar() return value is exercised.
    session.query.return_value.filter.return_value.scalar.return_value = 4

    added: list = []
    session.add_all.side_effect = lambda items: added.extend(items)

    def fake_flush() -> None:
        for i, obj in enumerate(o for o in added if isinstance(o, Fact)):
            obj.id = 100 + i

    session.flush.side_effect = fake_flush

    extract_and_store_facts(session, document)

    assert session.flush.called
    fact_rows = [row for row in added if isinstance(row, Fact)]
    chunk_rows = [row for row in added if isinstance(row, Chunk)]
    assert len(fact_rows) == 1
    assert len(chunk_rows) == 1
    # base_ord = max(existing ord) + 1 = 5
    assert chunk_rows[0].ord == 5
    assert chunk_rows[0].fact_id == fact_rows[0].id


def test_extract_and_store_facts_empty_content_clears_stale_facts(monkeypatch) -> None:
    document = Document(id=9, content="")
    called = False

    def fake_extract_facts(text, **kwargs):
        nonlocal called
        called = True
        return []

    monkeypatch.setattr("garage_rag.enrich.facts.extract_facts", fake_extract_facts)
    session = MagicMock()

    assert extract_and_store_facts(session, document) == []

    assert not called
    # The stale rows for a now-empty document are removed, not left behind.
    session.query.return_value.filter.return_value.delete.assert_called_once()
    assert not session.add_all.called


@pytest.mark.parametrize("provider", ["ollama", "lmstudio", "llama_xpc"])
@pytest.mark.parametrize("corpus_class", [CorpusClass.COMMUNICATION, CorpusClass.DOCUMENT])
def test_an_unapproved_host_is_refused_for_every_class(monkeypatch, corpus_class: CorpusClass, provider: str) -> None:
    """A host that is neither loopback nor configured gets nothing, before stored facts are touched."""
    document = Document(id=9, content="hi", corpus_class=corpus_class)
    called = False

    def fake_extract_facts(text, **kwargs):
        nonlocal called
        called = True
        return []

    monkeypatch.setattr("garage_rag.enrich.facts.extract_facts", fake_extract_facts)
    session = MagicMock()
    with pytest.raises(EgressBlocked):
        extract_and_store_facts(session, document, model_url="http://ollama.example:11434", provider=provider)

    assert not called
    assert not session.query.called


@pytest.mark.parametrize("provider", ["ollama", "lmstudio"])
def test_a_configured_remote_host_takes_documents_but_not_communications(monkeypatch, provider: str) -> None:
    captured: dict = {}

    def fake_extract_facts(text, **kwargs):
        captured.update(kwargs)
        return []

    monkeypatch.setattr("garage_rag.enrich.facts.extract_facts", fake_extract_facts)
    set_settings(Settings(ollama_host="http://gpu.example:11434", lmstudio_host="http://lm.example:1234/v1"))
    try:
        document = Document(id=9, content="hi", corpus_class=CorpusClass.DOCUMENT)
        assert extract_and_store_facts(MagicMock(), document, provider=provider) == []
        assert captured["corpus_class"] is CorpusClass.DOCUMENT
        session = MagicMock()
        message = Document(id=10, content="hi", corpus_class=CorpusClass.COMMUNICATION)
        with pytest.raises(EgressBlocked, match="communications may never"):
            extract_and_store_facts(session, message, provider=provider)
        assert not session.query.called
        # And the client itself refuses, should a caller skip the check.
        with pytest.raises(EgressBlocked):
            facts_language_model(provider, "m", corpus_class=CorpusClass.COMMUNICATION)
    finally:
        reset_settings()


def test_loopback_ollama_host_takes_communications(monkeypatch) -> None:
    """Local inference is not egress; communications are fine on loopback."""
    document = Document(id=9, content="hi", corpus_class=CorpusClass.COMMUNICATION)
    monkeypatch.setattr("garage_rag.enrich.facts.extract_facts", lambda text, **kwargs: [])
    session = MagicMock()
    set_settings(Settings(ollama_host="http://127.0.0.1:11434"))
    try:
        assert extract_and_store_facts(session, document) == []
    finally:
        reset_settings()


def test_extract_and_store_facts_can_skip_embedding_queue(monkeypatch) -> None:
    document = Document(id=9, content="Acme Corp was founded in 1998.")
    extraction = _extraction("Acme Corp was founded in 1998.", start=0, end=31)

    monkeypatch.setattr(
        "garage_rag.enrich.facts.extract_facts",
        lambda text, **kwargs: [extraction],
    )

    session = MagicMock()
    added: list = []
    session.add_all.side_effect = lambda items: added.extend(items)

    extract_and_store_facts(session, document, queue_for_embedding=False)

    assert not session.flush.called
    assert all(isinstance(row, Fact) for row in added)
    assert len(added) == 1


# ---- prompts ------------------------------------------------------------------

_PEOPLE = FactPrompt(
    name="people",
    description="List every person named.",
    examples=[
        FactExample(
            text="Jane met Bob.",
            extractions=[FactExtractionExample(extraction_class="person", text="Jane", attributes={"role": "host"})],
        )
    ],
)


def _people():
    return next(p for p in effective_prompts([_PEOPLE]) if p.name == "people")


def test_extract_facts_sends_the_prompts_own_text_and_examples(monkeypatch) -> None:
    captured: dict = {}

    class Result:
        extractions: list = []

    def fake_extract(**kwargs):
        captured.update(kwargs)
        return Result()

    monkeypatch.setattr("garage_rag.enrich.facts.lx.extract", fake_extract)
    extract_facts("Jane met Bob.", prompt=_people(), provider="llama_xpc", model_id="gemma2-2b")

    assert captured["prompt_description"] == "List every person named."
    (example,) = captured["examples"]
    assert example.text == "Jane met Bob."
    (extraction,) = example.extractions
    assert (extraction.extraction_class, extraction.extraction_text, extraction.attributes) == (
        "person",
        "Jane",
        {"role": "host"},
    )


def test_the_default_prompt_is_the_built_in_one(monkeypatch) -> None:
    captured: dict = {}

    class Result:
        extractions: list = []

    def fake_extract(**kwargs):
        captured.update(kwargs)
        return Result()

    monkeypatch.setattr("garage_rag.enrich.facts.lx.extract", fake_extract)
    extract_facts("text", provider="llama_xpc", model_id="gemma2-2b")
    assert captured["prompt_description"] == DEFAULT_DESCRIPTION
    assert captured["examples"][0].extractions[0].extraction_class == "fact"


def test_facts_record_their_prompt() -> None:
    people = _people()
    facts = facts_from_extractions(7, [_extraction("Jane", start=0, end=4)], prompt=people)
    assert facts[0].prompt_name == "people"
    assert facts[0].prompt_sha256 == people.sha256
    assert facts_from_extractions(7, [_extraction("x", start=0, end=1)])[0].prompt_name == "default"


def test_re_extraction_deletes_only_this_prompts_facts_and_records_the_run(monkeypatch) -> None:
    document = Document(id=9, content="Jane met Bob.", content_sha256=b"c")
    monkeypatch.setattr("garage_rag.enrich.facts.extract_facts", lambda text, **kwargs: [])
    people = _people()
    session = MagicMock()

    extract_and_store_facts(session, document, prompt=people, model_id="gemma2-2b", provider="llama_xpc")

    (criteria,) = [call.args for call in session.query.return_value.filter.call_args_list]
    assert [(c.left.name, c.right.value) for c in criteria] == [("document_id", 9), ("prompt_name", "people")]
    (run,) = [call.args[0] for call in session.merge.call_args_list]
    assert isinstance(run, FactRun)
    assert (run.document_id, run.prompt_name, run.prompt_sha256, run.content_sha256, run.extractor_model) == (
        9,
        "people",
        people.sha256,
        b"c",
        "gemma2-2b",
    )
    assert run.facts == 0


def test_is_stale() -> None:
    prompt = effective_prompts([])[0]
    document = Document(id=1, content_sha256=b"c")
    fresh = FactRun(prompt_sha256=prompt.sha256, content_sha256=b"c", extractor_model="m")
    assert not is_stale(fresh, document, prompt, "m")
    assert is_stale(None, document, prompt, "m")
    assert is_stale(fresh, document, prompt, "other")
    assert is_stale(fresh, Document(id=1, content_sha256=b"d"), prompt, "m")
    reworded = effective_prompts([FactPrompt(name="default", description="Other.")])[0]
    assert is_stale(fresh, document, reworded, "m")


class TestEnrichFactsRebuildsTheGraph:
    """A glean gives a document's facts new ids, so the graph is re-projected; otherwise the Graph
    page's Show in Graph looks for a vertex that is gone and finds nothing until the next Distill Facts."""

    @pytest.fixture
    def run(self, monkeypatch) -> Iterator:
        from contextlib import contextmanager

        from garage_rag.db.graph import GraphSummary
        from garage_rag.ops import facts as ops_facts

        document = Document(id=7, uri="file:///note.md", content="Some text.", corpus_class=CorpusClass.DOCUMENT)
        session = MagicMock()
        session.get.return_value = document
        session.query.return_value.all.return_value = []

        @contextmanager
        def scope():
            yield session

        rebuilds: list[object] = []

        def rebuild_graph(s):
            rebuilds.append(s)
            return GraphSummary(available=True, vertices={"Fact": 2})

        monkeypatch.setattr(ops_facts, "session_scope", scope)
        monkeypatch.setattr("garage_rag.enrich.facts.configured_backend", lambda model, provider: ("m", "ollama"))
        monkeypatch.setattr("garage_rag.enrich.metadata.store_metadata_facts", lambda s, d: [])
        monkeypatch.setattr("garage_rag.db.graph.rebuild_graph", rebuild_graph)

        def go(extracted: list | Exception):
            def extract(*args, **kwargs):
                if isinstance(extracted, Exception):
                    raise extracted
                return extracted

            monkeypatch.setattr("garage_rag.enrich.facts.extract_and_store_facts", extract)
            return ops_facts.enrich_facts(document_id=7), rebuilds

        yield go

    def test_a_glean_that_ran_rebuilds_the_graph(self, run) -> None:
        summary, rebuilds = run([MagicMock(), MagicMock()])
        assert summary.facts == 2
        assert len(rebuilds) == 1
        assert summary.graph
        assert summary.message.endswith(summary.graph)

    def test_a_glean_that_wrote_nothing_leaves_the_graph(self, run) -> None:
        summary, rebuilds = run(RuntimeError("model gone"))
        assert summary.failed == 1
        assert rebuilds == []
        assert summary.graph == ""

    def test_a_failed_rebuild_is_reported_not_raised(self, run, monkeypatch) -> None:
        def broken(session):
            raise RuntimeError("no graph for you")

        monkeypatch.setattr("garage_rag.db.graph.rebuild_graph", broken)
        summary, _ = run([MagicMock()])
        assert summary.facts == 1
        assert "graph not rebuilt" in summary.graph
