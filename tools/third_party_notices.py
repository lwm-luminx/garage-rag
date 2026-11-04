#!/usr/bin/env python3
"""Generate (or check) THIRD_PARTY_NOTICES.txt for everything the Garage app redistributes.

The app links every crate `rust/Cargo.lock` resolves for the libraries it ships (the CLI, the
backend, the ingest and embed workers, the MCP server), plus a from-source Postgres + pgvector +
Apache AGE (with ICU and zlib), llama.cpp, Tesseract + Leptonica, libgit2, Sparkle and the Swift
gRPC/NIO/protobuf runtime pulled in by rules_swift. Their licenses (MIT, BSD, Apache, Unicode,
LGPL, ...) require the license text to accompany binary redistribution, so this collects the actual
license files from each upstream release into one text file that ships in
`Garage.app/Contents/Resources`.

    # regenerate after changing rust/Cargo.lock or ext/ (needs network)
    python3 tools/third_party_notices.py

    # offline: fail if the committed file no longer covers the lockfile + NATIVE_COMPONENTS
    python3 tools/third_party_notices.py --check

Stdlib only, so it runs with any Python 3.11 or newer.
"""

from __future__ import annotations

import argparse
import io
import re
import sys
import tarfile
import time
import tomllib
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LOCKFILE = REPO / "rust" / "Cargo.lock"
OUTPUT = REPO / "data" / "notices" / "THIRD_PARTY_NOTICES.txt"
# The crates the app, the Windows app and the launchers link; every crate they reach in Cargo.lock
# is shipped. Cargo.lock does not tell a build or dev dependency from a normal one, so a few
# build-time crates are listed too, which is harmless.
SHIPPED_CRATES = (
    "garage-cli",
    "garage-service-ffi",
    "garage-ingest-ffi",
    "garage-embed-ffi",
    "garage-mcp-ffi",
)
CRATES_IO = "registry+https://github.com/rust-lang/crates.io-index"
RAW = "https://raw.githubusercontent.com"
# The standard text of a license a crate names but does not ship, by SPDX identifier.
SPDX_TEXT = f"{RAW}/spdx/license-list-data/v3.27.0/text/{{id}}.txt"
# Suffix for a source file whose license is only its header comment: keep just that comment.
HEADER = "#license-header"


@dataclass(frozen=True)
class Component:
    """A non-Rust component compiled into or bundled with the app."""

    name: str
    version: str
    license: str
    homepage: str
    # raw.githubusercontent.com (or other plain-text) URLs of the upstream license files
    license_urls: tuple[str, ...]


# Everything shipped that Cargo.lock does not cover: ext/*.MODULE.bazel, the swift_proto deps of
# rules_swift (MODULE.bazel), and third-party code reimplemented in the tree (see NOTICE).
# Components that are built but not shipped in the app are omitted.
NATIVE_COMPONENTS: tuple[Component, ...] = (
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
        "langchain-text-splitters (reimplemented in rust/garage-ingest/src/splitters.rs)",
        "1.1.2",
        "MIT",
        "https://github.com/langchain-ai/langchain",
        (f"{RAW}/langchain-ai/langchain/langchain-text-splitters%3D%3D1.1.2/LICENSE",),
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

# Crates whose package ships no license file, and whose `license` field is not one SPDX identifier
# the standard texts cover: the upstream repository's license files instead.
LICENSE_OVERRIDES: dict[str, tuple[str, ...]] = {}

# Names at a crate's root that hold license/notice text.
_LICENSE_NAME = re.compile(r"(?i)^(licen[cs]e|copying|notice|authors|copyright)([._-].*)?$")
_RULE = "=" * 100


# ---------------------------------------------------------------------------- lockfile


@dataclass(frozen=True)
class Crate:
    name: str
    version: str
    source: str | None


def shipped_crates(lockfile: Path = LOCKFILE) -> list[Crate]:
    """Every crates.io package in the lock reachable from the shipped crates, by name and version."""
    lock = tomllib.loads(lockfile.read_text())
    packages = lock["package"]
    by_name: dict[str, list[dict]] = {}
    for pkg in packages:
        by_name.setdefault(pkg["name"], []).append(pkg)

    def resolve(dep: str) -> dict:
        # "name", "name version" or "name version (source)".
        parts = dep.split(" ")
        candidates = by_name[parts[0]]
        if len(parts) > 1:
            candidates = [p for p in candidates if p["version"] == parts[1]]
        if len(candidates) != 1:
            raise ValueError(f"ambiguous dependency in Cargo.lock: {dep}")
        return candidates[0]

    seen: set[tuple[str, str]] = set()
    queue = [resolve(name) for name in SHIPPED_CRATES]
    while queue:
        pkg = queue.pop()
        key = (pkg["name"], pkg["version"])
        if key in seen:
            continue
        seen.add(key)
        queue.extend(resolve(dep) for dep in pkg.get("dependencies", []))
    crates = [
        Crate(pkg["name"], pkg["version"], pkg.get("source"))
        for pkg in packages
        if (pkg["name"], pkg["version"]) in seen and pkg.get("source")  # workspace members have none
    ]
    return sorted(crates, key=lambda c: (c.name, c.version))


def expected_entries(lockfile: Path = LOCKFILE) -> list[str]:
    """`name version` lines the notices index must contain, in order."""
    return [f"{c.name} {c.version}" for c in shipped_crates(lockfile)] + [
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


def _crate_package(crate: Crate) -> tuple[str, list[tuple[str, str]]]:
    """(license expression, license files at the crate's root) from its crates.io package."""
    if crate.source != CRATES_IO:
        raise SystemExit(
            f"{crate.name} {crate.version} does not come from crates.io ({crate.source}); add a LICENSE_OVERRIDES entry"
        )
    url = f"https://static.crates.io/crates/{crate.name}/{crate.name}-{crate.version}.crate"
    expression = "see license text"
    texts: list[tuple[str, str]] = []
    with tarfile.open(fileobj=io.BytesIO(_get(url)), mode="r:gz") as tf:
        for member in sorted(tf.getmembers(), key=lambda m: m.name):
            parts = member.name.split("/")
            if not member.isfile() or len(parts) != 2:
                continue
            if parts[1] == "Cargo.toml":
                fh = tf.extractfile(member)
                if fh:
                    manifest = tomllib.loads(fh.read().decode("utf-8", "replace"))
                    expression = manifest.get("package", {}).get("license") or expression
            elif _LICENSE_NAME.match(parts[1]):
                fh = tf.extractfile(member)
                if fh:
                    texts.append((parts[1], fh.read().decode("utf-8", "replace")))
    return expression, texts


def _spdx_ids(expression: str) -> list[str]:
    """The SPDX identifiers an expression names (`MIT OR Apache-2.0`, `MIT/Apache-2.0`, ...)."""
    ids = re.split(r"\s+(?:OR|AND|WITH)\s+|/", expression)
    return [i.strip("() ") for i in ids if i.strip("() ")]


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
    crates = shipped_crates()
    index = expected_entries()
    header = [
        "THIRD-PARTY SOFTWARE NOTICES AND INFORMATION",
        "",
        "Garage includes the third-party software listed below. Each component is licensed by its",
        "authors under the terms reproduced in this file. Garage itself is licensed under the MIT",
        "License (see LICENSE).",
        "",
        "The Rust crates are linked into Garage's binaries; each is listed with the license its",
        "package names and the license files it ships. A crate that ships none is covered by the",
        "standard text of its license, reproduced once at the end of this file. Source code for the",
        "GPL- and LGPL-licensed components is available from the upstream projects linked below.",
        "",
        "This file is generated by tools/third_party_notices.py; do not edit it by hand.",
        "",
        "Components:",
        "",
        *(f"  {line}" for line in index),
        "",
    ]
    sections: list[str] = []
    standard: dict[str, None] = {}
    for crate in crates:
        print(f"crate   {crate.name} {crate.version}", file=sys.stderr)
        if override := LICENSE_OVERRIDES.get(crate.name):
            expression = "see license text"
            texts = [_fetch_license(url.format(version=crate.version)) for url in override]
        else:
            expression, texts = _crate_package(crate)
        meta = [f"License: {expression}", f"Homepage: https://crates.io/crates/{crate.name}"]
        if not texts:
            ids = _spdx_ids(expression)
            if expression == "see license text" or not ids:
                raise SystemExit(
                    f"{crate.name} {crate.version} ships no license file and names no license; "
                    "add it to LICENSE_OVERRIDES"
                )
            for spdx in ids:
                standard[spdx] = None
            meta.append("License text: the standard text of " + " / ".join(ids) + " at the end of this file")
        sections.append(_section(f"{crate.name} {crate.version}", meta, texts))
    for comp in NATIVE_COMPONENTS:
        print(f"native  {comp.name} {comp.version}", file=sys.stderr)
        texts = [_fetch_license(url) for url in comp.license_urls]
        for (_, text), url in zip(texts, comp.license_urls, strict=True):
            if len(text) < 200:  # e.g. a git symlink served as its target path
                raise SystemExit(f"{comp.name}: {url} does not look like a license text: {text!r}")
        sections.append(
            _section(f"{comp.name} {comp.version}", [f"License: {comp.license}", f"Homepage: {comp.homepage}"], texts)
        )
    for spdx in sorted(standard):
        print(f"license {spdx}", file=sys.stderr)
        name, text = _fetch_license(SPDX_TEXT.format(id=spdx))
        if len(text) < 200:
            raise SystemExit(f"{spdx}: no standard text at {SPDX_TEXT.format(id=spdx)}")
        sections.append(
            _section(f"Standard license text: {spdx}", ["Source: https://spdx.org/licenses/"], [(name, text)])
        )
    return "\n".join(header) + "\n" + "\n".join(sections)


def indexed_entries(notices: str) -> list[str]:
    """The component index at the top of a generated notices file."""
    _, _, rest = notices.partition("Components:\n\n")
    return [line.strip() for line in rest.split("\n\n", 1)[0].splitlines() if line.strip()]


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
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="verify the committed file offline instead of writing")
    parser.add_argument("--notices", type=Path, default=OUTPUT)
    parser.add_argument("--lockfile", type=Path, default=LOCKFILE)
    args = parser.parse_args()

    if args.check:
        problems = check(args.notices, args.lockfile)
        for p in problems:
            print(p, file=sys.stderr)
        if problems:
            print("run `python3 tools/third_party_notices.py` and commit the result", file=sys.stderr)
        return 1 if problems else 0

    args.notices.parent.mkdir(parents=True, exist_ok=True)
    args.notices.write_text(generate())
    print(f"wrote {args.notices}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
