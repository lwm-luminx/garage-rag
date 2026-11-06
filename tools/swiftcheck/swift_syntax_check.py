#!/usr/bin/env python3
"""Syntax-check Swift sources without a Swift toolchain.

Parses every ``.swift`` file with the tree-sitter Swift grammar and reports the
``ERROR`` and ``MISSING`` nodes the parser had to insert. It knows nothing about
types or modules, so it never replaces ``swiftc``, but it catches what a text
diff review cannot: unbalanced braces, malformed closures and attributes, bad
string interpolation, stray tokens. Meant for environments (Linux CI helpers,
Claude Code on the web) where the macOS toolchain is unavailable.

    python tools/swiftcheck/swift_syntax_check.py [PATH ...]   # default: macapp
    python tools/swiftcheck/swift_syntax_check.py --update-baseline

Constructs the grammar cannot parse but swiftc accepts are listed in baseline.txt
next to this script and ignored; anything not in it fails the check.

Exit status is 1 when any file has a syntax error. Requires ``tree-sitter`` and
``tree-sitter-swift`` (``uv pip install tree-sitter tree-sitter-swift``).
"""

from __future__ import annotations

import sys
from pathlib import Path

try:
    import tree_sitter_swift
    from tree_sitter import Language, Node, Parser
except ImportError as exc:  # pragma: no cover - environment dependent
    sys.stderr.write(f"swift_syntax_check: {exc}\nInstall with: uv pip install tree-sitter tree-sitter-swift\n")
    sys.exit(2)

REPO_ROOT = Path(__file__).resolve().parents[2]


def iter_swift_files(paths: list[str]) -> list[Path]:
    roots = [Path(p) for p in paths] or [REPO_ROOT / "macapp"]
    files: list[Path] = []
    for root in roots:
        if root.is_file():
            files.append(root)
        else:
            files.extend(sorted(p for p in root.rglob("*.swift") if ".build" not in p.parts))
    return files


def error_nodes(node: Node) -> list[Node]:
    """Innermost parser error nodes, in source order.

    An ``ERROR`` node that itself contains ``ERROR``/``MISSING`` descendants is
    only a wrapper the parser opened while recovering; reporting the innermost
    ones points at the construct that actually failed to parse.
    """
    found: list[Node] = []
    stack = [node]
    while stack:
        current = stack.pop()
        if current.is_missing:
            found.append(current)
            continue
        inner = [c for c in current.children if c.has_error or c.is_missing]
        if current.type == "ERROR" and not inner:
            found.append(current)
            continue
        stack.extend(reversed(inner))
    found.sort(key=lambda n: n.start_byte)
    return found


def describe(source: bytes, node: Node) -> str:
    line, col = node.start_point
    if node.is_missing:
        return f"{line + 1}:{col + 1}: missing {node.type!r}"
    snippet = source[node.start_byte : node.end_byte].decode("utf-8", "replace").strip().splitlines()
    head = snippet[0][:80] if snippet else ""
    return f"{line + 1}:{col + 1}: unexpected {head!r}"


BASELINE = Path(__file__).with_name("baseline.txt")


def load_baseline() -> set[str]:
    """Known grammar gaps: valid Swift the tree-sitter grammar cannot parse.

    Entries are ``path: line:col: message`` exactly as this script prints them,
    minus the line number, so a construct that moves a few lines stays known
    while a new problem in the same file still fails the check.
    """
    if not BASELINE.exists():
        return set()
    return {line.strip() for line in BASELINE.read_text().splitlines() if line.strip() and not line.startswith("#")}


def baseline_key(rel: Path, message: str) -> str:
    # "12:34: unexpected 'x'" -> ":34: unexpected 'x'" (drop the line number)
    return f"{rel}: {message.split(':', 1)[1]}"


def main(argv: list[str]) -> int:
    update_baseline = "--update-baseline" in argv
    paths = [a for a in argv if not a.startswith("--")]
    parser = Parser(Language(tree_sitter_swift.language()))
    files = iter_swift_files(paths)
    known = set() if update_baseline else load_baseline()
    new_keys: set[str] = set()
    failures = 0
    suppressed = 0
    for path in files:
        source = path.read_bytes()
        tree = parser.parse(source)
        problems = error_nodes(tree.root_node)
        if not problems:
            continue
        rel = path.relative_to(REPO_ROOT) if path.is_relative_to(REPO_ROOT) else path
        messages = [describe(source, node) for node in problems]
        fresh = [m for m in messages if baseline_key(rel, m) not in known]
        suppressed += len(messages) - len(fresh)
        new_keys.update(baseline_key(rel, m) for m in messages)
        if not fresh:
            continue
        failures += 1
        print(f"{rel}: {len(fresh)} syntax problem(s)")
        for message in fresh[:10]:
            print(f"  {message}")
        if len(fresh) > 10:
            print(f"  ... {len(fresh) - 10} more")
    if update_baseline:
        header = (
            "# Known tree-sitter-swift grammar gaps (valid Swift it cannot parse). One entry per\n"
            "# construct: 'path: :col: message'. Regenerate with --update-baseline after verifying\n"
            "# each entry compiles with swiftc.\n"
        )
        BASELINE.write_text(header + "\n".join(sorted(new_keys)) + ("\n" if new_keys else ""))
        print(f"wrote {BASELINE.relative_to(REPO_ROOT)} with {len(new_keys)} entries")
        return 0
    note = f", {suppressed} known grammar gap(s) ignored" if suppressed else ""
    print(f"checked {len(files)} file(s), {failures} with syntax errors{note}")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
