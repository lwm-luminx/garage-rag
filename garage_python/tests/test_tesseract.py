"""garage_rag.extract.tesseract: finding libtesseract, and OCR through its C API.

The recognition tests run through each way garage_rag reads images: ``_garage_tesseract``
(built into the app's Python; CI builds it as an extension module with
tools/garage_tesseract/build_extension.sh and puts it on PYTHONPATH) and the system
libtesseract through ctypes. Each needs English language data where Tesseract looks by
default (or TESSDATA_PREFIX); a way that is not available here skips.
"""

from __future__ import annotations

import threading

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


@pytest.fixture(params=["builtin", "ctypes"])
def backend(request, monkeypatch):
    """Each way of reading, with a fresh engine; skips one this Python cannot use."""
    monkeypatch.setattr(tesseract, "_local", threading.local())
    if request.param == "builtin":
        if tesseract.builtin_module() is None:
            pytest.skip("no _garage_tesseract (built into the app's Python; CI builds it)")
    else:
        monkeypatch.setattr(tesseract, "builtin_module", lambda: None)
        try:
            tesseract._find_library()
        except tesseract.TesseractUnavailable as exc:
            pytest.skip(str(exc))
    try:
        tesseract._engine()
    except tesseract.TesseractUnavailable as exc:
        pytest.skip(str(exc))
    return request.param


def _sentence(mode: str = "RGB") -> Image.Image:
    image = Image.new("RGB", (900, 220), "white")
    draw = ImageDraw.Draw(image)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Helvetica.ttc", 48)
    except OSError:
        font = ImageFont.load_default(size=48)
    draw.text((20, 60), "Garage reads this sentence.", fill="black", font=font)
    return image.convert(mode)


@pytest.mark.parametrize("mode", ["RGB", "L", "RGBA"])
def test_reads_a_rendered_sentence(backend, mode):
    words = tesseract.recognize(_sentence(mode))
    assert " ".join(w.text for w in words) == "Garage reads this sentence."
    assert all(w.confidence > 80 for w in words)


def test_a_blank_page_has_no_words(backend):
    assert tesseract.recognize(Image.new("RGB", (400, 300), "white")) == []


def test_a_stated_resolution_reads_the_same(backend):
    image = _sentence()
    image.info["dpi"] = (144, 144)
    assert " ".join(w.text for w in tesseract.recognize(image)) == "Garage reads this sentence."


def test_version_is_tesseract_5(backend):
    assert tesseract.version().startswith("5.")


def test_the_app_reads_through_the_builtin_module(monkeypatch):
    module = object()
    monkeypatch.setattr(tesseract, "builtin_module", lambda: module)
    monkeypatch.setattr(tesseract, "_BuiltinEngine", lambda found: ("builtin", found))
    monkeypatch.setattr(tesseract, "_local", threading.local())
    assert tesseract._engine() == ("builtin", module)


def test_the_apps_data_is_beside_site_python(monkeypatch, tmp_path):
    resources = tmp_path / "PythonXPCService.framework" / "Versions" / "A" / "Resources"
    (resources / "site-python").mkdir(parents=True)
    monkeypatch.setattr(tesseract.sys, "prefix", str(resources / "site-python"))
    monkeypatch.setattr(tesseract.os, "__file__", str(resources / "site-python" / "os.py"))
    assert tesseract._bundled_datapath() is None, "no language data yet"

    (resources / "tessdata").mkdir()
    (resources / "tessdata" / "eng.traineddata").touch()
    assert tesseract._bundled_datapath() == str(resources / "tessdata")


def test_the_builtin_module_checks_the_buffer(backend):
    if backend != "builtin":
        pytest.skip("the module's own argument check")
    engine = tesseract._engine().engine
    with pytest.raises(ValueError, match="does not hold"):
        engine.words(b"\xff" * 10, 100, 100, 1, 100)
