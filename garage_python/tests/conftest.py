"""Load the native libraries PythonXPCService.framework loads in the app.

In the app, dyld has loaded libpq before Python starts, and garage_rag finds it
among the process's images (garage_rag.native). On macOS Bazel hands the tests the
same build through a test-only variable; loading it here, before any test imports
garage_rag, puts it where it looks.

At the end of every run it also writes the runtime files manifest (see
pytest_unconfigure below).
"""

from __future__ import annotations

import ctypes
import os

_libpq = os.environ.get("GARAGE_TEST_LIBPQ")
if _libpq:
    ctypes.CDLL(os.path.abspath(_libpq), mode=ctypes.RTLD_GLOBAL)


def pytest_unconfigure(config):
    """Write the runtime files manifest: every Python file the run loaded.

    One absolute path per line, sorted, collected from ``sys.modules`` as the
    session ends, so it covers source, bytecode-only and extension modules
    alike (frozen, built-in and namespace modules have no file). It shows what a
    bundled interpreter has to carry for the suite's code paths.

    Written to ``GARAGE_RUNTIME_MANIFEST`` when set; under Bazel to the test's
    undeclared outputs (``bazel-testlogs/<target>/test.outputs``); otherwise to
    pytest's cache folder (``.pytest_cache/d/garage/runtime_files.txt``).
    """
    import sys
    from pathlib import Path

    loaded: set[str] = set()
    for module in list(sys.modules.values()):
        path = getattr(module, "__file__", None)
        if isinstance(path, str) and path:
            loaded.add(os.path.abspath(path))

    target = os.environ.get("GARAGE_RUNTIME_MANIFEST")
    if target:
        manifest = Path(target)
    elif os.environ.get("TEST_UNDECLARED_OUTPUTS_DIR"):
        manifest = Path(os.environ["TEST_UNDECLARED_OUTPUTS_DIR"]) / "runtime_files.txt"
    elif (cache := getattr(config, "cache", None)) is not None:
        manifest = cache.mkdir("garage") / "runtime_files.txt"
    else:  # the cacheprovider plugin is disabled (-p no:cacheprovider)
        return
    manifest.parent.mkdir(parents=True, exist_ok=True)
    manifest.write_text("".join(f"{path}\n" for path in sorted(loaded)))
