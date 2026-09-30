"""garage_rag.extract.tesseract: finding libtesseract, and OCR through its C API.

The recognition tests need a real libtesseract and English language data. On macOS
Bazel supplies the ones the app bundles (//ext/tesseract): conftest.py loads the
library from GARAGE_TEST_LIBTESSERACT, as the app's framework does, and
GARAGE_TEST_TESSDATA_FILE names the data. Elsewhere they skip.
"""

from __future__ import annotations

import os
from pathlib import Path

import pytest
from PIL import Image, ImageDraw, ImageFont

from garage_rag.extract import tesseract


@pytest.fixture
def nothing_loaded(monkeypatch):
    monkeypatch.setattr(tesseract, "loaded_library", lambda name: None)
    monkeypatch.setattr(tesseract.ctypes.util, "find_library", lambda name: None)


def test_the_loaded_library_wins(monkeypatch, nothing_loaded):
    framework = (
        "/Applications/Garage.app/Contents/Frameworks/PythonXPCService.framework/Frameworks/libtesseract.5.5.dylib"
    )
    monkeypatch.setattr(tesseract, "loaded_library", lambda name: framework)
    monkeypatch.setattr(tesseract.ctypes.util, "find_library", lambda name: f"/usr/lib/lib{name}.dylib")
    assert tesseract._find_library() == framework


def test_then_the_linker_search(monkeypatch, nothing_loaded):
    monkeypatch.setattr(tesseract.ctypes.util, "find_library", lambda name: f"/usr/lib/lib{name}.dylib")
    assert tesseract._find_library() == "/usr/lib/libtesseract.dylib"


def test_missing_library_is_unavailable(monkeypatch, nothing_loaded):
    monkeypatch.setattr(tesseract.sys, "platform", "darwin")
    with pytest.raises(tesseract.TesseractUnavailable, match="not loaded"):
        tesseract._find_library()


def test_data_comes_from_the_frameworks_tessdata(tmp_path):
    framework = tmp_path / "PythonXPCService.framework"
    (framework / "Frameworks").mkdir(parents=True)
    (framework / "tessdata").mkdir()
    library = framework / "Frameworks" / "libtesseract.5.5.dylib"
    assert tesseract._datapath(str(library)) is None, "no language data yet"

    (framework / "tessdata" / "eng.traineddata").touch()
    assert tesseract._datapath(str(library)) == str(framework / "tessdata")


def test_data_comes_from_a_versioned_frameworks_resources(tmp_path):
    version = tmp_path / "PythonXPCService.framework" / "Versions" / "A"
    (version / "Frameworks").mkdir(parents=True)
    (version / "Resources" / "tessdata").mkdir(parents=True)
    library = version / "Frameworks" / "libtesseract.5.5.dylib"
    assert tesseract._datapath(str(library)) is None, "no language data yet"

    (version / "Resources" / "tessdata" / "eng.traineddata").touch()
    assert tesseract._datapath(str(library)) == str(version / "Resources" / "tessdata")


def test_windows_finds_the_installed_dll_by_its_versioned_name(tmp_path):
    empty = tmp_path / "on-path"
    empty.mkdir()
    install = tmp_path / "Tesseract-OCR"
    install.mkdir()
    (install / "tesseract.exe").touch()
    assert tesseract._find_windows_library([empty, tmp_path / "missing", install]) is None

    dll = install / "libtesseract-5.dll"
    dll.touch()
    assert tesseract._find_windows_library([empty, tmp_path / "missing", install]) == str(dll)


def test_windows_install_dirs_cover_machine_and_user_installs(monkeypatch, tmp_path):
    monkeypatch.setenv("PROGRAMFILES", str(tmp_path / "Program Files"))
    monkeypatch.setenv("LOCALAPPDATA", str(tmp_path / "Local"))
    assert tesseract._windows_install_dirs() == [
        tmp_path / "Program Files" / "Tesseract-OCR",
        tmp_path / "Local" / "Programs" / "Tesseract-OCR",
    ]


def test_windows_missing_library_says_how_to_install(monkeypatch, nothing_loaded):
    monkeypatch.setattr(tesseract.sys, "platform", "win32")
    monkeypatch.setattr(tesseract, "_find_windows_library", lambda: None)
    with pytest.raises(tesseract.TesseractUnavailable, match="UB-Mannheim.TesseractOCR"):
        tesseract._find_library()


def test_data_comes_from_the_tessdata_beside_a_windows_install(tmp_path):
    install = tmp_path / "Tesseract-OCR"
    (install / "tessdata").mkdir(parents=True)
    library = install / "libtesseract-5.dll"
    assert tesseract._datapath(str(library)) is None, "no language data yet"

    (install / "tessdata" / "eng.traineddata").touch()
    assert tesseract._datapath(str(library)) == str(install / "tessdata")


@pytest.mark.parametrize(
    ("mode", "expected"),
    [("RGB", "RGB"), ("L", "L"), ("1", "L"), ("P", "RGB"), ("RGBA", "RGB"), ("LA", "RGB"), ("CMYK", "RGB")],
)
def test_pixels_are_grey_or_rgb(mode, expected):
    assert tesseract._pixels_for(Image.new(mode, (8, 8))).mode == expected


def test_transparency_goes_onto_white():
    clear = Image.new("RGBA", (4, 4), (0, 0, 0, 0))
    assert tesseract._pixels_for(clear).getpixel((0, 0)) == (255, 255, 255)


needs_library = pytest.mark.skipif(
    not os.environ.get("GARAGE_TEST_LIBTESSERACT") or not os.environ.get("GARAGE_TEST_TESSDATA_FILE"),
    reason="needs the bundled libtesseract and tessdata (Bazel supplies them on macOS)",
)


@pytest.fixture
def tessdata(monkeypatch):
    # Tesseract's own variable, read when no datapath is passed: the test build is not in a framework.
    monkeypatch.setenv("TESSDATA_PREFIX", str(Path(os.environ["GARAGE_TEST_TESSDATA_FILE"]).resolve().parent))


def _sentence(mode: str = "RGB") -> Image.Image:
    image = Image.new("RGB", (900, 220), "white")
    draw = ImageDraw.Draw(image)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 48)
    except OSError:
        font = ImageFont.load_default(size=48)
    draw.text((20, 60), "Garage reads this sentence.", fill="black", font=font)
    return image.convert(mode)


@needs_library
@pytest.mark.parametrize("mode", ["RGB", "L", "RGBA"])
def test_reads_a_rendered_sentence(tessdata, mode):
    words = tesseract.recognize(_sentence(mode))
    assert " ".join(w.text for w in words) == "Garage reads this sentence."
    assert all(w.confidence > 80 for w in words)


@needs_library
def test_a_blank_page_has_no_words(tessdata):
    assert tesseract.recognize(Image.new("RGB", (400, 300), "white")) == []


@needs_library
def test_version_is_the_bundled_build():
    assert tesseract.version().startswith("5.")
