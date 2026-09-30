"""Image text extraction with Tesseract, on this machine.

Tesseract handles clean screenshots and scans well. It struggles with
low-contrast captures, dense UI, diagrams and handwriting; those images yield
little or no text, and there is no fallback -- no image is ever sent to a cloud
vision model.

An image that yields no usable text is indexed as a picture when
``ingest.index_images`` is on (the default): a document whose one chunk
(:data:`~garage_rag.ingest.chunking.IMAGE_CHUNKER`) an image embedding model
embeds from the file itself, and whose text is the file's name, for full-text
search. With it off, such an image raises :class:`NoTextFound`: not indexed as
an empty document, and not an error either -- most images simply hold no
text -- so the pipeline records it as rejected. Either way an image too small
to be a picture worth finding (an icon, a spacer) is rejected.

Note on the corpus: most images in a source tree are UI assets -- icons, arrows,
logos. Those have no recoverable text and should not consume OCR time at all, so
tiny images are rejected before Tesseract runs.

HEIC/HEIF (every iPhone photo and screenshot since iOS 11) is decoded by macOS
ImageIO (:mod:`garage_rag.extract.imageio`) rather than Pillow, which cannot read
it without libheif and its GPL/LGPL HEVC codecs.
"""

from __future__ import annotations

import logging
import re
from pathlib import Path

from garage_rag.config import get_settings
from garage_rag.extract.base import ContentKind, ExtractionError, ExtractResult, NoTextFound, normalize_text

log = logging.getLogger(__name__)

# 3: images without text become picture documents (ingest.index_images).
VERSION = "3"

# Below this, an image is an icon or a spacer, not a document. Screenshots and
# scans are comfortably larger in both dimensions.
MIN_OCR_WIDTH = 200
MIN_OCR_HEIGHT = 200
# Guard against decompression bombs and multi-hundred-megapixel scans.
MAX_OCR_PIXELS = 40_000_000

# HEVC-coded HEIF. AVIF (AV1 in the same container) Pillow reads itself.
IMAGEIO_SUFFIXES = frozenset({".heic", ".heif", ".hif"})


def _open_image(path: Path):
    if path.suffix.lower() in IMAGEIO_SUFFIXES:
        from garage_rag.extract import imageio

        return imageio.open_image(path, max_pixels=MAX_OCR_PIXELS)

    from PIL import Image

    try:
        image = Image.open(path)
        image.load()
    except Exception as exc:  # noqa: BLE001 - Pillow raises many types
        raise ExtractionError(f"unreadable image {path}: {exc}") from exc
    return image


def _tesseract(path: Path) -> tuple[str, float, tuple[int, int]]:
    """Run Tesseract, returning ``(text, mean_word_confidence, (width, height))``.

    Confidence comes from the per-word results rather than the plain text:
    "returned something" and "returned something legible" are different, and only
    the word data distinguishes them. Tesseract runs in-process through its C API
    (:mod:`garage_rag.extract.tesseract`); nothing is spawned.
    """
    from garage_rag.extract import tesseract

    image = _open_image(path)
    width, height = image.size
    if width * height > MAX_OCR_PIXELS:
        raise ExtractionError(f"image too large to OCR ({width}x{height}): {path}")
    if width < MIN_OCR_WIDTH or height < MIN_OCR_HEIGHT:
        raise NoTextFound(f"image too small to hold text ({width}x{height}): {path}")

    try:
        recognized = tesseract.recognize(image)
    except Exception as exc:  # noqa: BLE001
        raise ExtractionError(f"tesseract failed on {path}: {exc}") from exc

    words: list[str] = []
    confidences: list[float] = []
    for word in recognized:
        cleaned = word.text.strip()
        # A negative confidence marks a region Tesseract found but could not read.
        if not cleaned or word.confidence < 0:
            continue
        words.append(cleaned)
        confidences.append(word.confidence)

    text = " ".join(words)
    mean_conf = sum(confidences) / len(confidences) if confidences else 0.0
    return normalize_text(text), mean_conf, (width, height)


_NAME_SEPARATORS = re.compile(r"[_\-\.]+")


def picture_text(path: Path) -> str:
    """What a picture without text says in the index: its name, as words, so
    full-text search finds ``kitchen-remodel-03.heic`` by "kitchen remodel"."""
    return normalize_text(_NAME_SEPARATORS.sub(" ", path.stem)).strip() or path.stem


def extract_image(path: Path) -> ExtractResult:
    """Extract text from an image with Tesseract, or index it as a picture."""
    settings = get_settings()

    text, confidence, (width, height) = _tesseract(path)
    if len(text) < settings.ocr_min_chars:
        if not settings.index_images:
            # Not indexed as an empty document, and not an error: most images in a
            # code tree are icons and genuinely contain nothing.
            raise NoTextFound(f"no usable text in image (confidence {confidence:.0f}, {len(text)} chars): {path}")
        return ExtractResult(
            text=picture_text(path),
            kind=ContentKind.IMAGE,
            extractor="image",
            extractor_version=VERSION,
            title=path.stem,
            meta={"image": {"width": width, "height": height}},
        )

    return ExtractResult(
        text=text,
        kind=ContentKind.PROSE,
        extractor="tesseract",
        extractor_version=VERSION,
        title=path.stem,
        meta={
            "ocr_engine": "tesseract",
            "ocr_confidence": round(confidence, 2),
            "image": {"width": width, "height": height},
        },
    )
