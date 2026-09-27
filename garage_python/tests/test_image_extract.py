"""The local OCR pass in garage_rag.extract.image: gating and word filtering."""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

import pytest
from PIL import Image

from garage_rag.config import Settings, reset_settings, set_settings
from garage_rag.extract import image as image_extract
from garage_rag.extract import tesseract
from garage_rag.extract.base import ContentKind, ExtractionError, NoTextFound


def _write(tmp_path: Path, name: str, size: tuple[int, int] = (400, 300)) -> Path:
    path = tmp_path / name
    Image.new("RGB", size, "white").save(path)
    return path


def test_joins_readable_words_and_averages_their_confidence(monkeypatch, tmp_path):
    words = [
        tesseract.Word("Hello", 90.0),
        tesseract.Word("  ", 50.0),
        tesseract.Word("?", -1.0),
        tesseract.Word("world", 80.0),
    ]
    monkeypatch.setattr(tesseract, "recognize", lambda image: words)

    text, confidence, size = image_extract._tesseract(_write(tmp_path, "shot.png"))

    assert text == "Hello world"
    assert confidence == pytest.approx(85.0)
    assert size == (400, 300)


def test_nothing_readable_is_zero_confidence(monkeypatch, tmp_path):
    monkeypatch.setattr(tesseract, "recognize", lambda image: [])
    assert image_extract._tesseract(_write(tmp_path, "blank.png")) == ("", 0.0, (400, 300))


def test_icons_are_rejected_before_ocr(monkeypatch, tmp_path):
    def fail(image):
        raise AssertionError("OCR must not run on an icon")

    monkeypatch.setattr(tesseract, "recognize", fail)
    with pytest.raises(NoTextFound, match="too small"):
        image_extract._tesseract(_write(tmp_path, "icon.png", (64, 64)))


def test_library_failures_become_extraction_errors(monkeypatch, tmp_path):
    def unavailable(image):
        raise tesseract.TesseractUnavailable("libtesseract not found")

    monkeypatch.setattr(tesseract, "recognize", unavailable)
    with pytest.raises(ExtractionError, match="libtesseract not found"):
        image_extract._tesseract(_write(tmp_path, "shot.png"))


def test_an_image_without_text_is_a_picture_document(monkeypatch, tmp_path):
    """The picture gets one image chunk (for image embedding models) whose text is its name."""
    monkeypatch.setattr(tesseract, "recognize", lambda image: [])
    result = image_extract.extract_image(_write(tmp_path, "kitchen-remodel_03.png"))
    assert result.kind is ContentKind.IMAGE
    assert result.extractor == "image"
    assert result.text == "kitchen remodel 03"
    assert result.title == "kitchen-remodel_03"
    assert result.meta == {"image": {"width": 400, "height": 300}}


def test_an_image_without_text_is_no_text_when_pictures_are_not_indexed(monkeypatch, tmp_path):
    monkeypatch.setattr(tesseract, "recognize", lambda image: [])
    set_settings(Settings(index_images=False))
    try:
        with pytest.raises(NoTextFound, match="no usable text"):
            image_extract.extract_image(_write(tmp_path, "photo.png"))
    finally:
        reset_settings()


def test_a_screenshot_with_text_keeps_the_ocr_result(monkeypatch, tmp_path):
    words = [tesseract.Word(word, 90.0) for word in ["meeting", "notes", "for", "the", "quarterly", "review"]]
    monkeypatch.setattr(tesseract, "recognize", lambda image: words)
    result = image_extract.extract_image(_write(tmp_path, "shot.png"))
    assert result.kind is ContentKind.PROSE
    assert result.extractor == "tesseract"
    assert result.text == "meeting notes for the quarterly review"
    assert result.meta["image"] == {"width": 400, "height": 300}


@pytest.mark.parametrize(
    ("name", "words"),
    [("IMG_4021.HEIC", "IMG 4021"), ("kitchen-remodel.03.jpg", "kitchen remodel 03"), ("___.png", "___")],
)
def test_picture_text_is_the_name_as_words(name: str, words: str) -> None:
    assert image_extract.picture_text(Path(name)) == words


def test_library_failures_are_not_mistaken_for_no_text(monkeypatch, tmp_path):
    def unavailable(image):
        raise tesseract.TesseractUnavailable("libtesseract not found")

    monkeypatch.setattr(tesseract, "recognize", unavailable)
    with pytest.raises(ExtractionError) as info:
        image_extract.extract_image(_write(tmp_path, "shot.png"))
    assert not isinstance(info.value, NoTextFound)


def test_heic_is_decoded_by_imageio_not_pillow(monkeypatch, tmp_path):
    from garage_rag.extract import imageio

    path = tmp_path / "IMG_0001.HEIC"
    path.write_bytes(b"\x00\x00\x00\x18ftypheic")
    decoded = Image.new("RGB", (400, 300), "white")
    calls = []

    def open_image(p, *, max_pixels):
        calls.append((p, max_pixels))
        return decoded

    monkeypatch.setattr(imageio, "open_image", open_image)
    monkeypatch.setattr(tesseract, "recognize", lambda image: [tesseract.Word("receipt", 90.0)])

    assert image_extract._tesseract(path) == ("receipt", 90.0, (400, 300))
    assert calls == [(path, image_extract.MAX_OCR_PIXELS)]


@pytest.mark.skipif(sys.platform == "darwin", reason="ImageIO is present on macOS")
def test_heic_off_macos_is_an_extraction_error(tmp_path):
    path = tmp_path / "IMG_0001.heic"
    path.write_bytes(b"\x00\x00\x00\x18ftypheic")
    with pytest.raises(ExtractionError, match="macOS ImageIO"):
        image_extract._open_image(path)


@pytest.mark.skipif(sys.platform != "darwin", reason="needs macOS ImageIO")
def test_imageio_decodes_upright_rgb_over_white(tmp_path):
    from garage_rag.extract import imageio

    path = tmp_path / "half.png"
    source = Image.new("RGBA", (40, 20), (0, 0, 0, 0))
    source.paste((255, 0, 0, 255), (0, 0, 40, 10))  # red top half, transparent bottom
    source.save(path)

    decoded = imageio.open_image(path, max_pixels=10_000)

    assert decoded.mode == "RGB"
    assert decoded.size == (40, 20)
    assert decoded.getpixel((20, 2)) == (255, 0, 0)
    assert decoded.getpixel((20, 17)) == (255, 255, 255)


@pytest.mark.skipif(sys.platform != "darwin", reason="needs macOS ImageIO")
def test_imageio_refuses_oversized_images_from_the_header(tmp_path):
    from garage_rag.extract import imageio

    path = _write(tmp_path, "big.png", (400, 300))
    with pytest.raises(ExtractionError, match="too large"):
        imageio.open_image(path, max_pixels=1000)


@pytest.mark.skipif(sys.platform != "darwin" or shutil.which("sips") is None, reason="needs macOS sips and ImageIO")
def test_imageio_reads_a_real_heic(tmp_path):

    png = _write(tmp_path, "shot.png", (400, 300))
    heic = tmp_path / "shot.heic"
    converted = subprocess.run(
        ["sips", "-s", "format", "heic", str(png), "--out", str(heic)], capture_output=True, check=False
    )
    if converted.returncode != 0 or not heic.is_file():
        pytest.skip(f"this Mac cannot encode HEIC: {converted.stderr.decode(errors='replace')}")

    decoded = image_extract._open_image(heic)

    assert decoded.size == (400, 300)
    assert all(channel > 240 for channel in decoded.getpixel((200, 150)))
