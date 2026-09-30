"""Authorship from git history.

The obvious implementation -- ``git log --follow`` per file -- is unusable here:
across ~18k tracked documents in 60 repositories it means 18k history walks. Instead
this walks each repository's history **once**, collecting every commit with its touched
paths, and builds a path -> authors map in memory.

The tradeoff is ``--no-renames``: following renames requires per-file history. A
renamed file is attributed from the commits that touched its current path, which
in practice still identifies the right person.

History is read in-process through libgit2; no ``git`` command is ever run, so no
Command Line Tools are needed. In the app that is ``_garage_git``, a built-in module of
its Python with libgit2 linked in statically (``//ext/python``, ``//ext/libgit2``), so
nothing is loaded at run time. Elsewhere (a venv, a PyPI install) it is pygit2 when it
is installed (the ``git`` extra). With neither, git attribution is skipped.
``tests/test_git_history.py`` holds both to what ``git log`` itself reports.
"""

from __future__ import annotations

import logging
from collections import defaultdict
from collections.abc import Callable
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path
from types import ModuleType
from typing import Protocol
from urllib.parse import urlsplit

log = logging.getLogger(__name__)


@dataclass
class AuthorTally:
    """How much one identity contributed to one file."""

    name: str
    email: str
    commits: int = 0


@dataclass
class RepoAttribution:
    """Everything one ``git log`` pass learned about a repository."""

    root: Path
    remote: str | None = None
    # repo-relative POSIX path -> identity key -> tally
    by_path: dict[str, dict[tuple[str, str], AuthorTally]] = field(default_factory=dict)
    commit_count: int = 0

    def authors_for(self, relative_path: str) -> list[AuthorTally]:
        """Contributors to one file, most commits first."""
        tallies = self.by_path.get(relative_path)
        if not tallies:
            return []
        return sorted(tallies.values(), key=lambda t: (-t.commits, t.name))


def find_repo_root(path: Path) -> Path | None:
    """Nearest enclosing git repository root, or None."""
    current = path if path.is_dir() else path.parent
    for candidate in [current, *current.parents]:
        if (candidate / ".git").exists():
            return candidate
    return None


class GitReader(Protocol):
    """The three reads git attribution makes. ``_garage_git`` implements them in C."""

    GitError: type[Exception]

    def commit_paths(self, path: Path, max_commits: int | None = None) -> list[tuple[str, str, list[str]]]: ...

    def remote_url(self, path: Path, name: str = "origin") -> str | None: ...

    def index_entry_count(self, path: Path) -> int: ...


class _Pygit2Reader:
    """:class:`GitReader` over pygit2, for a Python without ``_garage_git``."""

    def __init__(self, pygit2: ModuleType) -> None:
        self._pygit2 = pygit2
        self.GitError = pygit2.GitError

    def commit_paths(self, path: Path, max_commits: int | None = None) -> list[tuple[str, str, list[str]]]:
        pygit2 = self._pygit2
        repo = pygit2.Repository(str(path))
        if repo.head_is_unborn:
            return []
        mailmap = pygit2.Mailmap.from_repository(repo)
        commits: list[tuple[str, str, list[str]]] = []
        for commit in repo.walk(repo.head.target, pygit2.enums.SortMode.TIME):
            if max_commits is not None and len(commits) >= max_commits:
                break
            if len(commit.parent_ids) > 1:
                continue
            author = mailmap.resolve_signature(commit.author)
            if commit.parent_ids:
                diff = repo.diff(commit.parents[0].tree, commit.tree)
            else:
                diff = commit.tree.diff_to_tree(swap=True)
            paths = [_decode(delta.new_file.raw_path or delta.old_file.raw_path) for delta in diff.deltas]
            commits.append((_decode(author.raw_name), _decode(author.raw_email), paths))
        return commits

    def remote_url(self, path: Path, name: str = "origin") -> str | None:
        repo = self._pygit2.Repository(str(path))
        try:
            return repo.remotes[name].url or None
        except (KeyError, ValueError):
            return None

    def index_entry_count(self, path: Path) -> int:
        return len(self._pygit2.Repository(str(path)).index)


def _decode(raw: bytes | None) -> str:
    return raw.decode("utf-8", errors="replace") if raw else ""


@lru_cache(maxsize=1)
def git_reader() -> GitReader | None:
    """How this Python reads git history: ``_garage_git``, else pygit2, else None."""
    try:
        # Built into the app's Python.
        # gazelle:ignore _garage_git
        import _garage_git

        return _garage_git
    except ImportError:
        pass
    try:
        # The `git` extra, never bundled in the app.
        # gazelle:ignore pygit2
        import pygit2
    except ImportError:
        log.info("neither _garage_git nor pygit2 is available; skipping git attribution")
        return None
    return _Pygit2Reader(pygit2)


def _read[T](root: Path, what: str, read: Callable[[GitReader], T]) -> T | None:
    reader = git_reader()
    if reader is None:
        return None
    try:
        return read(reader)
    except (reader.GitError, OSError) as exc:
        log.debug("could not read %s of %s: %s", what, root, exc)
        return None


def repo_remote(root: Path) -> str | None:
    return _read(root, "the origin remote", lambda reader: reader.remote_url(root, "origin"))


def count_tracked_files(root: Path) -> int | None:
    """Tracked files (``git ls-files``), or None when ``root`` is not a git work tree or git can't be read."""
    return _read(root, "the index", lambda reader: reader.index_entry_count(root))


def load_repo_attribution(root: Path, *, max_commits: int | None = None) -> RepoAttribution:
    """Single-pass authorship extraction for one repository."""
    attribution = RepoAttribution(root=root, remote=repo_remote(root))

    commits = _read(root, "the history", lambda reader: reader.commit_paths(root, max_commits))
    if commits is None:
        return attribution

    by_path: dict[str, dict[tuple[str, str], AuthorTally]] = defaultdict(dict)
    for name, email, paths in commits:
        if not name:
            continue
        key = (name, email.lower())
        for path in paths:
            tallies = by_path[path]
            tally = tallies.get(key)
            if tally is None:
                tallies[key] = AuthorTally(name=name, email=email, commits=1)
            else:
                tally.commits += 1

    attribution.by_path = dict(by_path)
    attribution.commit_count = len(commits)
    log.debug("%s: %d commits, %d tracked paths", root.name, commits, len(attribution.by_path))
    return attribution


@lru_cache(maxsize=128)
def cached_repo_attribution(root_str: str, max_commits: int | None = None) -> RepoAttribution:
    """Memoized per-repository attribution.

    A walk visits thousands of files per repository; without this the history would be
    re-read for each one. Keyed on a string so the cache key is exactly
    the path as given, with no ``Path`` normalization or platform flavor in it.
    """
    return load_repo_attribution(Path(root_str), max_commits=max_commits)


def relative_posix(root: Path, path: Path) -> str | None:
    """Path relative to ``root`` in the form git reports."""
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        return None


def remote_owner(remote: str | None) -> str | None:
    """Owner segment of a git remote URL, for third-party detection.

    Handles URL forms (``https://host/owner/repo``, ``ssh://git@host:22/owner/repo``),
    scp-style ``git@host:owner/repo.git``, and bare ``host/owner/repo``.
    """
    if not remote:
        return None
    cleaned = remote.removesuffix(".git")
    if "://" in cleaned:
        # A real URL: let urlsplit take the userinfo/host/port apart, since a
        # port makes the naive "colon after @" test misread ssh:// remotes.
        tail = urlsplit(cleaned).path
    elif "@" in cleaned and ":" in cleaned.split("@", 1)[1]:
        # scp-style: git@github.com:owner/repo
        tail = cleaned.split(":", 1)[1]
    else:
        tail = cleaned.split("/", 1)[1] if "/" in cleaned else cleaned
    segments = [segment for segment in tail.split("/") if segment]
    return segments[0] if segments else None
