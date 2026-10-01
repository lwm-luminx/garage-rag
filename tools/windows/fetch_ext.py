"""Fetch the pinned //ext sources for the Windows CI build (.github/workflows/windows.yaml).

The macOS build gets Postgres, pgvector, ICU, zlib and Python through Bazel repository rules
in ext/<name>/<name>.MODULE.bazel. The Windows build does not go through Bazel, so this reads
the same files and fetches the same archive (sha256-checked) or git commit, keeping the two
builds on one set of pins. Patches and patch_cmds are not applied: they are macOS-specific
(the Postgres ones replace SysV shared memory for the App Sandbox; Windows uses its own).

    python tools/windows/fetch_ext.py --dest C:/src postgres libicu libzlib pgvector python

Each source lands in DEST/<name>, with strip_prefix removed. Standard library only.
"""

import argparse
import hashlib
import io
import re
import shutil
import sys
import tarfile
import urllib.request
import zipfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

# Module files that do not follow ext/<name>/<name>.MODULE.bazel.
MODULE_FILES = {"python": REPO / "ext/python/python.MODULE.bazel"}


def _string(text: str, key: str) -> str | None:
    match = re.search(rf'^\s*{key}\s*=\s*"([^"]*)"', text, re.MULTILINE)
    return match.group(1) if match else None


def pins(name: str) -> dict[str, object]:
    path = MODULE_FILES.get(name, REPO / "ext" / name / f"{name}.MODULE.bazel")
    text = path.read_text()
    commit, remote = _string(text, "commit"), _string(text, "remote")
    if commit and remote:
        url = remote.removesuffix(".git") + f"/archive/{commit}.tar.gz"
        return {"urls": [url], "sha256": None, "strip_prefix": None, "source": path}
    urls_block = re.search(r"urls\s*=\s*\[(.*?)\]", text, re.DOTALL)
    if not urls_block:
        raise SystemExit(f"{path}: no urls or commit/remote")
    return {
        "urls": re.findall(r'"([^"]+)"', urls_block.group(1)),
        "sha256": _string(text, "sha256"),
        "strip_prefix": _string(text, "strip_prefix"),
        "source": path,
    }


def download(urls: list[str], sha256: str | None = None) -> bytes:
    """The first url's body that matches sha256 (when pinned), as Bazel's http_archive takes it.

    A mirror serving other bytes under the pinned name (zlib.net has done so for zlib-1.3.2) is
    skipped like one that is down, rather than failing the build while a later url has the file.
    """
    for url in urls:
        try:
            print(f"  GET {url}", flush=True)
            with urllib.request.urlopen(url, timeout=300) as response:
                data = response.read()
        except OSError as error:
            print(f"  failed: {error}", flush=True)
            continue
        if sha256:
            digest = hashlib.sha256(data).hexdigest()
            if digest != sha256:
                print(
                    f"  sha256 {digest} does not match the pinned {sha256}", flush=True
                )
                continue
            print(f"  sha256 ok ({digest})", flush=True)
        return data
    raise SystemExit("no url served the pinned file" if sha256 else "every url failed")


def extract(data: bytes, dest: Path, strip_prefix: str | None) -> None:
    staging = dest.with_name(dest.name + ".staging")
    shutil.rmtree(staging, ignore_errors=True)
    staging.mkdir(parents=True)
    if data[:2] == b"PK":
        zipfile.ZipFile(io.BytesIO(data)).extractall(staging)
    else:
        with tarfile.open(fileobj=io.BytesIO(data)) as archive:
            archive.extractall(staging, filter="tar")
    if strip_prefix:
        root = staging / strip_prefix
    else:
        # A GitHub archive has one top-level directory, <repo>-<commit>.
        entries = list(staging.iterdir())
        root = entries[0] if len(entries) == 1 and entries[0].is_dir() else staging
    shutil.rmtree(dest, ignore_errors=True)
    shutil.move(root, dest)
    shutil.rmtree(staging, ignore_errors=True)


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument("--dest", type=Path, required=True)
    parser.add_argument("names", nargs="+")
    args = parser.parse_args()
    for name in args.names:
        pin = pins(name)
        print(f"{name}: {pin['source'].relative_to(REPO)}", flush=True)
        data = download(pin["urls"], pin["sha256"])
        extract(data, args.dest / name, pin["strip_prefix"])
        print(f"  -> {args.dest / name}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
