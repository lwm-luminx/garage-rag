#!/usr/bin/env python3
"""Generate (or check) THIRD_PARTY_NOTICES.txt for everything the Garage app redistributes.

The macOS app bundles a Python runtime plus every runtime package in `garage_python/uv.lock`,
a from-source Postgres + pgvector + Apache AGE (with ICU and zlib), OpenSSL, llama.cpp, Tesseract +
Leptonica, libgit2, PythonKit, Sparkle, the Swift gRPC/NIO/protobuf runtime pulled in by rules_swift,
and third-party code vendored into garage_python (see NOTICE). Their licenses (MIT, BSD, Apache,
Unicode, PSF, LGPL, ...) require the license text to accompany binary redistribution, so this
collects the actual license files from each upstream release into one text file that ships in
`Garage.app/Contents/Resources`.

    # regenerate after changing uv.lock, ext/, or vendored code (needs network)
    python3 tools/third_party_notices.py

    # offline: fail if the committed file no longer covers the lockfile + NATIVE_COMPONENTS
    python3 tools/third_party_notices.py --check

Stdlib only, so it runs without the project venv.
"""

from __future__ import annotations

import argparse
import io
import json
import re
import sys
import tarfile
import time
import tomllib
import urllib.error
import urllib.request
import zipfile
from dataclasses import dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LOCKFILE = REPO / "garage_python" / "uv.lock"
OUTPUT = REPO / "data" / "notices" / "THIRD_PARTY_NOTICES.txt"
ROOT_PACKAGE = "garage-rag"
RAW = "https://raw.githubusercontent.com"
# Suffix for a source file whose license is only its header comment: keep just that comment.
HEADER = "#license-header"


@dataclass(frozen=True)
class Component:
    """A non-Python component compiled into or bundled with the app."""

    name: str
    version: str
    license: str
    homepage: str
    # raw.githubusercontent.com (or other plain-text) URLs of the upstream license files
    license_urls: tuple[str, ...]


# Everything shipped that uv.lock does not cover: ext/*.MODULE.bazel, the swift_proto deps of
# rules_swift (MODULE.bazel), and third-party code vendored into garage_python (see NOTICE).
# Components that are built but not shipped in the app are omitted.
NATIVE_COMPONENTS: tuple[Component, ...] = (
    Component(
        "CPython",
        "3.14.7",
        "PSF-2.0 (and bundled third-party licenses)",
        "https://www.python.org/",
        (
            f"{RAW}/python/cpython/v3.14.7/LICENSE",
            f"{RAW}/python/cpython/v3.14.7/Doc/license.rst",
        ),
    ),
    Component(
        "PostgreSQL",
        "18.6",
        "PostgreSQL",
        "https://www.postgresql.org/",
        (f"{RAW}/postgres/postgres/REL_18_6/COPYRIGHT",),
    ),
    Component(
        "pgvector",
        "0.8.6",
        "PostgreSQL",
        "https://github.com/pgvector/pgvector",
        (f"{RAW}/pgvector/pgvector/v0.8.6/LICENSE",),
    ),
    Component(
        "Apache AGE",
        "1.8.0",
        "Apache-2.0",
        "https://age.apache.org/",
        # PG18/v1.8.0-rc0 (the tag's slash does not survive a raw URL, so the commit)
        (
            f"{RAW}/apache/age/e43dc1a12b78fba4acef9835b2b10379b8d243b4/LICENSE",
            f"{RAW}/apache/age/e43dc1a12b78fba4acef9835b2b10379b8d243b4/NOTICE",
        ),
    ),
    Component(
        "ICU",
        "76.1",
        "Unicode-3.0",
        "https://icu.unicode.org/",
        (f"{RAW}/unicode-org/icu/release-76-1/LICENSE",),
    ),
    Component(
        "OpenSSL",
        "3.4.7",
        "Apache-2.0",
        "https://www.openssl.org/",
        (f"{RAW}/openssl/openssl/openssl-3.4.7/LICENSE.txt",),
    ),
    Component(
        "zlib",
        "1.3.2",
        "Zlib",
        "https://zlib.net/",
        (f"{RAW}/madler/zlib/v1.3.2/LICENSE",),
    ),
    Component(
        "llama.cpp (includes ggml)",
        "0.4.0",
        "MIT",
        "https://github.com/ggml-org/llama.cpp",
        (f"{RAW}/ggml-org/llama.cpp/v0.4.0/LICENSE",),
    ),
    Component(
        "Tesseract",
        "5.5.3",
        "Apache-2.0",
        "https://github.com/tesseract-ocr/tesseract",
        (f"{RAW}/tesseract-ocr/tesseract/5.5.3/LICENSE",),
    ),
    Component(
        "tessdata_fast (eng.traineddata)",
        "4.1.0",
        "Apache-2.0",
        "https://github.com/tesseract-ocr/tessdata_fast",
        (f"{RAW}/tesseract-ocr/tessdata_fast/4.1.0/LICENSE",),
    ),
    Component(
        "nomic-embed-text v1.5 (Q2_K GGUF, LlamaXPCService known-answer self-test)",
        "1.5",
        "Apache-2.0",
        "https://huggingface.co/nomic-ai/nomic-embed-text-v1.5",
        # Neither Hugging Face repository carries a LICENSE file; both declare apache-2.0.
        ("https://www.apache.org/licenses/LICENSE-2.0.txt",),
    ),
    Component(
        # COPYING carries the GPL-2.0 linking exception and the licenses of the code libgit2
        # bundles (xdiff, the SHA-1 collision detection, the builtin SHA-256, http-parser, ...).
        "libgit2",
        "1.9.7",
        "GPL-2.0-only WITH GCC-exception-2.0",
        "https://libgit2.org/",
        (f"{RAW}/libgit2/libgit2/v1.9.7/COPYING",),
    ),
    Component(
        "Leptonica",
        "1.87.0",
        "BSD-2-Clause",
        "http://www.leptonica.org/",
        (f"{RAW}/DanBloomberg/leptonica/1.87.0/leptonica-license.txt",),
    ),
    Component(
        # lxml's macOS wheel links libiconv statically into etree and objectify; lxml's own notice
        # names it, but LGPL-2.1 needs its full text to travel with the binary.
        "GNU libiconv (statically linked into lxml's binary wheel)",
        "as bundled in lxml 6.1.2",
        "LGPL-2.1-or-later",
        "https://www.gnu.org/software/libiconv/ (source: https://ftp.gnu.org/pub/gnu/libiconv/)",
        (f"{RAW}/spdx/license-list-data/v3.27.0/text/LGPL-2.1-only.txt",),
    ),
    Component(
        # LGPL-3.0 section 4(b) requires the GPL-3.0 text to accompany a work that uses an LGPL-3.0
        # library (psycopg and psycopg-pool); their wheels ship only the LGPL text.
        "GNU General Public License, version 3 (for the LGPL-3.0 components)",
        "3.0",
        "GPL-3.0",
        "https://www.gnu.org/licenses/gpl-3.0.html",
        (f"{RAW}/spdx/license-list-data/v3.27.0/text/GPL-3.0-only.txt",),
    ),
    Component(
        "Sparkle",
        "2.10.0",
        "MIT (and bundled third-party licenses)",
        "https://sparkle-project.org/",
        (f"{RAW}/sparkle-project/Sparkle/2.10.0/LICENSE",),
    ),
    Component(
        # Windows: the Burn engine and its standard installer UI, which Garage-Setup.exe embeds
        # (winapp/packaging/setup); the MSI itself carries no WiX code. MS-RL 3(A) asks for the
        # license and the source of those files, which is the tag below, unmodified.
        "WiX Toolset (Burn bootstrapper in Garage-Setup.exe)",
        "5.0.2",
        "MS-RL",
        "https://wixtoolset.org/ (source: https://github.com/wixtoolset/wix/tree/v5.0.2)",
        (
            f"{RAW}/wixtoolset/wix/v5.0.2/LICENSE.TXT",
            f"{RAW}/spdx/license-list-data/v3.27.0/text/MS-RL.txt",
        ),
    ),
    Component(
        "LangExtract (vendored subset, modified)",
        "1.7.0",
        "Apache-2.0",
        "https://github.com/google/langextract",
        (f"{RAW}/google/langextract/v1.7.0/LICENSE",),
    ),
    Component(
        "langchain-text-splitters (reimplemented in garage_rag.ingest.splitters)",
        "1.1.2",
        "MIT",
        "https://github.com/langchain-ai/langchain",
        (f"{RAW}/langchain-ai/langchain/langchain-text-splitters%3D%3D1.1.2/LICENSE",),
    ),
    Component(
        "PythonKit",
        "0.5.1",
        "Apache-2.0",
        "https://github.com/pvieito/PythonKit",
        (f"{RAW}/pvieito/PythonKit/v0.5.1/LICENSE.txt",),
    ),
    Component(
        "SwiftProtobuf",
        "1.20.2",
        "Apache-2.0",
        "https://github.com/apple/swift-protobuf",
        (f"{RAW}/apple/swift-protobuf/1.20.2/LICENSE.txt",),
    ),
    Component(
        "grpc-swift",
        "1.16.0",
        "Apache-2.0",
        "https://github.com/grpc/grpc-swift",
        (
            f"{RAW}/grpc/grpc-swift/1.16.0/LICENSE",
            f"{RAW}/grpc/grpc-swift/1.16.0/NOTICES.txt",
        ),
    ),
    Component(
        "SwiftNIO (includes llhttp, uSHET cpp_magic.h and FreeBSD sha1)",
        "2.42.0",
        "Apache-2.0 AND MIT AND BSD-3-Clause",
        "https://github.com/apple/swift-nio",
        (
            f"{RAW}/apple/swift-nio/2.42.0/LICENSE.txt",
            f"{RAW}/apple/swift-nio/2.42.0/NOTICE.txt",
            # Code NOTICE.txt lists as vendored into the compiled modules.
            f"{RAW}/apple/swift-nio/2.42.0/Sources/CNIOLLHTTP/LICENSE-MIT",
            # CNIOAtomics/src/cpp_magic.h points at uSHET's license without carrying it.
            f"{RAW}/18sg/uSHET/c09e0acafd86720efe42dc15c63e0cc228244c32/LICENSE",
            f"{RAW}/apple/swift-nio/2.42.0/Sources/CNIOSHA1/c_nio_sha1.c{HEADER}",
        ),
    ),
    Component(
        "SwiftNIO HTTP/2",
        "1.26.0",
        "Apache-2.0",
        "https://github.com/apple/swift-nio-http2",
        (
            f"{RAW}/apple/swift-nio-http2/1.26.0/LICENSE.txt",
            f"{RAW}/apple/swift-nio-http2/1.26.0/NOTICE.txt",
        ),
    ),
    Component(
        "SwiftNIO Transport Services",
        "1.15.0",
        "Apache-2.0",
        "https://github.com/apple/swift-nio-transport-services",
        (f"{RAW}/apple/swift-nio-transport-services/1.15.0/LICENSE.txt",),
    ),
    Component(
        "SwiftNIO Extras",
        "1.4.0",
        "Apache-2.0",
        "https://github.com/apple/swift-nio-extras",
        (
            f"{RAW}/apple/swift-nio-extras/1.4.0/LICENSE.txt",
            f"{RAW}/apple/swift-nio-extras/1.4.0/NOTICE.txt",
        ),
    ),
    Component(
        "SwiftNIO SSL (includes BoringSSL)",
        "2.23.0",
        "Apache-2.0 AND OpenSSL AND ISC",
        "https://github.com/apple/swift-nio-ssl",
        (
            f"{RAW}/apple/swift-nio-ssl/2.23.0/LICENSE.txt",
            f"{RAW}/apple/swift-nio-ssl/2.23.0/NOTICE.txt",
            # BoringSSL revision vendored by swift-nio-ssl 2.23.0 (Sources/CNIOBoringSSL/hash.txt)
            f"{RAW}/google/boringssl/b819f7e9392d25db6705a6bd3c92be3bb91775e2/LICENSE",
        ),
    ),
    Component(
        "Swift Logging API",
        "1.4.4",
        "Apache-2.0",
        "https://github.com/apple/swift-log",
        (
            f"{RAW}/apple/swift-log/1.4.4/LICENSE.txt",
            f"{RAW}/apple/swift-log/1.4.4/NOTICE.txt",
        ),
    ),
    Component(
        "Swift Collections",
        "1.0.4",
        "Apache-2.0 WITH Swift-exception",
        "https://github.com/apple/swift-collections",
        (f"{RAW}/apple/swift-collections/1.0.4/LICENSE.txt",),
    ),
    Component(
        "Swift Atomics",
        "1.1.0",
        "Apache-2.0 WITH Swift-exception",
        "https://github.com/apple/swift-atomics",
        (f"{RAW}/apple/swift-atomics/1.1.0/LICENSE.txt",),
    ),
)

# Packages whose wheel and sdist ship no license file: take it from the upstream repository instead.
# `{version}` is filled from uv.lock so a version bump follows the matching upstream tag.
LICENSE_OVERRIDES: dict[str, tuple[str, ...]] = {}

# Names inside a wheel's .dist-info (or sdist root) that hold license/notice text.
_LICENSE_NAME = re.compile(
    r"(?i)^(licen[cs]e|copying|notice|authors|copyright)([._-].*)?$"
)
_MARKER_ENV = {
    "sys_platform": "darwin",
    "platform_machine": "arm64",
    "platform_python_implementation": "CPython",
    "implementation_name": "cpython",
}
_RULE = "=" * 100


# ---------------------------------------------------------------------------- lockfile


def _marker_applies(marker: str | None) -> bool:
    """Evaluate the small subset of PEP 508 markers uv writes for this (macOS-only) lockfile."""
    if not marker:
        return True
    expr = marker
    for var, value in _MARKER_ENV.items():
        expr = expr.replace(var, repr(value))
    if re.search(r"[a-z_]+_version|<|>|\bin\b", expr):
        raise ValueError(
            f"unsupported marker in uv.lock (extend _marker_applies): {marker}"
        )
    # Literal-only expression: every variable was substituted above.
    return bool(eval(expr, {"__builtins__": {}}, {}))


def runtime_packages(lockfile: Path = LOCKFILE) -> list[dict]:
    """Every package in the lock reachable from garage-rag's non-optional dependencies."""
    lock = tomllib.loads(lockfile.read_text())
    by_name = {p["name"]: p for p in lock["package"]}
    seen: set[str] = set()
    queue: list[tuple[str, tuple[str, ...]]] = [(ROOT_PACKAGE, ())]
    while queue:
        name, extras = queue.pop()
        pkg = by_name[name]
        first_visit = name not in seen
        seen.add(name)
        deps = list(pkg.get("dependencies", [])) if first_visit else []
        for extra in extras:
            deps += pkg.get("optional-dependencies", {}).get(extra, [])
        for dep in deps:
            if _marker_applies(dep.get("marker")):
                queue.append((dep["name"], tuple(dep.get("extra", ()))))
    seen.discard(ROOT_PACKAGE)
    return sorted((by_name[n] for n in seen), key=lambda p: p["name"])


def expected_entries(lockfile: Path = LOCKFILE) -> list[str]:
    """`name version` lines the notices index must contain, in order."""
    return [f"{p['name']} {p['version']}" for p in runtime_packages(lockfile)] + [
        f"{c.name} {c.version}" for c in NATIVE_COMPONENTS
    ]


# ---------------------------------------------------------------------------- fetching


def _get(url: str, attempts: int = 4) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "garage-rag-notices"})
    for attempt in range(attempts):
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                return resp.read()
        except (TimeoutError, urllib.error.URLError):
            if attempt == attempts - 1:
                raise
            time.sleep(2**attempt)
    raise AssertionError("unreachable")


def _pick_wheel(pkg: dict) -> str | None:
    wheels = [w["url"] for w in pkg.get("wheels", [])]
    for pref in ("none-any", "macosx", ""):
        for url in wheels:
            if pref in url:
                return url
    return None


def _python_license_texts(pkg: dict) -> list[tuple[str, str]]:
    """License files from the package's wheel .dist-info, falling back to the sdist root."""
    texts: list[tuple[str, str]] = []
    if url := _pick_wheel(pkg):
        with zipfile.ZipFile(io.BytesIO(_get(url))) as zf:
            for info in sorted(zf.namelist()):
                parts = info.split("/")
                in_dist_info = len(parts) >= 2 and parts[0].endswith(".dist-info")
                if in_dist_info and not info.endswith("/"):
                    under_licenses = len(parts) > 2 and parts[1] == "licenses"
                    if under_licenses or _LICENSE_NAME.match(parts[-1]):
                        texts.append(
                            (
                                "/".join(parts[1:]),
                                zf.read(info).decode("utf-8", "replace"),
                            )
                        )
    if not texts and "sdist" in pkg:
        with tarfile.open(fileobj=io.BytesIO(_get(pkg["sdist"]["url"]))) as tf:
            for member in sorted(tf.getmembers(), key=lambda m: m.name):
                parts = member.name.split("/")
                if (
                    member.isfile()
                    and len(parts) == 2
                    and _LICENSE_NAME.match(parts[1])
                ):
                    fh = tf.extractfile(member)
                    if fh:
                        texts.append((parts[1], fh.read().decode("utf-8", "replace")))
    return texts


def _license_expression(pkg: dict) -> str:
    try:
        info = json.loads(
            _get(f"https://pypi.org/pypi/{pkg['name']}/{pkg['version']}/json")
        )["info"]
    except Exception:  # noqa: BLE001 - metadata is a nicety; the texts are what matter
        return "see license text"
    if expr := info.get("license_expression"):
        return expr
    classifiers = [
        c.split("::")[-1].strip()
        for c in info.get("classifiers", [])
        if c.startswith("License ::")
    ]
    if classifiers:
        return " / ".join(classifiers)
    lic = (info.get("license") or "").strip()
    return lic if lic and "\n" not in lic and len(lic) < 60 else "see license text"


def _fetch_license(url: str) -> tuple[str, str]:
    """(file name, text) for a license URL; a HEADER URL keeps the source's license comment."""
    fetch_url, _, fragment = url.partition("#")
    name = fetch_url.rsplit("/", 1)[-1]
    text = _get(fetch_url).decode("utf-8", "replace")
    if f"#{fragment}" == HEADER:
        return f"{name} (license header)", _license_comment(text)
    return name, text


def _license_comment(source: str) -> str:
    """The C-style block comment that holds a source file's copyright and license terms."""
    for match in re.finditer(r"/\*.*?\*/", source, re.DOTALL):
        if "Copyright" in match.group(0):
            return match.group(0)
    raise SystemExit("no copyright comment found in license-header source")


# ---------------------------------------------------------------------------- rendering


def _section(title: str, meta: list[str], texts: list[tuple[str, str]]) -> str:
    out = [_RULE, title, *meta, _RULE, ""]
    for fname, text in texts:
        out += [f"--- {fname} ---", "", text.strip("\n"), ""]
    return "\n".join(out) + "\n"


def generate() -> str:
    packages = runtime_packages()
    index = expected_entries()
    header = [
        "THIRD-PARTY SOFTWARE NOTICES AND INFORMATION",
        "",
        "Garage includes the third-party software listed below. Each component is licensed by its",
        "authors under the terms reproduced in this file. Garage itself is licensed under the MIT",
        "License (see LICENSE).",
        "",
        "Source code for the GPL- and LGPL-licensed components is available from the upstream",
        "projects linked below. The Python packages are shipped as their own source; the source of",
        "GNU libiconv is at https://ftp.gnu.org/pub/gnu/libiconv/, and the author will provide the",
        "version bundled in this build on request through https://github.com/rickmark/garage-rag.",
        "",
        "This file is generated by tools/third_party_notices.py; do not edit it by hand.",
        "",
        "Components:",
        "",
        *(f"  {line}" for line in index),
        "",
    ]
    sections: list[str] = []
    missing: list[str] = []
    for pkg in packages:
        print(f"python  {pkg['name']} {pkg['version']}", file=sys.stderr)
        if override := LICENSE_OVERRIDES.get(pkg["name"]):
            urls = [url.format(version=pkg["version"]) for url in override]
            texts = [
                (url.rsplit("/", 1)[-1], _get(url).decode("utf-8", "replace"))
                for url in urls
            ]
        else:
            texts = _python_license_texts(pkg)
        if not texts:
            missing.append(f"{pkg['name']} {pkg['version']}")
            continue
        sections.append(
            _section(
                f"{pkg['name']} {pkg['version']}",
                [
                    f"License: {_license_expression(pkg)}",
                    f"Homepage: https://pypi.org/project/{pkg['name']}/",
                ],
                texts,
            )
        )
    if missing:
        raise SystemExit(
            f"no license file shipped for {', '.join(missing)}; add them to LICENSE_OVERRIDES"
        )
    for comp in NATIVE_COMPONENTS:
        print(f"native  {comp.name} {comp.version}", file=sys.stderr)
        texts = [_fetch_license(url) for url in comp.license_urls]
        for (_, text), url in zip(texts, comp.license_urls, strict=True):
            if len(text) < 200:  # e.g. a git symlink served as its target path
                raise SystemExit(
                    f"{comp.name}: {url} does not look like a license text: {text!r}"
                )
        sections.append(
            _section(
                f"{comp.name} {comp.version}",
                [f"License: {comp.license}", f"Homepage: {comp.homepage}"],
                texts,
            )
        )
    return "\n".join(header) + "\n" + "\n".join(sections)


def indexed_entries(notices: str) -> list[str]:
    """The component index at the top of a generated notices file."""
    _, _, rest = notices.partition("Components:\n\n")
    return [
        line.strip() for line in rest.split("\n\n", 1)[0].splitlines() if line.strip()
    ]


def check(notices_path: Path = OUTPUT, lockfile: Path = LOCKFILE) -> list[str]:
    """Human-readable problems with the committed notices file (empty when up to date)."""
    if not notices_path.exists():
        return [f"{notices_path} is missing"]
    have = indexed_entries(notices_path.read_text())
    want = expected_entries(lockfile)
    problems = [f"missing from notices: {e}" for e in want if e not in have]
    problems += [f"stale entry in notices: {e}" for e in have if e not in want]
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify the committed file offline instead of writing",
    )
    parser.add_argument("--notices", type=Path, default=OUTPUT)
    parser.add_argument("--lockfile", type=Path, default=LOCKFILE)
    args = parser.parse_args()

    if args.check:
        problems = check(args.notices, args.lockfile)
        for p in problems:
            print(p, file=sys.stderr)
        if problems:
            print(
                "run `python3 tools/third_party_notices.py` and commit the result",
                file=sys.stderr,
            )
        return 1 if problems else 0

    args.notices.parent.mkdir(parents=True, exist_ok=True)
    args.notices.write_text(generate())
    print(f"wrote {args.notices}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
