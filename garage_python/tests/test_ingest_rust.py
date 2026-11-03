"""The Rust ingest pieces (``rust/garage-ingest``) against the Python they replace.

``garage_rag.ingest.walker``, ``garage_rag.extract.quality`` and ``garage_rag.ingest.chunking`` are
the specification. Each tree below is walked by both walkers, each text judged by both gates and
chunked by both chunkers, through ``libgarage_ingest_ffi``'s C ABI; the files found, the counts, the
verdicts, the reasons, every metric and every chunk (text, ordinal, chunker id, heading path and
offsets) must be identical. The chunking cases include the golden test's, which pin Python's
chunks to the langchain output the index was first built with. The Rust walker's default rules
are held to Python's tables too, so a table edited on one side only fails here. One file through
``pipeline.ingest_one``, with its reads stated rather than made, must end in the same facade calls,
with the same arguments, and move the counters the same way.

The library is found through ``GARAGE_INGEST_FFI_LIBRARY`` or in ``rust/target/{release,debug}``;
without it the tests skip (``cargo build -p garage-ingest-ffi`` in ``rust/`` makes it).
"""

from __future__ import annotations

import ctypes
import dataclasses
import importlib.util
import json
import os
import random
import shutil
import string
import subprocess
import sys
from datetime import UTC, datetime
from pathlib import Path
from types import SimpleNamespace

import pytest

from garage_rag import config
from garage_rag.attribute import git as git_attribution
from garage_rag.attribute import resolver
from garage_rag.attribute.pathrules import EXCLUDED_PREFIXES
from garage_rag.db.models import CorpusClass, TrustTier
from garage_rag.extract import dispatch, quality
from garage_rag.extract.base import ContentKind, ExtractionError, ExtractResult, NoTextFound
from garage_rag.extract.contact_names import ContactNames
from garage_rag.extract.placeholder import PlaceholderFile
from garage_rag.ingest import chunking, classify, materialize, pipeline, splitters, walker
from garage_rag.ingest.gateway import ExistingDocStat, GrpcIngestStorageGateway, SourceContext
from garage_rag.proto import garage_pb2
from garage_rag.service import server as service
from garage_rag.service.client import GarageClient

REPO = Path(__file__).resolve().parents[2]
CORPUS = Path(__file__).parent / "corpora" / "second-brain-os"
_NAME = {"darwin": "libgarage_ingest_ffi.dylib", "win32": "garage_ingest_ffi.dll"}.get(
    sys.platform, "libgarage_ingest_ffi.so"
)


def _library() -> Path | None:
    if value := os.environ.get("GARAGE_INGEST_FFI_LIBRARY"):
        return Path(value)
    for profile in ("release", "debug"):
        candidate = REPO / "rust" / "target" / profile / _NAME
        if candidate.exists():
            return candidate
    return None


LIBRARY = _library()
pytestmark = pytest.mark.skipif(
    LIBRARY is None, reason="libgarage_ingest_ffi is not built (cargo build -p garage-ingest-ffi)"
)


@pytest.fixture(scope="module")
def rust():
    assert LIBRARY is not None
    lib = ctypes.CDLL(str(LIBRARY))
    for name in (
        "garage_ingest_policy",
        "garage_ingest_walk",
        "garage_ingest_root_problem",
        "garage_ingest_assess",
        "garage_ingest_chunk",
        "garage_ingest_ensure_local",
        "garage_ingest_attribute",
        "garage_ingest_git_history",
        "garage_ingest_ingest_one",
    ):
        getattr(lib, name).argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
        getattr(lib, name).restype = ctypes.c_int32
    lib.garage_ingest_string_free.argtypes = [ctypes.c_void_p]
    lib.garage_ingest_string_free.restype = None

    def call(name: str, request: dict) -> dict:
        result = ctypes.c_void_p()
        status = getattr(lib, name)(json.dumps(request).encode(), ctypes.byref(result))
        try:
            reply = json.loads(ctypes.string_at(result.value).decode())
        finally:
            lib.garage_ingest_string_free(result)
        assert status == 0, reply
        return reply

    return call


# --- the rules ----------------------------------------------------------------------------------


def test_the_default_rules_are_pythons(rust):
    policy = rust("garage_ingest_policy", {})
    assert set(policy["exclude_dirs"]) == set(config.DEFAULT_EXCLUDE_DIRS)
    assert tuple(policy["dependency_path_fragments"]) == config.DEPENDENCY_PATH_FRAGMENTS
    assert tuple(policy["diagnostic_dir_patterns"]) == config.DIAGNOSTIC_DIR_PATTERNS
    assert tuple(policy["diagnostic_file_patterns"]) == config.DIAGNOSTIC_FILE_PATTERNS
    assert set(policy["indexable_extensions"]) == set(dispatch.INDEXABLE_EXTENSIONS)
    assert set(policy["named_code_files"]) == set(dispatch.NAMED_CODE_FILES)
    assert set(policy["code_extensions"]) == set(dispatch.CODE_EXTENSIONS)
    assert set(policy["doc_extensions"]) == set(classify._DOC_EXTENSIONS_IN_CODE_TREES)
    assert set(policy["doc_stems"]) == set(classify._DOC_STEMS)
    assert policy["max_file_bytes"] == config.Settings().max_file_bytes


# --- the walker ---------------------------------------------------------------------------------

LIMIT = 4096


def _python_walk(monkeypatch, root: Path, **kwargs) -> tuple[list[tuple], dict]:
    monkeypatch.setattr(walker, "get_settings", lambda: SimpleNamespace(max_file_bytes=LIMIT))
    stats = walker.WalkStats()
    found = [(str(c.path), c.size, c.mtime, c.placeholder) for c in walker.walk(root, stats=stats, **kwargs)]
    return sorted(found), dataclasses.asdict(stats)


def _rust_walk(rust, root: Path, **kwargs) -> tuple[list[tuple], dict]:
    reply = rust("garage_ingest_walk", {"root": str(root), "policy": {"max_file_bytes": LIMIT}, **kwargs})
    found = [
        (c["path"], c["size"], datetime.fromtimestamp(c["mtime"], tz=UTC), c["placeholder"])
        for c in reply["candidates"]
    ]
    for path, _, _, _ in found:
        # The exact st_mtime, before datetime's rounding to microseconds.
        assert next(c["mtime"] for c in reply["candidates"] if c["path"] == path) == os.stat(path).st_mtime
    return sorted(found), reply["stats"]


def _assert_same_walk(monkeypatch, rust, root: Path, *, include_code=False, exclude_prefixes=()):
    python = _python_walk(monkeypatch, root, include_code=include_code, exclude_prefixes=tuple(exclude_prefixes))
    port = _rust_walk(rust, root, include_code=include_code, exclude_prefixes=list(exclude_prefixes))
    assert port == python
    return python


def _write(path: Path, size: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"x" * size)


def _named_tree(root: Path) -> None:
    files = {
        "notes/plan.md": 10,
        "notes/Plan.MD": 11,
        "notes/empty.md": 0,
        "notes/huge.txt": LIMIT + 1,
        "notes/edge.txt": LIMIT,
        "notes/.hidden.md": 5,
        "notes/foo.": 5,
        "notes/..x": 5,
        "notes/photo.raw": 5,
        "notes/ps.txt": 5,
        "notes/disk.sha256sum": 5,
        "notes/Makefile": 5,
        "notes/Dockerfile.txt": 5,
        "notes/README": 5,
        "notes/LICENSE.py": 5,
        "notes/security.rb": 5,
        "notes/design.cfg": 5,
        "notes/café 日記.md": 7,
        "src/main.py": 9,
        "src/lib.rs": 9,
        "src/README.md": 9,
        "node_modules/pkg/readme.md": 5,
        "Contents/Info.md": 5,
        ".config/settings.md": 5,
        "sysdiagnose_2026/report.txt": 5,
        "Logs/today.md": 5,
        "x.logarchive/a.md": 5,
        "mirror.git/HEAD": 5,
        "mirror.git/objects/a.md": 5,
        "mirror.git/refs/b.md": 5,
        "home/go/pkg/mod/github.com/m/doc.md": 5,
        "Library/Caches/app/doc.md": 5,
        "Library/notes.md": 5,
        "Objects/blob.md": 5,
        "deep/a/b/c/d/e.md": 5,
    }
    for relative, size in files.items():
        _write(root / relative, size)
    (root / "links").mkdir()
    (root / "links" / "to-file.md").symlink_to(root / "notes" / "plan.md")
    (root / "links" / "to-dir").symlink_to(root / "notes", target_is_directory=True)
    (root / "links" / "broken.md").symlink_to(root / "nowhere.md")
    os.mkfifo(root / "notes" / "pipe.md")
    locked = root / "locked"
    _write(locked / "secret.md", 5)
    locked.chmod(0)


@pytest.mark.skipif(sys.platform == "win32", reason="symlinks and fifos")
@pytest.mark.parametrize("include_code", [False, True])
@pytest.mark.parametrize("exclude_prefixes", [(), ("Library/", "Objects/"), ("notes/",)])
def test_a_tree_of_every_rule_walks_the_same(monkeypatch, rust, tmp_path, include_code, exclude_prefixes):
    root = tmp_path / "source"
    _named_tree(root)
    try:
        found, stats = _assert_same_walk(
            monkeypatch, rust, root, include_code=include_code, exclude_prefixes=exclude_prefixes
        )
    finally:
        (root / "locked").chmod(0o755)
    assert stats["yielded"] == len(found) > 0


def test_a_random_tree_walks_the_same(monkeypatch, rust, tmp_path):
    pieces = [
        *config.DEFAULT_EXCLUDE_DIRS,
        "logs",
        "Diagnostics",
        "spindump_1",
        "a.dSYM",
        ".cargo",
        "registry",
        "go",
        "pkg",
        "mod",
        "Library",
        "Caches",
        "notes",
        "Docs",
        "été",
        "objects",
        "refs",
    ]
    extensions = [*sorted(dispatch.INDEXABLE_EXTENSIONS)[::3], ".raw", ".bin", "", ".TXT", ".Md", ".hash.txt", "."]
    stems = ["readme", "LICENSE", "notes", "HEAD", "Makefile", "ps", "pmset_1", "apticket", "x", "日記"]
    for seed in range(4):
        rng = random.Random(seed)
        root = tmp_path / f"random-{seed}"
        root.mkdir()
        for _ in range(250):
            depth = rng.randint(0, 4)
            parts = [rng.choice(pieces) for _ in range(depth)]
            name = rng.choice(stems) + rng.choice(extensions)
            if rng.random() < 0.05:
                name = "." + name
            size = rng.choice([0, 1, 100, LIMIT, LIMIT + 1])
            target = root.joinpath(*parts, name)
            if target.exists() and target.is_dir():
                continue
            try:
                _write(target, size)
            except (IsADirectoryError, NotADirectoryError, FileExistsError):
                continue
        for include_code in (False, True):
            _assert_same_walk(monkeypatch, rust, root, include_code=include_code)
            _assert_same_walk(monkeypatch, rust, root, include_code=include_code, exclude_prefixes=("notes/", "go/"))


def test_a_root_inside_git_walks_nothing(monkeypatch, rust, tmp_path):
    _write(tmp_path / "repo" / ".git" / "info" / "notes.md", 5)
    root = tmp_path / "repo" / ".git" / "info"
    assert list(walker.walk(root)) == []
    reply = rust("garage_ingest_walk", {"root": str(root)})
    assert reply["walked"] is False
    assert reply["candidates"] == []


def test_the_home_folder_is_expanded(monkeypatch, rust, tmp_path):
    monkeypatch.setenv("HOME", str(tmp_path))
    _write(tmp_path / "Documents" / "a.md", 5)
    reply = rust("garage_ingest_walk", {"root": "~/Documents"})
    assert reply["root"] == str(config.expand_home("~/Documents"))
    assert [c["path"] for c in reply["candidates"]] == [str(tmp_path / "Documents" / "a.md")]


def test_dropbox_roots_skip_dropboxs_folders(rust, tmp_path):
    dropbox = tmp_path / "Dropbox"
    dropbox.mkdir()
    marked = tmp_path / "Elsewhere"
    marked.mkdir()
    (marked / ".dropbox.device").write_text("")
    plain = tmp_path / "Plain"
    plain.mkdir()
    for root in (dropbox, marked, plain):
        reply = rust("garage_ingest_walk", {"root": str(root), "exclude_prefixes": "default"})
        assert tuple(reply["exclude_prefixes"]) == walker.default_exclude_prefixes(root)
    assert walker.default_exclude_prefixes(dropbox) == EXCLUDED_PREFIXES


def test_root_problems_read_the_same(rust, tmp_path):
    a_file = tmp_path / "file.md"
    a_file.write_text("x")
    through_a_file = a_file / "below"
    for root in (tmp_path, a_file, tmp_path / "missing", through_a_file):
        assert rust("garage_ingest_root_problem", {"root": str(root)})["problem"] == walker.root_problem(root)


# --- the quality gate ---------------------------------------------------------------------------


def _texts() -> list[tuple[str, str]]:
    rng = random.Random(7)
    texts: list[tuple[str, str]] = []
    for path in sorted(CORPUS.rglob("*")):
        if path.is_file() and path.suffix in {".md", ".txt", ".py", ".sh", ".json", ".yaml", ".yml"}:
            texts.append((str(path.relative_to(CORPUS)), path.read_text(encoding="utf-8", errors="replace")))

    def lines(make, count=80):
        return "\n".join(make(i) for i in range(count))

    texts += [
        ("empty", ""),
        ("blank", "\n \n\t\n\x1c\n"),
        ("iso log", lines(lambda i: f"2026-07-27 11:{i % 60:02}:00 kernel[0]: event {i} happened")),
        ("syslog", lines(lambda i: f"Dec 24 04:09:{i % 60:02} host app[{i}]: did a thing")),
        ("time log", lines(lambda i: f"11:30:{i % 60:02}.{i:03} worker started job")),
        ("kernel log", lines(lambda i: f"[{i}.{i * 7 % 1000:03}] usb 1-1: new device")),
        ("epoch log", lines(lambda i: f"{1_700_000_000_000 + i} GET /index.html 200")),
        ("manifest", lines(lambda i: f"{rng.getrandbits(256):064x}  file{i}.bin", 12)),
        ("long manifest", lines(lambda i: f"{rng.getrandbits(256):064x}  file{i}.bin")),
        ("base64", lines(lambda i: "".join(rng.choices(string.ascii_letters + string.digits + "+/", k=76)), 60)),
        ("short base64", lines(lambda i: "".join(rng.choices(string.ascii_letters + "+/", k=60)) + "==", 5)),
        ("ioreg", lines(lambda i: f"  | +-o Device{i} <class IOService, id 0x{i:08x}, registered>")),
        ("braces", lines(lambda i: "{" if i % 2 else "}")),
        ("csv", lines(lambda i: f"{i},{i * 3},{i * 7},{i % 5}")),
        ("table of contents", lines(lambda i: f"Chapter {i}: The Chapter About Things ........ page {i * 3}")),
        ("one long line", "".join(rng.choices(string.hexdigits, k=300_000))),
        ("long lines then prose", "x" * 70_000 + "\n" + lines(lambda i: f"Sentence {i} about a garden.")),
        ("hindi", lines(lambda i: "कार्य सूची के लिए नोट्स " * 3)),
        ("russian", lines(lambda i: f"Заметка {i}: мы гуляли по парку")),
        ("chinese", lines(lambda i: f"第{i}天，我们在花园里读书。")),
        ("digits of other scripts", lines(lambda i: f"٣٤:٥٦:٧٨.{i} ١٢")),
        ("separators", lines(lambda i: f"field\x1c{i}\x1dvalue\x1e\x1f end")),
        ("crlf", lines(lambda i: f"2026-01-02 10:{i % 60:02} line\r")),
    ]
    for n in range(40):
        kinds = [
            lambda: " ".join(
                rng.choice(["the", "garden", "we", "walked", "Ada", "wrote", "letters"]) for _ in range(12)
            ),
            lambda: f"2026-0{rng.randint(1, 9)}-1{rng.randint(0, 9)} 0{rng.randint(0, 9)}:1{rng.randint(0, 9)} msg",
            lambda: f"{rng.getrandbits(128):032x}",
            lambda: f"  +-o Node <class X, id 0x{rng.getrandbits(32):08x}>",
            lambda: "".join(rng.choices(string.printable, k=rng.randint(1, 120))),
        ]
        weights = [rng.random() for _ in kinds]
        texts.append((f"mixed {n}", "\n".join(rng.choices(kinds, weights)[0]() for _ in range(rng.randint(5, 200)))))
    return texts


TEXTS = _texts()


@pytest.mark.parametrize("sample", [quality.SAMPLE_BYTES, 500])
@pytest.mark.parametrize(("name", "text"), TEXTS, ids=[name for name, _ in TEXTS])
def test_every_text_is_judged_the_same(rust, name, text, sample):
    python = quality.assess(text, sample_bytes=sample)
    port = rust("garage_ingest_assess", {"text": text, "sample_chars": sample})
    assert port["machine_generated"] == python.machine_generated
    assert port["reasons"] == python.reasons
    assert port["reason_text"] == python.reason_text
    assert port["metrics"] == python.metrics
    assert list(port["metrics"]) == list(python.metrics)


def test_the_corpus_has_both_verdicts():
    verdicts = {quality.assess(text).machine_generated for _, text in TEXTS}
    assert verdicts == {True, False}


# --- chunking -----------------------------------------------------------------------------------


def _golden_cases() -> list[tuple[str, str, ContentKind, str, int, int]]:
    """The chunking golden test's cases, which pin Python to langchain's output."""
    spec = importlib.util.spec_from_file_location("_chunking_golden", Path(__file__).parent / "test_chunking_golden.py")
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.CASES


def _sample_code(language: str, rng: random.Random) -> str:
    keywords = [s.strip() for s in splitters.LANGUAGE_SEPARATORS[language] if s.strip()]
    words = ["alpha", "beta(x)", "{", "}", "return", "=", "1;", "\\", "{x}", "$", "$$", "|", "::", "é", "日本"]
    lines = []
    for _ in range(rng.randint(10, 120)):
        indent = rng.choice(["", "  ", "    ", "\t"])
        head = rng.choice(keywords + words)
        lines.append(indent + head + " " + " ".join(rng.choices(words, k=rng.randint(0, 12))))
        if rng.random() < 0.2:
            lines.append("")
    return rng.choice(["\n", "\r\n"]).join(lines) + rng.choice(["", "\n", "\n\n"])


def _sample_markdown(rng: random.Random) -> str:
    lines = []
    for _ in range(rng.randint(5, 150)):
        kind = rng.random()
        if kind < 0.15:
            lines.append(rng.choice(["#", "##", "###", "####", "#No"]) + rng.choice(["", " Title", "  Spaced  ", " é"]))
        elif kind < 0.22:
            lines.append(rng.choice(["```", "```python", "~~~", "``` ```", "  ```"]))
        elif kind < 0.3:
            lines.append("")
        elif kind < 0.35:
            lines.append(rng.choice(["\t\tindented code", "a​b c\x07d", "   ", " "]))
        else:
            lines.append(
                " ".join(
                    rng.choices(
                        ["word", "Sentence.", "comma,", "why?", "yes!", "日本語", "x" * 40], k=rng.randint(1, 30)
                    )
                )
            )
    return "\n".join(lines)


def _chunk_cases() -> list[tuple[str, str, str, str, int, int]]:
    cases = [(name, text, kind.value, ext, size, overlap) for name, text, kind, ext, size, overlap in _golden_cases()]
    rng = random.Random(11)
    sizes = [(50, 0), (120, 30), (400, 80), (1000, 100)]
    for extension, language in sorted(chunking._CODE_LANGUAGES.items()):
        for n in range(2):
            size, overlap = rng.choice(sizes)
            cases.append((f"{extension} {n}", _sample_code(language, rng), "code", extension, size, overlap))
    for extension in (".pl", ".txt", ""):
        cases.append((f"untabled {extension}", _sample_code("python", rng), "code", extension, 120, 30))
    for n in range(30):
        size, overlap = rng.choice(sizes)
        cases.append((f"markdown {n}", _sample_markdown(rng), "markdown", "", size, overlap))
        cases.append((f"prose {n}", _sample_markdown(rng), "prose", "", size, overlap))
        cases.append((f"tabular {n}", _sample_markdown(rng).replace("# ", "## "), "tabular", "", size, overlap))
    cases += [
        ("unclosed fence", "# A\nintro\n```\ncode\n\n## B\nmore", "markdown", "", 50, 10),
        ("conversation", "Ada: hello\nGrace: hi\n" * 40, "conversation", "", 100, 20),
        ("image", "A photo of a garden", "image", "", 100, 20),
        ("image empty", "", "image", "", 100, 20),
        ("corpus readme", (CORPUS / "README.md").read_text(encoding="utf-8"), "markdown", "", 1000, 100),
    ]
    return cases


CHUNK_CASES = _chunk_cases()


@pytest.mark.parametrize(
    ("name", "text", "kind", "ext", "size", "overlap"), CHUNK_CASES, ids=[c[0] for c in CHUNK_CASES]
)
def test_every_text_is_chunked_the_same(rust, name, text, kind, ext, size, overlap):
    python = [
        dataclasses.asdict(chunk)
        for chunk in chunking.chunk_text(text, ContentKind(kind), extension=ext, size=size, overlap=overlap)
    ]
    port = rust("garage_ingest_chunk", {"text": text, "kind": kind, "extension": ext, "size": size, "overlap": overlap})
    assert port["chunks"] == python


# --- materializing placeholders -----------------------------------------------------------------

BUDGET_FIELDS = (
    "enabled",
    "max_files",
    "max_bytes",
    "timeout_seconds",
    "files_done",
    "bytes_done",
    "deferred",
    "failed",
)


def _python_ensure_local(path: Path, budget: materialize.MaterializationBudget) -> str:
    try:
        materialize.ensure_local(path, budget)
    except PlaceholderFile:
        return "deferred" if budget.deferred else "failed"
    return "local"


@pytest.mark.parametrize(
    ("name", "budget"),
    [
        ("off", {}),
        ("on", {"enabled": True, "timeout_seconds": 5.0}),
        ("spent files", {"enabled": True, "max_files": 2, "files_done": 2}),
        ("spent bytes", {"enabled": True, "max_bytes": 10, "bytes_done": 11, "deferred": 4}),
        ("room left", {"enabled": True, "max_files": 5, "files_done": 1, "bytes_done": 123, "failed": 2}),
    ],
)
@pytest.mark.parametrize("file", ["note.md", ".note.md.icloud", "empty.md", "missing.md"])
def test_placeholders_are_materialized_the_same(rust, tmp_path, name, budget, file):
    path = tmp_path / file
    if file != "missing.md":
        path.write_bytes(b"" if file == "empty.md" else b"text that is local")
    python = materialize.MaterializationBudget(**budget)
    python_outcome = _python_ensure_local(path, python)

    port = rust("garage_ingest_ensure_local", {"path": str(path), "budget": budget})

    assert port["outcome"] == python_outcome
    assert {key: port["budget"][key] for key in BUDGET_FIELDS} == dataclasses.asdict(python)
    assert port["budget"]["exhausted"] == python.exhausted
    assert port["budget"]["summary"] == python.summary()


@pytest.mark.parametrize(
    "counts", [(0, 0, 0, 0), (1, 5, 0, 0), (1234, 1 << 29, 3, 1), (10**7, 3 * 1024**3 + 12345, 1000, 999)]
)
def test_budget_summaries_read_the_same(rust, tmp_path, counts):
    files, size, deferred, failed = counts
    budget = {"files_done": files, "bytes_done": size, "deferred": deferred, "failed": failed}
    port = rust("garage_ingest_ensure_local", {"path": str(tmp_path / "missing"), "budget": budget})
    assert port["budget"]["summary"] == materialize.MaterializationBudget(**budget).summary()


# --- attribution --------------------------------------------------------------------------------

OWNER = {"name": "Ada Lovelace", "identities": ["git_email:Ada@Example.com", "git_name:ada-l"]}


def _owner() -> resolver.SelfIdentity:
    pairs = [tuple(part.strip() for part in raw.split(":", 1)) for raw in OWNER["identities"]]
    return resolver.SelfIdentity(OWNER["name"], pairs)


def _python_attribution(path: Path, root: Path, *, trust="authored", hints=(), communication=False) -> dict:
    decided = resolver.resolve(
        path,
        root,
        source_default_trust=TrustTier(trust),
        author_hints=list(hints),
        self_identity=_owner(),
        communication=communication,
    )
    return {
        "trust": str(decided.trust),
        "authors": [
            {
                "name": author.name,
                "email": author.email,
                "role": str(author.role),
                "confidence": author.confidence,
                "evidence": author.evidence,
            }
            for author in decided.authors
        ],
        "evidence": decided.evidence,
        "meta": decided.meta,
    }


def _rust_attribution(
    rust, path: Path, root: Path, *, trust="authored", hints=(), communication=False, repos=None, read_git=False
):
    request = {
        "read_git": read_git,
        "path": str(path),
        "source_root": str(root),
        "default_trust": trust,
        "author_hints": list(hints),
        "communication": communication,
        "self": OWNER,
        "repos": repos or {},
    }
    return rust("garage_ingest_attribute", request)


PATHS = [
    "Reference/a.pdf",
    "Reference/deep/b.pdf",
    "Documents/Paper/Reference/c.pdf",
    "Documents/Paper/draft.md",
    "Documents/Research/r.md",
    "Documents/Reference/x.txt",
    "x/Army Field Manuals/fm.pdf",
    "a/b/Documentation/d.md",
    "Datasheets/top.pdf",
    "lab/Datasheets/chip.pdf",
    "lib/Manuals/m.pdf",
    "Books/b.epub",
    "shelf/Books/b.epub",
    "Papers/p.pdf",
    "x/Specs/s.md",
    "x/RFCs/rfc1.txt",
    "Personal/diary.md",
    "Projects/engine/main.py",
    "Projects/engine/node_modules/left-pad/index.js",
    "Projects/engine/vendor/lib.c",
    "Notes/today.md",
    "Notes/sub/deeper.md",
    "misc/references/r.md",
    "misc/PAPERS/r.md",
    "misc/Book/r.md",
    "misc/r.md",
    "r.md",
    "Library/site-packages/x.py",
    "Personal/Reference/mine.md",
]


@pytest.mark.parametrize("trust", ["authored", "reference", "received"])
@pytest.mark.parametrize("relative", PATHS)
def test_paths_are_attributed_the_same(rust, tmp_path, relative, trust):
    path = tmp_path / relative
    assert _rust_attribution(rust, path, tmp_path, trust=trust) == _python_attribution(path, tmp_path, trust=trust)


def test_a_path_outside_the_root_is_judged_by_its_name(rust, tmp_path):
    root = tmp_path / "root"
    for path in (tmp_path / "Reference" / "x.pdf", tmp_path / "elsewhere" / "Notes" / "n.md", Path("/")):
        assert _rust_attribution(rust, path, root) == _python_attribution(path, root)


HINTS = [
    ["Grace Hopper"],
    ["Ada Lovelace"],
    ["ada lovelace", "Grace Hopper"],
    ["ADA-L"],
    ["One", "Two", "Three", "Four", "Five", "Six", "Seven"],
]


@pytest.mark.parametrize("hints", HINTS)
@pytest.mark.parametrize("relative", ["Reference/p.pdf", "Notes/n.md", "misc/m.md"])
def test_metadata_is_weighed_the_same(rust, tmp_path, hints, relative):
    path = tmp_path / relative
    assert _rust_attribution(rust, path, tmp_path, hints=hints) == _python_attribution(path, tmp_path, hints=hints)


SENDERS = [
    "Ada Lovelace <ada@example.com>",
    "ADA@EXAMPLE.COM",
    "Grace Hopper <grace@navy.mil>",
    '"Hopper, Grace" <grace@navy.mil>',
    "grace@navy.mil (Grace Hopper)",
    "Grace (Admiral) <grace@navy.mil>",
    "Grace <grace@navy.mil>, Bob <bob@x>",
    "Mr. Bob <bob@x>",
    "  Bob  <  bob@x  >  ",
    "Bob <bob@x",
    '"unterminated <bob@x>',
    "bob@x@y",
    "Bob <>",
    "<>",
    "",
    "Zoë Ångström <zoe@example.org>",
    "=?utf-8?q?Ad=C3=A1?= <a@x>",
    "group: a@x, b@y;",
    "Bob <bob@[127.0.0.1]>",
    "Bob ((nested)) <bob@x>",
    "Bob (unbalanced <bob@x>",
    'Bob \\"quoted\\" <bob@x>',
    "bob . smith @ example . com",
    "<@route,@r2:bob@x>",
    "Bob <bob@x> trailing",
    "ada at example",
]


@pytest.mark.parametrize("sender", SENDERS)
def test_senders_are_read_the_same(rust, tmp_path, sender):
    path = tmp_path / "Mail" / "1.eml"
    hints = [sender, "Second <second@x>"] if sender.startswith("Bob") else [sender]
    port = _rust_attribution(rust, path, tmp_path, hints=hints, communication=True)
    assert port == _python_attribution(path, tmp_path, hints=hints, communication=True)


def test_random_senders_are_read_the_same(rust, tmp_path):
    rng = random.Random(1815)
    alphabet = 'ab .@<>(),:;"\\[]\t'
    path = tmp_path / "1.eml"
    for _ in range(3000):
        sender = "".join(rng.choice(alphabet) for _ in range(rng.randint(0, 14)))
        port = _rust_attribution(rust, path, tmp_path, hints=[sender], communication=True)
        assert port == _python_attribution(path, tmp_path, hints=[sender], communication=True), repr(sender)


REMOTES = [
    "https://github.com/grace/engine.git",
    "ssh://git@github.com:22/grace/engine",
    "git@github.com:grace/engine.git",
    "github.com/grace/engine",
    "engine",
    "file:///srv/git/engine.git",
    "https://host/",
    None,
]


@pytest.mark.parametrize("remote", REMOTES)
@pytest.mark.parametrize(
    "tallies",
    [
        [("Grace", "grace@navy.mil", 3)],
        [("Grace", "grace@navy.mil", 15), ("Ada", "ada@example.com", 1)],
        [("Bob", "b@x", 2), ("Ada", "", 2), ("Al", "al@x", 2)] + [(f"P{n}", f"p{n}@x", 1) for n in range(8)],
        [("ada-l", "other@x", 1), ("Grace", "grace@navy.mil", 2)],
        [("Zed", "z@x", 1), ("Amy", "a@x", 1)],
    ],
)
def test_git_history_is_weighed_the_same(rust, tmp_path, monkeypatch, remote, tallies):
    repo = tmp_path / "engine"
    (repo / ".git").mkdir(parents=True)
    (repo / "src").mkdir()
    tracked = repo / "src" / "main.rs"
    tracked.write_text("fn main() {}")
    history = git_attribution.RepoAttribution(root=repo, remote=remote)
    history.by_path = {
        "src/main.rs": {
            (name, email.lower()): git_attribution.AuthorTally(name=name, email=email, commits=commits)
            for name, email, commits in tallies
        }
    }
    monkeypatch.setattr(resolver, "cached_repo_attribution", lambda root, max_commits=None: history)
    repos = {str(repo): {"remote": remote, "by_path": {"src/main.rs": [list(t) for t in tallies]}}}

    for path in (tracked, repo / "src" / "untracked.rs", repo / "Reference" / "x.pdf"):
        port = _rust_attribution(rust, path, tmp_path, repos=repos)
        assert port == _python_attribution(path, tmp_path), path


def _git(root: Path, *args: str, author: tuple[str, str] | None = None, when: int = 0) -> None:
    env = {
        **os.environ,
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_COMMITTER_NAME": "Committer",
        "GIT_COMMITTER_EMAIL": "committer@example.com",
    }
    if author is not None:
        stamp = f"{1_700_000_000 + when * 60} +0000"
        env |= {
            "GIT_AUTHOR_NAME": author[0],
            "GIT_AUTHOR_EMAIL": author[1],
            "GIT_AUTHOR_DATE": stamp,
            "GIT_COMMITTER_DATE": stamp,
        }
    subprocess.run(["git", *args], cwd=root, check=True, env=env, capture_output=True)


def test_history_read_in_rust_attributes_the_same(rust, tmp_path, monkeypatch):
    """The whole of git attribution in Rust, libgit2 reads included, against Python's."""
    if shutil.which("git") is None or git_attribution.git_reader() is None:
        pytest.skip("needs git, and _garage_git or pygit2 for Python's side")
    monkeypatch.delenv("GIT_CONFIG_COUNT", raising=False)
    git_attribution.cached_repo_attribution.cache_clear()
    repo = tmp_path / "engine"
    repo.mkdir()
    _git(repo, "init", "-q", "-b", "main")
    people = [
        ("Ada Lovelace", "ada@example.com"),
        ("Ada Lovelace", "ADA@example.com"),
        ("Grace Hopper", "grace@navy.mil"),
        ("ada-l", "other@x"),
        ("Bob", "b@x"),
    ]
    files = ["src/main.rs", "src/lib.rs", "docs/guide.md", "Reference/spec.pdf", "vendor/dep.c", "café.md"]
    shuffle = random.Random(7)
    for when in range(40):
        for name in shuffle.sample(files, shuffle.randint(1, 3)):
            target = repo / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(f"{name} {when}\n")
        _git(repo, "add", "-A")
        _git(repo, "commit", "-q", "-m", f"change {when}", author=shuffle.choice(people), when=when)
    (repo / ".mailmap").write_text("Ada Lovelace <ada@example.com> <ADA@example.com>\n")
    _git(repo, "add", "-A")
    _git(repo, "commit", "-q", "-m", "mailmap", author=people[2], when=41)
    _git(repo, "remote", "add", "origin", "https://github.com/someone/engine.git")

    reader = git_attribution.git_reader()
    assert reader is not None
    commits = rust("garage_ingest_git_history", {"root": str(repo)})["commits"]
    assert [tuple(commit) for commit in commits] == [
        (name, email, paths) for name, email, paths in reader.commit_paths(repo)
    ], "the same commits in the same order"
    for path in [*(repo / name for name in files), repo / ".mailmap", repo / "src" / "untracked.rs"]:
        port = _rust_attribution(rust, path, tmp_path, read_git=True)
        assert port == _python_attribution(path, tmp_path), path


# --- one file through the ingest loop -----------------------------------------------------------


class _RecordingGateway:
    """The facade calls ``ingest_one`` makes, written down as the Rust port reports them."""

    def __init__(self, existing: dict | None) -> None:
        self.existing = ExistingDocStat(**existing) if existing else ExistingDocStat(exists=False)
        self.calls: list[dict] = []

    def check_stat(self, slug, uri):
        return self.existing

    def record_seen(self, run_id, slug, uri):
        self.calls.append({"method": "record_seen", "uri": uri})

    def record_placeholder(self, run_id, slug, uri, mtime, title, reason):
        self.calls.append(
            {"method": "record_placeholder", "uri": uri, "mtime": mtime, "title": title, "reason": reason}
        )

    def record_no_text(self, run_id, slug, uri, *, byte_size, mtime, source_sha256):
        self.calls.append(
            {
                "method": "record_no_text",
                "uri": uri,
                "byte_size": byte_size,
                "mtime": mtime,
                "source_sha256": source_sha256,
            }
        )

    def record_extract_failed(self, run_id, slug, uri, error, *, byte_size, mtime, source_sha256):
        self.calls.append(
            {
                "method": "record_extract_failed",
                "uri": uri,
                "error": error,
                "byte_size": byte_size,
                "mtime": mtime,
                "source_sha256": source_sha256,
            }
        )

    def record_rejected(self, run_id, slug, uri):
        self.calls.append({"method": "record_rejected", "uri": uri})

    def refresh_metadata(self, run_id, slug, uri, byte_size, mtime, source_sha256, corpus_class, trust_tier):
        self.calls.append(
            {
                "method": "refresh_metadata",
                "uri": uri,
                "byte_size": byte_size,
                "mtime": mtime,
                "source_sha256": source_sha256,
                "corpus_class": corpus_class,
                "trust_tier": trust_tier,
            }
        )

    def replace_document(self, *, run_id, source_slug, authors, chunks, **document):
        call = {"method": "replace_document", **document}
        call["authors"] = [dataclasses.asdict(author) for author in authors]
        call["chunks"] = [
            {key: value for key, value in dataclasses.asdict(chunk).items() if key not in ("direction", "sender")}
            for chunk in chunks
        ]
        # As stored: JSON, so a tuple in meta reads back as a list.
        self.calls.append(json.loads(json.dumps(call)))
        return len(chunks)


_KIND = {kind.value: kind for kind in ContentKind}
MTIME = 1_700_000_000.25
TEXT_HASH = "ab" * 32


def _document(text: str, kind: str = "markdown", **extra) -> dict:
    return {"document": {"text": text, "kind": kind, "extractor": "test", "extractor_version": "3", **extra}}


def _python_read(read: dict | None, path: Path):
    def extract(_path):
        if read is None:
            raise AssertionError("the file was read")
        if "document" in read:
            document = read["document"]
            return ExtractResult(
                text=document["text"],
                kind=_KIND[document["kind"]],
                extractor=document["extractor"],
                extractor_version=document["extractor_version"],
                title=document.get("title"),
                lang=document.get("lang"),
                meta=dict(document.get("meta", {})),
                author_hints=list(document.get("author_hints", [])),
            )
        if "no_text" in read:
            raise NoTextFound(read["no_text"])
        if read.get("placeholder"):
            raise PlaceholderFile(path)
        raise ExtractionError(read["failed"])

    return extract


def _ingest_both(rust, monkeypatch, tmp_path, case: dict, *, gateway=None, facade=None) -> tuple[dict, dict]:
    """``case`` through both ports; with ``gateway`` and ``facade``, both persist through GarageService."""
    root = tmp_path / "src"
    path = root / case.get("relative", "Notes/note.md")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("x")
    settings = config.Settings().model_copy(update=case.get("settings", {}))
    local = case.get("local", True)
    raw = case.get("source_sha256", TEXT_HASH)
    contacts = case.get("contact_names")

    def ensure_local(_path, _budget):
        if not local:
            raise PlaceholderFile(_path)

    def file_sha256(_path):
        if raw is None:
            raise OSError("unreadable")
        return bytes.fromhex(raw)

    monkeypatch.setattr(pipeline, "ensure_local", ensure_local)
    monkeypatch.setattr(pipeline, "file_sha256", file_sha256)
    monkeypatch.setattr(pipeline, "extract", _python_read(case.get("read"), path))
    monkeypatch.setattr(pipeline, "get_settings", lambda: settings)
    monkeypatch.setattr(chunking, "get_settings", lambda: settings)

    source = SourceContext(
        source_id=1,
        slug="src",
        root=root,
        default_class=CorpusClass(case.get("default_class", "document")),
        default_trust=TrustTier(case.get("default_trust", "authored")),
        run_id=1,
    )
    candidate = walker.Candidate(
        path=path,
        size=case.get("size", 1234),
        mtime=datetime.fromtimestamp(case.get("mtime", MTIME), UTC),
        placeholder=case.get("placeholder", False),
    )
    gateway = gateway or _RecordingGateway(case.get("existing"))
    counters = pipeline.IngestCounters()
    names = None
    if contacts is not None:
        names = ContactNames([tuple(entry) for entry in contacts.get("names", [])])
        if "fallback" in contacts:
            names = names.with_fallback([tuple(entry) for entry in contacts["fallback"]])
    pipeline.ingest_one(
        gateway,
        source,
        candidate,
        self_identity=_owner(),
        budget=materialize.MaterializationBudget(),
        counters=counters,
        force=case.get("force", False),
        contact_names=names,
    )
    python = {
        "calls": getattr(gateway, "calls", []),
        "counters": {
            name: getattr(counters, name)
            for name in ("seen", "indexed", "skipped", "failed", "placeholders", "rejected", "chunks_written", "errors")
        },
    }

    request = {
        "existing": case.get("existing"),
        "candidate": {
            "path": str(path),
            "uri": candidate.uri,
            "size": candidate.size,
            "mtime": candidate.mtime.timestamp(),
            "placeholder": candidate.placeholder,
        },
        "local": local,
        "source_sha256": raw,
        "read": case.get("read"),
        "settings": {
            name: getattr(settings, name)
            for name in (
                "reject_machine_generated",
                "index_images",
                "max_chunks_per_document",
                "chunk_size",
                "chunk_overlap",
                "code_chunk_size",
                "code_chunk_overlap",
            )
        },
        "source": {
            "root": str(root),
            "default_class": source.default_class.value,
            "default_trust": source.default_trust.value,
        },
        "self": OWNER,
        "contact_names": contacts,
        "repos": {},
        "force": case.get("force", False),
    }
    if facade is not None:
        request["facade"] = facade
    reply = rust("garage_ingest_ingest_one", request)
    reply.setdefault("calls", [])
    return python, reply


_PROSE = "# Notes\n\n" + "\n\n".join(f"Paragraph {n} says something about the garage." * 6 for n in range(12))
_CODE = (REPO / "garage_python" / "src" / "garage_rag" / "ingest" / "classify.py").read_text()
_LOG = "\n".join(f"2024-01-01T00:00:{n % 60:02d}Z INFO worker[{n}] request handled in {n}ms" for n in range(400))
_SETTLED = {"exists": True, "byte_size": 1234, "mtime": MTIME, "state": "OK", "content_sha256": "c" * 64}

INGEST_CASES = {
    "new markdown": {"read": _document(_PROSE, title="Notes", lang="en", meta={"front_matter": {"tags": ["a"]}})},
    "new code": {"relative": "Projects/engine/main.py", "read": _document(_CODE, "code")},
    "a readme stays a document": {"relative": "Projects/engine/README.py", "read": _document("x = 1\n", "code")},
    "a security.rb is code": {"relative": "Projects/engine/security.rb", "read": _document("x = 1\n", "code")},
    "a reference pdf": {
        "relative": "Reference/paper.pdf",
        "read": _document(_PROSE, "prose", author_hints=["Grace Hopper"]),
    },
    "the owner's hint": {"read": _document(_PROSE, author_hints=["Ada Lovelace", "Bob Smith"])},
    "machine output": {"relative": "Notes/run.txt", "read": _document(_LOG, "prose")},
    "machine output allowed": {
        "relative": "Notes/run.txt",
        "read": _document(_LOG, "prose"),
        "settings": {"reject_machine_generated": False},
    },
    "no chunks": {"read": _document("", "prose")},
    "too many chunks": {
        "read": _document(_PROSE, "prose"),
        "settings": {"max_chunks_per_document": 2, "chunk_size": 200},
    },
    "a screenshot": {"relative": "Pictures/shot.png", "read": _document("Error: disk full", "prose")},
    "a screenshot, images off": {
        "relative": "Pictures/shot.png",
        "read": _document("Error: disk full", "prose"),
        "settings": {"index_images": False},
    },
    "a photo": {"relative": "Pictures/cat.jpg", "read": _document("cat", "image", title="cat")},
    "a mail": {
        "relative": "Mail/hello.eml",
        "default_class": "communication",
        "read": _document(
            "From: grace@navy.mil\n\nHello there, about the compiler.", "conversation", author_hints=["grace@navy.mil"]
        ),
        "contact_names": {"names": [["Grace@Navy.mil", "Grace  Hopper"]]},
    },
    "a mail, fallback name": {
        "relative": "Mail/hello.eml",
        "read": _document("Hello there.", "conversation", author_hints=["+1 (555) 123-4567"]),
        "contact_names": {"names": [["x@y", "X"]], "fallback": [["5551234567", "Shared Name"]]},
    },
    "no text": {"read": {"no_text": "empty"}},
    "a placeholder read": {"read": {"placeholder": True}},
    "a failed read": {"read": {"failed": "broken PDF"}},
    "a failed read, unreadable bytes": {"read": {"failed": "broken"}, "source_sha256": None},
    "not materialized": {"local": False, "placeholder": True},
    "unchanged stat": {"existing": _SETTLED},
    "unchanged stat, forced": {"existing": _SETTLED, "force": True, "read": _document(_PROSE)},
    "unchanged stat of a placeholder with no size": {
        "existing": _SETTLED,
        "placeholder": True,
        "size": 0,
    },
    "changed mtime": {"existing": {**_SETTLED, "mtime": MTIME + 5}, "read": _document(_PROSE)},
    "unchanged bytes": {"existing": {**_SETTLED, "mtime": MTIME + 5, "source_sha256": TEXT_HASH}},
    "unchanged bytes, no text": {
        "existing": {
            **_SETTLED,
            "mtime": MTIME + 5,
            "source_sha256": TEXT_HASH,
            "state": "NO_TEXT",
            "content_sha256": "",
        }
    },
    "unchanged bytes, failed": {
        "existing": {
            **_SETTLED,
            "mtime": MTIME + 5,
            "source_sha256": TEXT_HASH,
            "state": "FAILED",
            "content_sha256": "",
        }
    },
    "an extract failure is retried": {
        "existing": {**_SETTLED, "state": "EXTRACT_FAILED", "content_sha256": ""},
        "read": _document(_PROSE),
    },
    "an old placeholder row with content": {"existing": {**_SETTLED, "state": "PLACEHOLDER"}},
    "an eml indexed as text": {
        "relative": "Mail/old.eml",
        "existing": {**_SETTLED, "chunker": "prose:recursive"},
        "read": _document("Hello.", "conversation"),
    },
    "an eml indexed as mail": {"relative": "Mail/old.eml", "existing": {**_SETTLED, "chunker": "conversation:x"}},
}


@pytest.mark.parametrize("case", INGEST_CASES.values(), ids=INGEST_CASES.keys())
def test_files_are_ingested_the_same(rust, monkeypatch, tmp_path, case):
    python, port = _ingest_both(rust, monkeypatch, tmp_path, case)
    assert port == python


@pytest.mark.parametrize("name", ["new markdown", "new code", "a mail", "a screenshot", "too many chunks"])
def test_unchanged_text_keeps_its_chunks_the_same(rust, monkeypatch, tmp_path, name):
    """Step 4: a changed file whose text and chunker are unchanged refreshes its metadata only."""
    case = INGEST_CASES[name]
    first, _ = _ingest_both(rust, monkeypatch, tmp_path / "first", case)
    written = first["calls"][-1]
    assert written["method"] == "replace_document"
    existing = {
        "exists": True,
        "byte_size": 1,
        "mtime": MTIME - 100,
        "state": "OK",
        "content_sha256": written["content_sha256"],
        "chunker": written["chunker"],
        "source_sha256": "0" * 64,
    }
    python, port = _ingest_both(rust, monkeypatch, tmp_path / "again", {**case, "existing": existing})
    assert python["calls"][0]["method"] == "refresh_metadata"
    assert port == python


# --- the same file, persisted through GarageService ---------------------------------------------


class _Facade:
    """GarageService's two per-file calls, written down by source, answering with ``existing``."""

    def __init__(self) -> None:
        self.existing: dict | None = None
        self.requests: dict[str, list[dict]] = {}
        self.tokens: set[str | None] = set()

    def _record(self, request, context) -> None:
        self.tokens.add(dict(context.invocation_metadata()).get("x-garage-token"))
        call = type(request)()
        call.CopyFrom(request)
        slug = call.source_slug
        call.source_slug = ""
        if isinstance(call, garage_pb2.PersistDocumentRequest):
            call.run_id = 0
            if call.meta_json:
                # The two serializers space JSON differently; what is stored is the parsed object.
                call.meta_json = json.dumps(json.loads(call.meta_json), sort_keys=True)
        self.requests.setdefault(slug, []).append(call)

    def CheckDocumentStat(self, request, context):
        self._record(request, context)
        return garage_pb2.CheckDocumentStatResponse(**(self.existing or {"exists": False}))

    def PersistDocument(self, request, context):
        self._record(request, context)
        return garage_pb2.PersistDocumentResponse(success=True, chunks_written=len(request.chunks))


@pytest.fixture
def facade(monkeypatch, tmp_path):
    """GarageService on a Unix socket, its per-file calls answered by a :class:`_Facade`."""
    recorder = _Facade()
    for name in ("CheckDocumentStat", "PersistDocument"):
        monkeypatch.setattr(service.GarageRpcServicer, name, lambda self, r, c, _n=name: getattr(recorder, _n)(r, c))
    monkeypatch.setenv("GARAGE_GRPC_TOKEN", "launch-token")
    socket = tmp_path / "grpc.sock"
    server, _ = service.create_grpc_server(socket_path=str(socket))
    server.start()
    client = GarageClient(socket_path=str(socket), in_process=False)
    yield recorder, socket, client
    server.stop(0)


@pytest.mark.skipif(sys.platform == "win32", reason="the facade's socket is a Unix-domain socket")
@pytest.mark.parametrize("case", INGEST_CASES.values(), ids=INGEST_CASES.keys())
def test_files_are_persisted_the_same_over_the_facade(rust, monkeypatch, tmp_path, facade, case):
    """``GrpcStorage`` sends GarageService what ``GrpcIngestStorageGateway`` sends, call for call."""
    recorder, socket, client = facade
    recorder.existing = case.get("existing")
    python, port = _ingest_both(
        rust,
        monkeypatch,
        tmp_path / "corpus",
        case,
        gateway=GrpcIngestStorageGateway(client),
        facade={"socket": str(socket), "token": "launch-token", "run_id": 2, "source_slug": "rust"},
    )
    assert "error" not in port
    assert port["counters"] == python["counters"]
    assert recorder.requests["rust"] == recorder.requests["src"]
    assert isinstance(recorder.requests["src"][0], garage_pb2.CheckDocumentStatRequest)
    assert recorder.tokens == {"launch-token"}


def test_an_unreachable_facade_is_reported(tmp_path):
    """A facade that cannot be reached fails the request, naming where it looked."""
    request = {
        "candidate": {"path": str(tmp_path / "note.md")},
        "source": {"root": str(tmp_path)},
        "facade": {"socket": str(tmp_path / "absent.sock"), "run_id": 1, "source_slug": "src"},
    }
    result = ctypes.c_void_p()
    library = ctypes.CDLL(str(LIBRARY))
    library.garage_ingest_ingest_one.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
    status = library.garage_ingest_ingest_one(json.dumps(request).encode(), ctypes.byref(result))
    reply = json.loads(ctypes.string_at(result.value).decode())
    library.garage_ingest_string_free.argtypes = [ctypes.c_void_p]
    library.garage_ingest_string_free(result)
    assert status == 1
    assert "absent.sock" in reply["error"]
