"""Native libraries already loaded into the process, for the ctypes fallbacks.

The app's interpreter loads none: psycopg_c and libpq, Tesseract and libgit2 are linked in and
reached through built-in modules. Outside it (the Bazel py_tests on macOS, which preload the
signed libpq) a library may already be mapped; Python code finds it here, among the images
loaded into the process, and hands that path to ctypes, which then gets the loaded copy rather
than opening another file.
"""

from __future__ import annotations

import ctypes
import os
import sys


def loaded_library(name: str) -> str | None:
    """Path of the loaded image ``lib{name}.*.dylib`` / ``lib{name}.dylib``, or None.

    None outside macOS, and when no such library is loaded (a plain venv, where
    callers fall back to their own search).
    """
    if sys.platform != "darwin":
        return None
    system = ctypes.CDLL(None)
    system._dyld_image_count.restype = ctypes.c_uint32
    system._dyld_get_image_name.argtypes = [ctypes.c_uint32]
    system._dyld_get_image_name.restype = ctypes.c_char_p
    prefix = f"lib{name}."
    for index in range(system._dyld_image_count()):
        image = system._dyld_get_image_name(index)
        if not image:
            continue
        path = os.fsdecode(image)
        base = os.path.basename(path)
        if base.startswith(prefix) and base.endswith(".dylib"):
            return path
    return None
