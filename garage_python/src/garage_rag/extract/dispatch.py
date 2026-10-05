"""Extension -> extractor routing.

Extractors are imported lazily. A corpus walk touches tens of thousands of files
but usually only a handful of types, and importing pdfplumber/openpyxl/libtesseract
up front for a run that never meets a PDF or a spreadsheet is pure startup cost.
"""

from __future__ import annotations

import importlib
import logging
from collections.abc import Callable
from pathlib import Path

from garage_rag.config import get_settings
from garage_rag.extract.base import ContentKind, ExtractionError, ExtractResult, NoTextFound, UnsupportedFile
from garage_rag.extract.placeholder import PlaceholderFile, check_materialized

log = logging.getLogger(__name__)

Extractor = Callable[[Path], ExtractResult]

MARKDOWN_EXTENSIONS = frozenset({".md", ".markdown", ".mdown", ".mkd", ".mdx", ".qmd", ".rmd"})

PLAINTEXT_EXTENSIONS = frozenset(
    {
        ".txt",
        ".text",
        ".rst",
        ".org",
        ".adoc",
        ".asciidoc",
        ".tex",
        ".srt",
        ".vtt",
    }
)

# RFC 822 messages, and Apple Mail's ``.emlx`` (a byte count, the message, then a plist).
EMAIL_EXTENSIONS = frozenset({".eml", ".emlx"})

# Binary containers that look like text formats by name. Outlook ``.msg`` is an
# OLE compound file, not RFC 822 text; reading it as plaintext yields mojibake.
UNSUPPORTED_BINARY_EXTENSIONS = frozenset({".msg"})

CODE_EXTENSIONS = frozenset(
    {
        ".py",
        ".pyi",
        ".js",
        ".jsx",
        ".mjs",
        ".cjs",
        ".ts",
        ".tsx",
        ".c",
        ".h",
        ".cc",
        ".cpp",
        ".cxx",
        ".hpp",
        ".hh",
        ".m",
        ".mm",
        ".swift",
        ".java",
        ".kt",
        ".kts",
        ".scala",
        ".go",
        ".rs",
        ".rb",
        ".php",
        ".pl",
        ".pm",
        ".lua",
        ".sh",
        ".bash",
        ".zsh",
        ".fish",
        ".ps1",
        ".sql",
        ".r",
        ".jl",
        ".hs",
        ".ml",
        ".ex",
        ".exs",
        ".erl",
        ".cs",
        ".fs",
        ".vb",
        ".dart",
        ".zig",
        ".nim",
        ".html",
        ".htm",
        ".xml",
        ".svg",
        ".css",
        ".scss",
        ".sass",
        ".less",
        ".vue",
        ".svelte",
        ".proto",
        ".graphql",
        ".gql",
        ".tf",
        ".hcl",
        ".dockerfile",
        ".makefile",
        ".cmake",
        ".gradle",
        ".s",
        ".asm",
        ".v",
        ".sv",
        ".vhd",
        # Structured configuration and data. Grouped with code because that is
        # what it is: package manifests, CI workflows, k8s specs, lockfiles.
        # As documents these were 63% of the corpus and pure retrieval noise.
        ".json",
        ".jsonl",
        ".ndjson",
        ".yaml",
        ".yml",
        ".toml",
        ".ini",
        ".cfg",
        ".conf",
        ".properties",
        ".csv",
        ".tsv",
    }
)

IMAGE_EXTENSIONS = frozenset(
    {".png", ".jpg", ".jpeg", ".tiff", ".tif", ".bmp", ".gif", ".webp", ".heic", ".heif", ".hif", ".avif"}
)

PDF_EXTENSIONS = frozenset({".pdf"})
DOCX_EXTENSIONS = frozenset({".docx", ".docm"})
PPTX_EXTENSIONS = frozenset({".pptx", ".pptm"})
XLSX_EXTENSIONS = frozenset({".xlsx", ".xlsm"})

# Legacy binary Office formats. Recognized so they can be reported honestly
# rather than being silently treated as unknown; reading them needs LibreOffice.
LEGACY_OFFICE_EXTENSIONS = frozenset({".doc", ".ppt", ".xls", ".rtf", ".pages", ".key", ".numbers"})

# Filenames without a useful extension that are still worth indexing.
NAMED_CODE_FILES = frozenset(
    {
        "makefile",
        "dockerfile",
        "rakefile",
        "gemfile",
        "podfile",
        "brewfile",
        "justfile",
        "vagrantfile",
    }
)

ALL_TEXT_EXTENSIONS = (
    MARKDOWN_EXTENSIONS
    | PLAINTEXT_EXTENSIONS
    | EMAIL_EXTENSIONS
    | CODE_EXTENSIONS
    | PDF_EXTENSIONS
    | DOCX_EXTENSIONS
    | PPTX_EXTENSIONS
    | XLSX_EXTENSIONS
)

INDEXABLE_EXTENSIONS = ALL_TEXT_EXTENSIONS | IMAGE_EXTENSIONS


def _markdown(path: Path) -> ExtractResult:
    from garage_rag.extract.text import extract_markdown

    return extract_markdown(path)


def _plaintext(path: Path) -> ExtractResult:
    from garage_rag.extract.text import extract_plaintext

    return extract_plaintext(path)


def _email(path: Path) -> ExtractResult:
    from garage_rag.extract.mail import extract_email

    return extract_email(path)


def _code(path: Path) -> ExtractResult:
    from garage_rag.extract.text import extract_code

    return extract_code(path)


def _pdf(path: Path) -> ExtractResult:
    from garage_rag.extract.pdf import extract_pdf

    return extract_pdf(path)


def _docx(path: Path) -> ExtractResult:
    from garage_rag.extract.office import extract_docx

    return extract_docx(path)


def _pptx(path: Path) -> ExtractResult:
    from garage_rag.extract.office import extract_pptx

    return extract_pptx(path)


def _xlsx(path: Path) -> ExtractResult:
    from garage_rag.extract.office import extract_xlsx

    return extract_xlsx(path)


def _image(path: Path) -> ExtractResult:
    from garage_rag.extract.image import extract_image

    return extract_image(path)


def extractor_for(path: Path) -> Extractor:
    """Choose an extractor for ``path``, or raise :class:`UnsupportedFile`."""
    suffix = path.suffix.lower()
    name = path.name.lower()

    if suffix in MARKDOWN_EXTENSIONS:
        return _markdown
    if suffix in PDF_EXTENSIONS:
        return _pdf
    if suffix in DOCX_EXTENSIONS:
        return _docx
    if suffix in PPTX_EXTENSIONS:
        return _pptx
    if suffix in XLSX_EXTENSIONS:
        return _xlsx
    if suffix in IMAGE_EXTENSIONS:
        return _image
    if suffix in CODE_EXTENSIONS:
        return _code
    if suffix in PLAINTEXT_EXTENSIONS:
        return _plaintext
    if suffix in EMAIL_EXTENSIONS:
        return _email
    if not suffix and name in NAMED_CODE_FILES:
        return _code
    if suffix in LEGACY_OFFICE_EXTENSIONS:
        raise UnsupportedFile(f"legacy binary format {suffix} needs LibreOffice conversion: {path.name}")
    if suffix in UNSUPPORTED_BINARY_EXTENSIONS:
        raise UnsupportedFile(f"binary container {suffix} has no extractor: {path.name}")

    raise UnsupportedFile(f"no extractor for {suffix or name!r}")


# Each extractor's name, and the module whose VERSION it reports.
_EXTRACTOR_MODULES: dict[Extractor, tuple[str, str]] = {
    _markdown: ("markdown", "text"),
    _plaintext: ("plaintext", "text"),
    _code: ("code", "text"),
    _email: ("email", "mail"),
    _pdf: ("pdf", "pdf"),
    _docx: ("docx", "office"),
    _pptx: ("pptx", "office"),
    _xlsx: ("xlsx", "office"),
    _image: ("image", "image"),
}


def extractor_revision(path: Path) -> str:
    """The extractor for ``path`` and its version, such as ``"pdf:1"``; empty when there is none.

    A remembered no-text or failed outcome counts only while this is unchanged, so
    bumping an extractor's ``VERSION`` retries every file it gave up on.
    """
    try:
        extractor = extractor_for(path)
    except UnsupportedFile:
        return ""
    name, module_name = _EXTRACTOR_MODULES[extractor]
    module = importlib.import_module(f"garage_rag.extract.{module_name}")
    return f"{name}:{module.VERSION}"


def is_indexable(path: Path) -> bool:
    """Cheap pre-filter for the walker, before any file is opened."""
    suffix = path.suffix.lower()
    return suffix in INDEXABLE_EXTENSIONS or (not suffix and path.name.lower() in NAMED_CODE_FILES)


def extract(path: Path) -> ExtractResult:
    """Extract text from ``path``. Every extractor runs on this machine.

    Raises :class:`ExtractionError` (or :class:`UnsupportedFile`) rather than
    returning empty results, so the pipeline can record *why* a document failed.
    """
    settings = get_settings()

    try:
        size = path.stat().st_size
    except OSError as exc:
        raise ExtractionError(f"cannot stat {path}: {exc}") from exc

    # Must precede the empty-file check: a cloud stub is also zero bytes, but the
    # remedy is to download it, not to skip it as junk. Raises PlaceholderFile.
    check_materialized(path, size=size)

    if size == 0:
        raise NoTextFound(f"empty file: {path}")
    if size > settings.max_file_bytes:
        raise ExtractionError(f"file exceeds max_file_bytes ({size:,} > {settings.max_file_bytes:,}): {path}")

    extractor = extractor_for(path)
    result = extractor(path)
    if result.is_empty:
        raise NoTextFound(f"extractor {result.extractor} produced no text: {path}")
    return result


__all__ = [
    "ContentKind",
    "ExtractionError",
    "ExtractResult",
    "NoTextFound",
    "PlaceholderFile",
    "UnsupportedFile",
    "extract",
    "extractor_for",
    "extractor_revision",
    "is_indexable",
]
