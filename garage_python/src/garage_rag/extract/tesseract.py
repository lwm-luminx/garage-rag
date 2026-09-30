"""In-process Tesseract through its C API (``capi.h``), loaded with ctypes.

The CLI route (pytesseract) forks a ``tesseract`` process per image, writes the
image to a temp file for it, and reloads the language model every time. Here the
pixels Pillow already decoded go straight to ``TessBaseAPISetImage``, and each
thread keeps one initialised engine, so the model loads once.

In the app, ``PythonXPCService.framework`` links libtesseract, so it is already
loaded (:func:`garage_rag.native.loaded_library`) and its English data sits in the
framework's ``tessdata`` folder: in ``Resources`` beside the ``Frameworks`` folder that holds
the library (the versioned layout the app ships), or beside ``Frameworks`` itself (a flat
one). Elsewhere (a venv) the dynamic linker's search finds the library, and Tesseract's own
default (or ``TESSDATA_PREFIX``) finds the data. On Windows the installed ``libtesseract-5.dll`` is
also looked for in Tesseract's install folder, with the ``tessdata`` beside it.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import os
import sys
import threading
from dataclasses import dataclass
from pathlib import Path

from PIL import Image

from garage_rag.native import loaded_library

LANGUAGE = "eng"

# TessPageIteratorLevel / TessPageSegMode values from publictypes.h.
_RIL_WORD = 3
# The CLI's default, and so what pytesseract used. TessBaseAPI itself defaults to
# PSM_SINGLE_BLOCK, which reads a multi-column screenshot as one run of text.
_PSM_AUTO = 3
# Below this, Tesseract ignores a stated resolution and estimates its own.
_MIN_CREDIBLE_DPI = 70


class TesseractUnavailable(RuntimeError):
    """libtesseract, or its language data, could not be loaded."""


@dataclass(frozen=True)
class Word:
    text: str
    confidence: float


def _find_library() -> str:
    loaded = loaded_library("tesseract")
    if loaded:
        return loaded
    found = ctypes.util.find_library("tesseract")
    if found:
        return found
    if sys.platform == "win32":
        found = _find_windows_library()
        if found:
            return found
        raise TesseractUnavailable(
            "libtesseract not found: install Tesseract for Windows (winget install UB-Mannheim.TesseractOCR), "
            f"which puts libtesseract-5.dll in {_windows_install_dirs()[0]}"
        )
    raise TesseractUnavailable("libtesseract not found: not loaded by the app's framework, nor on the linker's path")


def _windows_install_dirs() -> list[Path]:
    """Where the Windows installer puts Tesseract: for every user, then for the current one."""
    program_files = Path(os.environ.get("PROGRAMFILES", r"C:\Program Files"))
    dirs = [program_files / "Tesseract-OCR"]
    if local := os.environ.get("LOCALAPPDATA"):
        dirs.append(Path(local) / "Programs" / "Tesseract-OCR")
    return dirs


def _find_windows_library(search_dirs: list[Path] | None = None) -> str | None:
    """``libtesseract-<N>.dll`` on ``PATH`` or in a standard install folder, else None.

    The Windows build Tesseract's documentation points to (UB Mannheim's) names the DLL
    ``libtesseract-5.dll``, which ``find_library("tesseract")`` does not look for, and installs
    it, its dependencies and ``tessdata`` into one folder that is usually not on ``PATH``.
    Loading it by full path lets Windows find those dependencies beside it.
    """
    if search_dirs is None:
        path_dirs = [Path(entry) for entry in os.environ.get("PATH", "").split(os.pathsep) if entry]
        search_dirs = [*path_dirs, *_windows_install_dirs()]
    for directory in search_dirs:
        candidates = sorted(directory.glob("libtesseract-*.dll"), reverse=True) if directory.is_dir() else []
        if candidates:
            return str(candidates[0])
    return None


def _datapath(library: str) -> str | None:
    """The framework's ``tessdata`` for a library in its ``Frameworks`` folder, or the one beside
    the library (a Windows install), else None (Tesseract's own default, or ``TESSDATA_PREFIX``).

    On Windows the default is relative to the running executable, here ``python.exe``, so an
    installed Tesseract's data is only found through the folder beside its DLL.
    """
    version = Path(library).parent.parent
    for tessdata in (version / "Resources" / "tessdata", version / "tessdata", Path(library).parent / "tessdata"):
        if (tessdata / f"{LANGUAGE}.traineddata").is_file():
            return str(tessdata)
    return None


_lib_lock = threading.Lock()
_lib: ctypes.CDLL | None = None
_lib_datapath: str | None = None


def _library() -> ctypes.CDLL:
    global _lib, _lib_datapath
    with _lib_lock:
        if _lib is not None:
            return _lib
        path = _find_library()
        # A libtesseract built with OpenMP (Homebrew's may be) threads internally,
        # which inside a process pool oversubscribes the CPU. The bundled one has none.
        os.environ.setdefault("OMP_THREAD_LIMIT", "1")
        try:
            lib = ctypes.CDLL(path)
        except OSError as exc:
            raise TesseractUnavailable(f"cannot load libtesseract at {path}: {exc}") from exc

        handle = ctypes.c_void_p
        lib.TessVersion.restype = ctypes.c_char_p
        lib.TessBaseAPICreate.restype = handle
        lib.TessBaseAPIDelete.argtypes = [handle]
        lib.TessBaseAPIInit3.argtypes = [handle, ctypes.c_char_p, ctypes.c_char_p]
        lib.TessBaseAPIInit3.restype = ctypes.c_int
        lib.TessBaseAPISetVariable.argtypes = [handle, ctypes.c_char_p, ctypes.c_char_p]
        lib.TessBaseAPISetVariable.restype = ctypes.c_int
        lib.TessBaseAPISetPageSegMode.argtypes = [handle, ctypes.c_int]
        lib.TessBaseAPISetImage.argtypes = [
            handle,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_int,
        ]
        lib.TessBaseAPISetSourceResolution.argtypes = [handle, ctypes.c_int]
        lib.TessBaseAPIRecognize.argtypes = [handle, ctypes.c_void_p]
        lib.TessBaseAPIRecognize.restype = ctypes.c_int
        lib.TessBaseAPIGetIterator.argtypes = [handle]
        lib.TessBaseAPIGetIterator.restype = handle
        lib.TessBaseAPIClear.argtypes = [handle]
        lib.TessResultIteratorDelete.argtypes = [handle]
        lib.TessResultIteratorNext.argtypes = [handle, ctypes.c_int]
        lib.TessResultIteratorNext.restype = ctypes.c_int
        lib.TessResultIteratorConfidence.argtypes = [handle, ctypes.c_int]
        lib.TessResultIteratorConfidence.restype = ctypes.c_float
        # A char* the caller must hand back to TessDeleteText, so not c_char_p
        # (ctypes would copy it and drop the pointer).
        lib.TessResultIteratorGetUTF8Text.argtypes = [handle, ctypes.c_int]
        lib.TessResultIteratorGetUTF8Text.restype = ctypes.POINTER(ctypes.c_char)
        lib.TessDeleteText.argtypes = [ctypes.POINTER(ctypes.c_char)]
        _lib = lib
        _lib_datapath = _datapath(path)
        return lib


def version() -> str:
    return _library().TessVersion().decode()


class _Engine:
    """One initialised TessBaseAPI. Not thread-safe; see :func:`_engine`."""

    def __init__(self) -> None:
        self.lib = _library()
        self.api = self.lib.TessBaseAPICreate()
        datapath = _lib_datapath
        rc = self.lib.TessBaseAPIInit3(self.api, datapath.encode() if datapath else None, LANGUAGE.encode())
        if rc != 0:
            self.lib.TessBaseAPIDelete(self.api)
            where = datapath or "the library's default tessdata"
            raise TesseractUnavailable(f"tesseract could not load '{LANGUAGE}' language data from {where}")
        self.lib.TessBaseAPISetPageSegMode(self.api, _PSM_AUTO)
        # tprintf goes to stderr otherwise ("Estimating resolution as ..." per image).
        self.lib.TessBaseAPISetVariable(self.api, b"debug_file", b"/dev/null")

    def __del__(self) -> None:
        api = getattr(self, "api", None)
        if api:
            self.lib.TessBaseAPIDelete(api)

    def words(self, image: Image.Image) -> list[Word]:
        lib, api = self.lib, self.api
        pixels = image.tobytes()
        bpp = len(image.getbands())
        lib.TessBaseAPISetImage(api, pixels, image.width, image.height, bpp, image.width * bpp)
        dpi = image.info.get("dpi")
        if dpi and int(dpi[0]) >= _MIN_CREDIBLE_DPI:
            lib.TessBaseAPISetSourceResolution(api, int(dpi[0]))
        try:
            if lib.TessBaseAPIRecognize(api, None) != 0:
                raise RuntimeError("tesseract recognition failed")
            iterator = lib.TessBaseAPIGetIterator(api)
            if not iterator:
                return []
            words: list[Word] = []
            try:
                while True:
                    raw = lib.TessResultIteratorGetUTF8Text(iterator, _RIL_WORD)
                    if raw:
                        text = ctypes.string_at(raw).decode("utf-8", errors="replace")
                        lib.TessDeleteText(raw)
                        words.append(Word(text, float(lib.TessResultIteratorConfidence(iterator, _RIL_WORD))))
                    if not lib.TessResultIteratorNext(iterator, _RIL_WORD):
                        break
            finally:
                lib.TessResultIteratorDelete(iterator)
            return words
        finally:
            lib.TessBaseAPIClear(api)


_local = threading.local()


def _engine() -> _Engine:
    engine = getattr(_local, "engine", None)
    if engine is None:
        engine = _Engine()
        _local.engine = engine
    return engine


def _pixels_for(image: Image.Image) -> Image.Image:
    """8-bit grey or RGB, the layouts SetImage takes; transparency goes onto white."""
    if image.mode in ("L", "RGB"):
        return image
    if "A" in image.getbands() or image.mode == "P" and "transparency" in image.info:
        rgba = image.convert("RGBA")
        background = Image.new("RGBA", rgba.size, (255, 255, 255, 255))
        return Image.alpha_composite(background, rgba).convert("RGB")
    return image.convert("L" if image.mode in ("1", "I", "I;16", "F") else "RGB")


def recognize(image: Image.Image) -> list[Word]:
    """Words Tesseract reads in ``image``, with their 0-100 confidences."""
    return _engine().words(_pixels_for(image))
