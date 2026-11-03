"""The Rust ingest pieces (``rust/garage-ingest``) against the Python they replace.

``garage_rag.ingest.walker`` and ``garage_rag.extract.quality`` are the specification. Each tree
below is walked by both walkers, and each text judged by both gates, through
``libgarage_ingest_ffi``'s C ABI; the files found, the counts, the verdicts, the reasons and every
metric must be identical. The Rust walker's default rules are held to Python's tables too, so a
table edited on one side only fails here.

The library is found through ``GARAGE_INGEST_FFI_LIBRARY`` or in ``rust/target/{release,debug}``;
without it the tests skip (``cargo build -p garage-ingest-ffi`` in ``rust/`` makes it).
"""

from __future__ import annotations

import ctypes
import dataclasses
import json
import os
import random
import string
import sys
from datetime import UTC, datetime
from pathlib import Path
from types import SimpleNamespace

import pytest

from garage_rag import config
from garage_rag.attribute.pathrules import EXCLUDED_PREFIXES
from garage_rag.extract import dispatch, quality
from garage_rag.ingest import classify, walker

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
    for name in ("garage_ingest_policy", "garage_ingest_walk", "garage_ingest_root_problem", "garage_ingest_assess"):
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
