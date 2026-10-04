"""End to end: the real ``garage`` and ``garage-mcp`` processes over a real database.

Every other test either mocks the database or calls the pipeline in-process. These run the
commands a person at a terminal runs, each as its own child process with its own config file,
against a throwaway database on the ``GARAGE_TEST_DATABASE_URL`` server and a fake Ollama on
loopback:

    init-db -> register-model -> add-source -> scan -> ingest -> backfill -> search -> garage-mcp

The corpus is the UI tests' fixture corpus (``macapp/Tests/Fixtures/corpus``), so what the
macOS UI tests check through the app is checked here through the CLI. The fake Ollama answers
``POST /api/embed`` with hashed bag-of-words vectors: a query made of one file's token lands
nearest that file's chunks, so vector search can be judged without a real model.

Like ``test_postgres.py`` this runs only when ``GARAGE_TEST_DATABASE_URL`` names a superuser on
a development server (Homebrew on a Mac, the devcontainer, CI's service container); unset, the
module is skipped. Each run creates a ``garage_e2e_*`` database and drops it afterwards.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import re
import shutil
import subprocess
import sys
import threading
import uuid
from collections.abc import Iterator
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

import pytest
from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine, make_url

from garage_rag.config import ensure_psycopg_database_url, repo_root
from garage_rag.db.migrate import _connect, to_psycopg_conninfo

TEST_URL_ENV = "GARAGE_TEST_DATABASE_URL"
TIMEOUT = 300

pytestmark = pytest.mark.skipif(
    not os.environ.get(TEST_URL_ENV),
    reason=f"{TEST_URL_ENV} is not set; see 'Testing against Postgres' in CLAUDE.md",
)

CORPUS = repo_root() / "macapp" / "Tests" / "Fixtures" / "corpus"

# file -> (title, corpus class, trust tier, the file's unique token); macapp/Tests/Fixtures/README.md.
EXPECTED = {
    "quillon-bridge.md": ("The Quillon Bridge", "document", "authored", "zorvexine"),
    "marrowgate-lighthouse.txt": ("Marrowgate Lighthouse", "document", "authored", "plimbrate"),
    "tide_tables.rs": ("tide_tables.rs", "code", "authored", "tessaroon"),
    "lantern-festival.eml": ("The Brindlecombe lantern festival", "communication", "received", "wendleflock"),
    "ashvale-orchard.pdf": ("The Ashvale Orchard Survey", "document", "reference", "orbanquet"),
    "tavish-glassworks.docx": ("A History of Tavish Glassworks", "document", "reference", "glimmerhaft"),
}
# With code on, the Markdown note splits at its "## Repairs" heading: seven chunks for six files.
EXPECTED_CHUNKS = 7

MODEL = "e2e-hash"
# Wide enough that no file's token shares a hash bucket with a word of another file's chunks
# (at 256, "wendleflock" collides with one in the Quillon note); within `vector`'s HNSW ceiling.
DIMS = 1024

# Each child runs its module through this, so it loads the libpq conftest.py loads (Bazel's, on
# macOS) before garage_rag looks for one; a child never runs conftest.py.
CHILD_BOOTSTRAP = """\
import ctypes, os, runpy, sys
libpq = os.environ.get("GARAGE_TEST_LIBPQ")
if libpq:
    ctypes.CDLL(libpq, mode=ctypes.RTLD_GLOBAL)
module = sys.argv.pop(1)
runpy.run_module(module, run_name="__main__", alter_sys=True)
"""


def child_command(module: str, *args: str) -> list[str]:
    return [sys.executable, "-c", CHILD_BOOTSTRAP, module, *args]


# The vendored cluster's port: it holds the real corpus, and nothing here may touch it.
APP_CLUSTER_PORT = 14824


# ---- fake Ollama ---------------------------------------------------------------


def hashed_embedding(text_in: str, dims: int = DIMS) -> list[float]:
    """A unit bag-of-words vector: each word adds +-1 to one bucket, both chosen by its hash."""
    vector = [0.0] * dims
    for word in re.findall(r"\w+", text_in.lower()):
        digest = hashlib.sha256(word.encode()).digest()
        bucket = int.from_bytes(digest[:4], "big") % dims
        vector[bucket] += 1.0 if digest[4] & 1 else -1.0
    norm = math.sqrt(sum(v * v for v in vector))
    if norm == 0:
        # Empty text: any fixed unit vector keeps the width right.
        vector[0] = 1.0
        return vector
    return [v / norm for v in vector]


@dataclass
class FakeOllama:
    url: str = ""
    embed_calls: int = 0
    inputs: int = 0


def _handler_for(fake: FakeOllama) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args: Any) -> None:
            pass

        def _reply(self, status: int, payload: Any) -> None:
            body = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:
            if self.path == "/api/tags":
                self._reply(200, {"models": [{"name": MODEL, "model": MODEL}]})
            elif self.path == "/v1/models":
                self._reply(200, {"object": "list", "data": [{"id": MODEL, "object": "model"}]})
            else:
                self._reply(404, {"error": f"no route {self.path}"})

        def do_POST(self) -> None:
            length = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(length) or b"{}")
            if self.path != "/api/embed":
                self._reply(404, {"error": f"no route {self.path}"})
                return
            inputs = body.get("input")
            inputs = [inputs] if isinstance(inputs, str) else list(inputs or [])
            fake.embed_calls += 1
            fake.inputs += len(inputs)
            self._reply(200, {"model": body.get("model"), "embeddings": [hashed_embedding(t) for t in inputs]})

    return Handler


@pytest.fixture(scope="module")
def ollama() -> Iterator[FakeOllama]:
    fake = FakeOllama()
    httpd = ThreadingHTTPServer(("127.0.0.1", 0), _handler_for(fake))
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    fake.url = f"http://127.0.0.1:{httpd.server_address[1]}"
    try:
        yield fake
    finally:
        httpd.shutdown()
        httpd.server_close()
        thread.join(timeout=5)


# ---- database and workspace ----------------------------------------------------


@pytest.fixture(scope="module")
def database_url() -> Iterator[str]:
    """An empty throwaway database (``init-db`` is part of what is tested), dropped afterwards."""
    server = make_url(ensure_psycopg_database_url(os.environ[TEST_URL_ENV]))
    if server.port == APP_CLUSTER_PORT or "host" in server.query:
        pytest.fail(f"{TEST_URL_ENV} looks like the app's own cluster; point it at a development server")
    admin = to_psycopg_conninfo(server.render_as_string(hide_password=False))
    name = f"garage_e2e_{uuid.uuid4().hex[:12]}"
    with _connect(admin) as conn:
        conn.execute(f'CREATE DATABASE "{name}"')
    try:
        yield server.set(database=name).render_as_string(hide_password=False)
    finally:
        with _connect(admin) as conn:
            conn.execute(f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE)')


@pytest.fixture(scope="module")
def db(database_url: str) -> Iterator[Engine]:
    engine = create_engine(database_url)
    try:
        yield engine
    finally:
        engine.dispose()


def scalar(engine: Engine, sql: str, **params: Any) -> Any:
    with engine.connect() as conn:
        return conn.execute(text(sql), params).scalar_one()


@dataclass
class Workspace:
    root: Path
    config: Path
    corpus: Path
    env: dict[str, str]

    def run(self, *args: str, check: bool = True, module: str = "garage_rag.cli") -> subprocess.CompletedProcess:
        """``garage --config <workspace>/garage.json ARGS`` as a child process."""
        result = subprocess.run(
            child_command(module, "--config", str(self.config), *args),
            env=self.env,
            cwd=self.root,
            capture_output=True,
            text=True,
            timeout=TIMEOUT,
        )
        if check and result.returncode != 0:
            pytest.fail(
                f"garage {' '.join(args)} exited {result.returncode}\n"
                f"--- stdout\n{result.stdout}\n--- stderr\n{result.stderr}"
            )
        return result


@pytest.fixture(scope="module")
def workspace(tmp_path_factory: pytest.TempPathFactory, database_url: str, ollama: FakeOllama) -> Workspace:
    root = tmp_path_factory.mktemp("e2e")
    # A copy, so the walk never sees the committed folder (or a README beside it).
    corpus = root / "corpus"
    shutil.copytree(CORPUS, corpus)
    config = root / "garage.json"
    config.write_text(
        json.dumps(
            {
                "identity": {"name": "Fixture Owner"},
                "embedding": {"ollama_host": ollama.url},
            },
            indent=2,
        )
    )
    home = root / "home"
    home.mkdir()
    # Nothing from this shell's Garage setup leaks in: no GARAGE_* (a database URL, a gRPC
    # socket), a HOME of its own so ~/.garage.json is never read, and plain output.
    env = {k: v for k, v in os.environ.items() if not k.startswith("GARAGE_")}
    env |= {
        "GARAGE_DATABASE_URL": database_url,
        "HOME": str(home),
        # The child imports what this process imports (Bazel's runfiles put it on sys.path, not the env).
        "PYTHONPATH": os.pathsep.join(sys.path),
        "COLUMNS": "200",
        "TERM": "dumb",
        "NO_COLOR": "1",
    }
    if libpq := os.environ.get("GARAGE_TEST_LIBPQ"):
        # Relative to the test's working directory, which the children do not share.
        env["GARAGE_TEST_LIBPQ"] = os.path.abspath(libpq)
    return Workspace(root=root, config=config, corpus=corpus, env=env)


# ---- the pipeline, in order ----------------------------------------------------
#
# The tests share one database and run in file order, each building on the last, as a person
# would. A failure early on makes the later ones fail too; read the first.


def test_init_db_applies_the_schema_and_is_idempotent(workspace: Workspace, db: Engine) -> None:
    first = workspace.run("init-db")
    assert "schema ready" in first.stdout
    assert scalar(db, "SELECT count(*) FROM pg_extension WHERE extname = 'vector'") == 1
    # Migrations are written to be re-applied.
    workspace.run("init-db")
    assert scalar(db, "SELECT count(*) FROM documents") == 0


def test_register_model_creates_its_table(workspace: Workspace, db: Engine) -> None:
    result = workspace.run(
        "register-model", MODEL, "--provider", "ollama", "--dims", str(DIMS), "--distance", "cosine", "--default"
    )
    assert "registered" in result.stdout
    listed = json.loads(workspace.run("list-models", "--json").stdout)
    row = next(m for m in listed if m["slug"] == MODEL)
    assert row["dims"] == DIMS
    table = scalar(db, "SELECT table_name FROM embedding_models WHERE slug = :slug", slug=MODEL)
    assert scalar(db, "SELECT to_regclass(:t) IS NOT NULL", t=table)


def test_add_source_and_scan(workspace: Workspace) -> None:
    workspace.run("add-source", "fixture", str(workspace.corpus))
    assert "fixture" in workspace.run("list-sources").stdout
    scanned = json.loads(workspace.run("scan", "--source", "fixture", "--include-code", "--json").stdout)
    assert len(scanned) == 1
    assert scanned[0]["error"] in (None, "")
    assert scanned[0]["item_count"] == len(EXPECTED)


def test_ingest_stores_every_file(workspace: Workspace, db: Engine) -> None:
    workspace.run("ingest", "--source", "fixture", "--include-code")

    with db.connect() as conn:
        rows = conn.execute(
            text("SELECT uri, title, corpus_class::text, trust_tier::text FROM documents ORDER BY uri")
        ).all()
    by_file = {Path(uri).name: (title, cc, trust) for uri, title, cc, trust in rows}
    assert by_file == {name: (title, cc, trust) for name, (title, cc, trust, _token) in EXPECTED.items()}
    assert scalar(db, "SELECT count(*) FROM chunks") == EXPECTED_CHUNKS
    for name, (*_rest, token) in EXPECTED.items():
        holder = scalar(
            db,
            "SELECT string_agg(DISTINCT d.uri, ',') FROM chunks c JOIN documents d ON d.id = c.document_id "
            "WHERE c.text ILIKE :pattern",
            pattern=f"%{token}%",
        )
        assert holder is not None and Path(holder).name == name, f"{token} should be in {name} only: {holder}"


def test_reingest_skips_unchanged_files(workspace: Workspace, db: Engine) -> None:
    chunk_ids = scalar(db, "SELECT array_agg(id ORDER BY id) FROM chunks")
    result = workspace.run("ingest", "--source", "fixture", "--include-code")
    # The progress line a non-terminal run prints; the table after it is drawn in box characters.
    assert f"ingested 0 (skipped {len(EXPECTED)}, failed 0)" in result.stdout, result.stdout
    assert scalar(db, "SELECT array_agg(id ORDER BY id) FROM chunks") == chunk_ids


def test_backfill_embeds_every_chunk(workspace: Workspace, db: Engine, ollama: FakeOllama) -> None:
    before = ollama.inputs
    workspace.run("backfill", "--model", MODEL)
    table = scalar(db, "SELECT table_name FROM embedding_models WHERE slug = :slug", slug=MODEL)
    # Loopback is local, so the mail is embedded too: every chunk has a vector.
    assert scalar(db, f'SELECT count(*) FROM "{table}"') == EXPECTED_CHUNKS
    assert ollama.inputs - before >= EXPECTED_CHUNKS

    again = workspace.run("backfill", "--model", MODEL)
    assert "already complete" in again.stdout


def test_stats_counts_the_corpus(workspace: Workspace) -> None:
    out = workspace.run("stats").stdout
    assert re.search(rf"\bdocuments\b.*\b{len(EXPECTED)}\b", out), out
    assert re.search(rf"\bchunks\b.*\b{EXPECTED_CHUNKS}\b", out), out


@pytest.mark.parametrize("mode", ["fts", "vector", "hybrid"])
@pytest.mark.parametrize("name", list(EXPECTED))
def test_search_finds_each_token_in_its_file(workspace: Workspace, mode: str, name: str) -> None:
    title, _cc, _trust, token = EXPECTED[name]
    out = workspace.run("search", token, "--mode", mode, "--limit", "3").stdout
    first = re.search(r"^\s*1\.\s+(.*?)\s+\(", out, re.MULTILINE)
    assert first is not None, out
    assert first.group(1) == title, out


def test_search_filters_by_class(workspace: Workspace) -> None:
    out = workspace.run("search", "wendleflock", "--mode", "fts", "--class", "document").stdout
    assert "no results" in out
    out = workspace.run("search", "wendleflock", "--mode", "fts", "--class", "communication").stdout
    assert "The Brindlecombe lantern festival" in out


# ---- garage-mcp over stdio ------------------------------------------------------

PROTOCOL_VERSION = "2025-06-18"


class StdioClient:
    def __init__(self, workspace: Workspace) -> None:
        self.proc = subprocess.Popen(
            child_command("garage_rag.mcp_server.server", "--config", str(workspace.config)),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=workspace.env,
            cwd=workspace.root,
            text=True,
        )
        self.next_id = 0

    def send(self, message: dict[str, Any]) -> None:
        assert self.proc.stdin is not None
        self.proc.stdin.write(json.dumps(message) + "\n")
        self.proc.stdin.flush()

    def request(self, method: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params or {}})
        assert self.proc.stdout is not None
        while True:
            line = self.proc.stdout.readline()
            assert line, f"garage-mcp exited: {self.close()}"
            message = json.loads(line)
            if message.get("id") == self.next_id:
                return message

    def call(self, tool: str, **arguments: Any) -> dict[str, Any]:
        reply = self.request("tools/call", {"name": tool, "arguments": arguments})
        result = reply["result"]
        assert not result.get("isError"), result
        return result["structuredContent"]

    def close(self) -> str:
        if self.proc.poll() is None:
            assert self.proc.stdin is not None
            self.proc.stdin.close()
            try:
                self.proc.wait(timeout=60)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait()
        assert self.proc.stderr is not None
        return self.proc.stderr.read()


@pytest.fixture(scope="module")
def mcp(workspace: Workspace) -> Iterator[StdioClient]:
    client = StdioClient(workspace)
    try:
        reply = client.request(
            "initialize",
            {"protocolVersion": PROTOCOL_VERSION, "capabilities": {}, "clientInfo": {"name": "e2e", "version": "0"}},
        )
        assert "error" not in reply, reply
        client.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        yield client
    finally:
        client.close()


def test_mcp_stats_report_the_corpus(mcp: StdioClient) -> None:
    stats = mcp.call("rag_stats")
    assert stats["documents"] == len(EXPECTED)
    assert stats["chunks"] == EXPECTED_CHUNKS
    model = next(m for m in stats["models"] if m["slug"] == MODEL)
    assert model["is_default"]
    assert (model["vectors"], model["pending"]) == (EXPECTED_CHUNKS, 0)


def test_mcp_search_and_fetch_a_document(mcp: StdioClient) -> None:
    found = mcp.call("rag_search", query="glimmerhaft", mode="hybrid", limit=3)
    assert found["model"] == MODEL
    top = found["hits"][0]
    assert top["title"] == "A History of Tavish Glassworks"
    assert top["trust_tier"] == "reference"

    document = mcp.call("rag_get_document", document_id=top["document_id"])
    assert "Tavish Glassworks was founded by Mirela Tavish in 1911" in json.dumps(document)
