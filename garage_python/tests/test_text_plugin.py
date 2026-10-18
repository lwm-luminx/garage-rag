"""The Rust text reader (``rust/garage-text``) against the Python one it replaces.

``garage_rag.extract.text`` is the specification. Every file in the corpus below goes through the
Python extractors (as ``dispatch.extract`` would run them) and through the Rust reader by both of
its transports: the ``garage-text-plugin`` process over gRPC, and ``libgarage_text_ffi`` in-process
over its C ABI. The results must be identical: the same text, so the same content hash, chunks and
vectors.

The Rust builds are found through ``GARAGE_TEXT_PLUGIN`` and ``GARAGE_TEXT_FFI_LIBRARY``, or in
``rust/target/{release,debug}``; a test whose build is missing skips (``cargo build --release`` in
``rust/`` makes both).
"""

from __future__ import annotations

import ctypes
import json
import math
import os
import random
import sys
from pathlib import Path

import pytest

from garage_rag.extract import dispatch, plugins
from garage_rag.extract.base import ContentKind, ExtractionError, NoTextFound
from garage_rag.extract.text import extract_code, extract_markdown, extract_plaintext
from garage_rag.proto import garage_plugin_pb2 as pb

REPO = Path(__file__).resolve().parents[2]
CORPUS = Path(__file__).parent / "corpora" / "second-brain-os"

_PYTHON = {"markdown": extract_markdown, "plaintext": extract_plaintext, "code": extract_code}


def _built(variable: str, name: str) -> Path | None:
    if value := os.environ.get(variable):
        return Path(value)
    for profile in ("release", "debug"):
        candidate = REPO / "rust" / "target" / profile / name
        if candidate.exists():
            return candidate
    return None


PLUGIN = _built("GARAGE_TEXT_PLUGIN", "garage-text-plugin")
FFI = _built(
    "GARAGE_TEXT_FFI_LIBRARY",
    {"darwin": "libgarage_text_ffi.dylib", "win32": "garage_text_ffi.dll"}.get(sys.platform, "libgarage_text_ffi.so"),
)


# --- the corpus ---------------------------------------------------------------------------------

FRONT_MATTER = [
    "---\ntitle: A Note\nauthor: Ada Lovelace\n---\n# Heading\nBody.\n",
    "---\ntitle: '  padded  '\nauthors: [Grace Hopper, '', 0, 7, yes, ~, 1.5, 1e3]\n---\nBody\n",
    "---\ntitle: 42\ndraft: no\nflag: On\ncount: 0x1F\nmode: 0755\ntime: 1:30\nratio: .5\nbig: 1_000\n---\nB\n",
    "---\ndate: 2024-01-02\nupdated: 2024-1-2 10:00:00Z\nby: [2024-01-02]\ncreator: Someone\n---\nBody text\n",
    "---\ntags:\n  - a\n  - b\nnested: {x: 1}\nempty:\nnull_value: null\n---\nBody\n",
    "---\nanchor: &a Ada\ncopy: *a\nauthor: *a\n---\nBody\n",
    "---\ntitle: First\ntitle: Second\n1: one\n1.0: float one\ntrue: bool one\n---\nBody\n",
    "---\r\ntitle: CRLF\r\n...\r\nBody\r\nmore\r\n",
    "---\n---\nEmpty front matter is not front matter\n",
    "---\njust a string\n---\nBody\n",
    "---\n- a list\n---\nBody\n",
    "---\ntitle: [unclosed\n---\nBody survives\n",
    "--- \ntitle: trailing space on the fence\n---\nBody\n",
    "----\ntitle: four dashes\n---\nBody\n",
    "---\ntitle: never closed\nBody\n",
    "---\ntitle: \"quoted: yes\"\nauthor: 'single'\n---\n# H\n",
    "---\ntitle: !!str 123\nauthor: ! 456\n---\n# H\n",
    "---\ntitle: |\n  literal\n  block\n---\nBody\n",
    "---\ntitle: >\n  folded\n  block\n---\nBody\n",
    "---\nnan: .nan\ninf: -.inf\nfloat: 1.e+5\nseconds: 1:30.5\n---\nBody\n",
    "---\n# only a comment\n---\nBody\n",
    "---\ntitle: First\nby: 2\ntitle: |\n  the last block\n  scalar\n---\nBody\n",
    '---\ntitle: ! 7\nauthor: ! "8"\ncreator: ! words\n---\nBody\n',
    "---\ntitle: has a \x00 NUL\n---\nBody\n",
    "---\nauthor: [Ada, 2024-02-29, -0, 0o7, 1_0, 3.]\n---\nBody\n",
]

TEXT = [
    "",
    " \n\t\n",
    "plain words",
    "line one\r\nline two\rline three\n",
    "a\n\n\n\n\n\nb\n\n\n",
    "trailing spaces   \nand tabs\t\t\nend",
    "nul\x00byte",
    "é decomposed, Å, 가",
    " non-breaking edges \n　ideographic　",
    "\x1cfile separator is Python whitespace\x1f",
    "# Heading after\nsome lines\n# Second",
    "intro\n" * 45 + "# Too late a heading\n",
    "ab\n" * 12 + "a title too late\n",
    "x" * 250 + "\nshort but valid line\n",
    " line separator paragraph separator\x85next line",
    "﻿ mark mid-text ﻿",
]

BINARY = [
    b"\xef\xbb\xbf---\ntitle: BOM\n---\nBody",
    b"\xff\xfeH\x00i\x00 \x00t\x00h\x00e\x00r\x00e\x00",
    b"\xfe\xff\x00H\x00i",
    b"\xff\xfeodd",
    b"caf\xe9 \x93quoted\x94 \x80uro",
    b"undefined \x81 byte \x93",
    b"\xed\xa0\x80 surrogate in utf-8",
    b"\x00\x00\x00",
    b"\r\n\r\n",
]


def _corpus(tmp_path: Path) -> list[Path]:
    paths: list[Path] = []

    def add(name: str, content: bytes) -> None:
        path = tmp_path / f"{len(paths):03d}" / name
        path.parent.mkdir()
        path.write_bytes(content)
        paths.append(path)

    for source in FRONT_MATTER:
        add("note.md", source.encode())
    for name in ("note.md", "notes.txt", "main.py", "Makefile", ".bashrc.txt", "x.tar.MD", "Dockerfile"):
        for text in TEXT:
            add(name, text.encode())
        for blob in BINARY:
            add(name, blob)

    # A seeded fuzz over the characters the readers treat specially.
    alphabet = ["-", "-", "-", "\n", "\r", " ", "\t", "#", ":", "a", "title", "author", "é", "́", "\x00", "'", "["]
    rng = random.Random(1557)
    for index in range(200):
        text = "".join(rng.choice(alphabet) for _ in range(rng.randint(0, 60)))
        add(("f.md", "f.txt", "f.rs")[index % 3], text.encode())

    for path in sorted(CORPUS.rglob("*")):
        if path.is_file() and dispatch.is_indexable(path):
            paths.append(path)
    return paths


# --- the two readers ------------------------------------------------------------------------------


def _python(path: Path) -> tuple:
    """What the Python reader makes of ``path``, as ``dispatch.extract`` would report it."""
    name = dispatch._EXTRACTOR_MODULES[dispatch.extractor_for(path)][0]
    if path.stat().st_size == 0:
        return ("no_text",)
    try:
        result = _PYTHON[name](path)
    except NoTextFound:
        return ("no_text",)
    if result.is_empty:
        return ("no_text",)
    # Through JSON, as the metadata is stored. The one intended difference: front matter's
    # non-finite floats (.nan, .inf) have no JSON form, and the Rust reader drops them.
    meta = json.loads(json.dumps(result.meta))
    if isinstance(meta.get("frontmatter"), dict):
        meta["frontmatter"] = {
            k: v for k, v in meta["frontmatter"].items() if not (isinstance(v, float) and not math.isfinite(v))
        }
    return (
        "document",
        result.text,
        result.kind,
        result.extractor,
        result.extractor_version,
        result.title,
        meta,
        result.author_hints,
    )


def _rust(response: pb.ExtractResponse, path: Path) -> tuple:
    try:
        result = plugins.to_extract_result("garage-text", response, path)
    except NoTextFound:
        return ("no_text",)
    except ExtractionError as exc:
        return ("failure", str(exc))
    meta = dict(result.meta)
    assert meta.pop("plugin") == "garage-text"
    return (
        "document",
        result.text,
        result.kind,
        result.extractor,
        result.extractor_version,
        result.title,
        meta,
        result.author_hints,
    )


class _GarageBuffer(ctypes.Structure):
    _fields_ = [("data", ctypes.POINTER(ctypes.c_uint8)), ("len", ctypes.c_size_t)]


class _Ffi:
    def __init__(self, path: Path) -> None:
        self.lib = ctypes.CDLL(str(path))
        for name in ("garage_text_describe", "garage_text_extract"):
            function = getattr(self.lib, name)
            function.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.POINTER(_GarageBuffer)]
            function.restype = ctypes.c_int32
        self.lib.garage_text_buffer_free.argtypes = [_GarageBuffer]
        self.lib.garage_text_contract_version.restype = ctypes.c_uint32

    def call(self, name: str, request: bytes) -> tuple[int, bytes]:
        out = _GarageBuffer()
        status = getattr(self.lib, name)(request, len(request), ctypes.byref(out))
        data = ctypes.string_at(out.data, out.len) if out.len else b""
        self.lib.garage_text_buffer_free(out)
        return status, data


# --- the tests ------------------------------------------------------------------------------------


@pytest.fixture(scope="module")
def plugin_registry():
    if PLUGIN is None or not PLUGIN.exists():
        pytest.skip("garage-text-plugin is not built (cargo build --release in rust/)")
    registry = plugins.PluginRegistry((str(PLUGIN),))
    registry.start()
    yield registry
    registry.close()


@pytest.fixture(scope="module")
def ffi():
    if FFI is None or not FFI.exists():
        pytest.skip("libgarage_text_ffi is not built (cargo build --release in rust/)")
    return _Ffi(FFI)


def test_describes_the_same_routing_as_dispatch(plugin_registry):
    """The plugin claims exactly the files the Python reader's three extractors take."""
    extractors = {e.name: e for p in plugin_registry._plugins for e in p.extractors}
    assert set(extractors) == {"markdown", "plaintext", "code"}
    assert extractors["markdown"].extensions == dispatch.MARKDOWN_EXTENSIONS
    assert extractors["plaintext"].extensions == dispatch.PLAINTEXT_EXTENSIONS
    assert extractors["code"].extensions == dispatch.CODE_EXTENSIONS
    assert extractors["code"].file_names == dispatch.NAMED_CODE_FILES
    assert {e.version for e in extractors.values()} == {"1"}


def test_the_grpc_plugin_reads_every_file_as_python_does(plugin_registry, tmp_path):
    corpus = _corpus(tmp_path)
    assert len(corpus) > 500
    for path in corpus:
        client, extractor = plugin_registry.route(path)
        request = pb.ExtractRequest(extractor=extractor.name, file_name=path.name, content=path.read_bytes())
        response = client._stub.Extract(request)
        assert _rust(response, path) == _python(path), path.read_bytes()[:200]


def test_the_c_abi_reads_every_file_as_python_does(ffi, tmp_path):
    assert ffi.lib.garage_text_contract_version() == pb.CONTRACT_VERSION_1
    for path in _corpus(tmp_path):
        # No extractor named: the library routes by file name, as dispatch does.
        request = pb.ExtractRequest(file_name=path.name, content=path.read_bytes())
        status, data = ffi.call("garage_text_extract", request.SerializeToString())
        assert status == 0, data
        response = pb.ExtractResponse.FromString(data)
        assert _rust(response, path) == _python(path), path.read_bytes()[:200]


def test_the_c_abi_reports_bad_requests(ffi):
    status, data = ffi.call("garage_text_extract", b"\xff\xff\xff")
    assert status == 1
    assert data.startswith(b"request does not decode")
    status, data = ffi.call("garage_text_describe", b"")
    assert status == 0
    assert pb.DescribeResponse.FromString(data).name == "garage-text"


def test_dispatch_uses_the_plugin_when_configured(tmp_path):
    if PLUGIN is None or not PLUGIN.exists():
        pytest.skip("garage-text-plugin is not built (cargo build --release in rust/)")
    from garage_rag.config import Settings, reset_settings, set_settings

    note = tmp_path / "n.md"
    note.write_text("---\ntitle: Configured\n---\nBody\n")
    set_settings(Settings(extraction_plugins=[str(PLUGIN)]))
    try:
        result = dispatch.extract(note)
        assert (result.title, result.text, result.kind) == ("Configured", "Body", ContentKind.MARKDOWN)
        assert result.meta["plugin"] == "garage-text"
        assert dispatch.extractor_revision(note) == "markdown:1"
    finally:
        plugins.close()
        reset_settings()
