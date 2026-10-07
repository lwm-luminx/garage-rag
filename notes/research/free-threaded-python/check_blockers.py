#!/usr/bin/env python3
"""Check what still blocks Garage from a free-threaded (3.14t) Python build.

For each blocker package: the latest PyPI release, whether it ships cp314t wheels (macOS arm64 and
Linux), and, when a Linux cp314t wheel exists and a free-threaded interpreter is available, whether
importing it re-enables the GIL. Prints a JSON report; compare with the previous run's
blockers-status.json to see what changed.

Usage: python3 check_blockers.py [--python /path/to/python3.14t]
"""
import json, ssl, subprocess, sys, tempfile, urllib.request, os, shutil

CA = os.environ.get("SSL_CERT_FILE") or ("/root/.ccr/ca-bundle.crt" if os.path.exists("/root/.ccr/ca-bundle.crt") else None)
CTX = ssl.create_default_context(cafile=CA) if CA else ssl.create_default_context()

# package -> module to import for the GIL check (None: pure Python or not importable on Linux)
BLOCKERS = {
    "grpcio": "grpc",                 # re-enables the GIL; no free-threaded wheels at all (2026-09-27)
    "lxml": "lxml.etree",             # re-enables the GIL despite cp314t wheels
    "sqlalchemy": "sqlalchemy",       # 2.0.x cyextension re-enables the GIL; 2.1 has none
    "protobuf": "google.protobuf",    # abi3 only: pure-Python fallback; the abi3 .so segfaults on macOS 3.14t
    "tree-sitter-swift": None,        # abi3 only (dev extra); does not build
    "tree-sitter": None,              # cp313/cp314 wheels, no t
    "cryptography": "cryptography.hazmat.bindings._rust",  # fine from 45+, pinned <44 in pyproject
    "pypdfium2": None,                # py3-none wheel, fine
}

def pypi(name):
    with urllib.request.urlopen(f"https://pypi.org/pypi/{name}/json", context=CTX, timeout=30) as r:
        return json.load(r)

def wheel_summary(files):
    names = [f["filename"] for f in files]
    t = [n for n in names if "cp314t" in n or "cp315t" in n]
    return {
        "free_threaded_wheels": len(t),
        "mac_arm64_t": any("macosx" in n and ("arm64" in n or "universal2" in n) for n in t),
        "linux_x86_64_t": any("linux" in n and "x86_64" in n for n in t),
        "abi3_only": bool(names) and all("abi3" in n or "none-any" in n or "py3-none" in n for n in names) and any("abi3" in n for n in names),
    }

def gil_check(python, pkg, module):
    """Install pkg (binary only) into a throwaway venv on the free-threaded interpreter and import it."""
    uv = shutil.which("uv") or "/tmp/uvnew/bin/uv"
    if not (python and module and os.path.exists(uv)):
        return None
    d = tempfile.mkdtemp()
    try:
        if subprocess.run([uv, "venv", "-q", "--python", python, d], capture_output=True).returncode: return None
        r = subprocess.run([uv, "pip", "install", "-q", "--python", f"{d}/bin/python", "--only-binary", ":all:", pkg], capture_output=True, text=True)
        if r.returncode: return {"installed": False, "reason": r.stderr.strip().splitlines()[-1][:160] if r.stderr.strip() else "install failed"}
        code = (f"import sys,warnings\nwith warnings.catch_warnings(record=True) as w:\n warnings.simplefilter('always')\n import {module}\n"
                "print(json.dumps({'gil_enabled_after_import': sys._is_gil_enabled(), 'warnings': [str(x.message)[:120] for x in w if 'GIL' in str(x.message)]}))")
        r = subprocess.run([f"{d}/bin/python", "-c", "import json\n" + code], capture_output=True, text=True, env={"PATH": os.environ["PATH"]})
        if r.returncode: return {"installed": True, "import_failed": r.stderr.strip()[-200:]}
        return {"installed": True, **json.loads(r.stdout)}
    finally:
        shutil.rmtree(d, ignore_errors=True)

def main():
    python = None
    if "--python" in sys.argv: python = sys.argv[sys.argv.index("--python") + 1]
    report = {}
    for pkg, module in BLOCKERS.items():
        try:
            d = pypi(pkg)
        except Exception as e:
            report[pkg] = {"error": str(e)}; continue
        ver = d["info"]["version"]
        entry = {"latest": ver, "released": max((f["upload_time"] for f in d["releases"][ver]), default=None), **wheel_summary(d["releases"][ver])}
        entry["gil"] = gil_check(python, pkg, module) if entry["linux_x86_64_t"] else None
        report[pkg] = entry
    print(json.dumps(report, indent=2, sort_keys=True))

if __name__ == "__main__":
    main()
