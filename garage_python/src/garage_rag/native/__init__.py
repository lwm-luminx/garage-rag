"""Native libraries the app's framework loads into every Python process.

``PythonXPCService.framework`` links libpq with a load command, so dyld maps it
when a Garage service or launcher starts, before the App Sandbox applies (a
sandboxed process may not open it by path later). Python code finds it here,
among the images already loaded into the process, and hands that path to ctypes,
which then gets the loaded copy rather than opening another file.
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
