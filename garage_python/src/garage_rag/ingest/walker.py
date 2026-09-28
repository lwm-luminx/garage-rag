"""Filesystem discovery.

The walk is deliberately cheap: it stats each candidate once and yields a small
record, without opening anything. Opening files is where cost lives -- parsing,
and for cloud placeholders, downloading -- so the decision about whether a file
is worth opening is made entirely from its name, size, and stat.
"""

from __future__ import annotations

import fnmatch
import logging
import os
import stat
from collections.abc import Iterator
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from garage_rag.config import (
    DEFAULT_EXCLUDE_DIRS,
    DEPENDENCY_PATH_FRAGMENTS,
    DIAGNOSTIC_DIR_PATTERNS,
    DIAGNOSTIC_FILE_PATTERNS,
    expand_home,
    get_settings,
)
from garage_rag.extract.dispatch import is_indexable
from garage_rag.extract.placeholder import is_placeholder
from garage_rag.ingest.classify import is_code_path

log = logging.getLogger(__name__)


class SourceUnavailable(OSError):
    """The source root cannot be walked: it is missing, or this process may not read it.

    Raised by the pipeline instead of reporting a run that saw nothing as complete, which
    would read as "up to date" in the app and the CLI.
    """


def root_problem(root: Path) -> str | None:
    """Why ``root`` cannot be walked, or None when it can.

    A missing root and one this process may not list are told apart, because the remedy
    differs: the sandboxed App Store build reads only folders the user granted, so
    "permission denied" there means the grant did not reach this process.
    """
    try:
        st = root.stat()
    except FileNotFoundError:
        return f"path does not exist: {root}"
    except PermissionError:
        return f"not readable: {root} (permission denied; this process has no access to it)"
    except OSError as exc:
        return f"not readable: {root} ({exc.strerror or exc})"
    if stat.S_ISDIR(st.st_mode):
        try:
            with os.scandir(root):
                pass
        except PermissionError:
            return f"not readable: {root} (permission denied; this process has no access to it)"
        except OSError as exc:
            return f"not readable: {root} ({exc.strerror or exc})"
    elif not os.access(root, os.R_OK):
        return f"not readable: {root} (permission denied; this process has no access to it)"
    return None


@dataclass
class Candidate:
    """One file the walker considers worth looking at."""

    path: Path
    size: int
    mtime: datetime
    placeholder: bool

    @property
    def uri(self) -> str:
        return str(self.path)


@dataclass
class WalkStats:
    """What a walk saw, for the run report."""

    dirs: int = 0
    files_seen: int = 0
    yielded: int = 0
    skipped_extension: int = 0
    skipped_excluded_dir: int = 0
    skipped_code: int = 0
    skipped_too_large: int = 0
    skipped_diagnostic: int = 0
    placeholders: int = 0
    unreadable: int = 0


def _matches_any(name: str, patterns: tuple[str, ...]) -> bool:
    lowered = name.lower()
    return any(fnmatch.fnmatch(lowered, pattern.lower()) for pattern in patterns)


def is_diagnostic_dir(name: str) -> bool:
    """Whether a directory is a machine-generated diagnostic bundle."""
    return _matches_any(name, DIAGNOSTIC_DIR_PATTERNS)


def is_diagnostic_file(name: str) -> bool:
    """Whether a filename is machine output regardless of its extension."""
    return _matches_any(name, DIAGNOSTIC_FILE_PATTERNS)


def is_dependency_path(path_str: str) -> bool:
    """Whether a path lies inside a package-manager cache.

    Matched on a fragment because the distinctive directory names ("mod",
    "registry") are far too generic to exclude by themselves.
    """
    lowered = path_str.replace("\\", "/").lower()
    return any(fragment.lower() in lowered for fragment in DEPENDENCY_PATH_FRAGMENTS)


def is_dependency_dir(path: Path, root: Path) -> bool:
    """Whether ``path`` is a package-manager cache below the source ``root``.

    Only the part below ``root`` is matched: the root itself may sit under such a
    path (Bazel's output base on macOS is ``~/Library/Caches/bazel``, and a user may
    add a source that lives in a cache on purpose), and pruning on an ancestor
    would silently index nothing at all.
    """
    try:
        relative = path.relative_to(root).as_posix()
    except ValueError:
        return False
    return relative != "." and is_dependency_path(f"/{relative}/")


def is_inside_git_dir(path: Path) -> bool:
    """Whether ``path`` is a ``.git`` directory or lies inside one.

    Checked on the source root, which the walk's pruning never sees: a source
    added at ``repo/.git`` (or below it) would otherwise index git's internals.
    """
    return any(part.lower() == ".git" for part in path.parts)


def is_git_dir(dirnames: list[str], filenames: list[str]) -> bool:
    """Whether a directory's listing is a git directory's: ``HEAD``, ``objects/`` and ``refs/``.

    Catches what pruning ``.git`` by name misses -- bare repositories and mirrors
    (``project.git``), and a root that is itself a git directory -- from the
    listing ``os.walk`` already made, without another stat.
    """
    return "HEAD" in filenames and "objects" in dirnames and "refs" in dirnames


def _is_hidden(name: str) -> bool:
    # Dotfiles are configuration or caches, not writing. The few exceptions
    # (dotfile repos) are not worth the noise of indexing every .DS_Store.
    return name.startswith(".")


def walk(
    root: Path,
    *,
    include_code: bool = False,
    exclude_prefixes: tuple[str, ...] = (),
    stats: WalkStats | None = None,
) -> Iterator[Candidate]:
    """Yield indexable files under ``root``.

    ``include_code`` gates source files specifically, so a source can be walked
    for documentation only -- which is the difference between ~18k documents and
    ~192k files in a tree full of checked-out repositories.
    """
    limit = get_settings().max_file_bytes
    tally = stats if stats is not None else WalkStats()
    root = expand_home(root)
    if is_inside_git_dir(root):
        log.info("Not walking %s: it is inside a git directory", root)
        return

    def on_error(exc: OSError) -> None:
        # Permission-denied on a subtree (TCC, or another user's files) should
        # not abort the walk.
        log.debug("walk error: %s", exc)
        tally.unreadable += 1

    for dirpath, dirnames, filenames in os.walk(root, onerror=on_error, followlinks=False):
        tally.dirs += 1
        current = Path(dirpath)

        # Git's own object store and refs, under whatever name: never writing.
        if is_git_dir(dirnames, filenames):
            log.debug("Walker pruning git directory: %s", dirpath)
            dirnames[:] = []
            tally.skipped_excluded_dir += 1
            continue

        # Whole dependency caches: stop descending entirely.
        if is_dependency_dir(current, root):
            log.debug("Walker pruning dependency path: %s", dirpath)
            dirnames[:] = []
            tally.skipped_excluded_dir += 1
            continue

        # Prune in place: os.walk honours mutation of dirnames, so excluded
        # subtrees are never descended into at all.
        kept: list[str] = []
        for name in dirnames:
            if name in DEFAULT_EXCLUDE_DIRS or _is_hidden(name):
                tally.skipped_excluded_dir += 1
                continue
            if is_diagnostic_dir(name):
                log.debug("Walker skipping diagnostic dir: %s", name)
                # Never descend: a sysdiagnose bundle holds thousands of files
                # and not one of them is writing.
                tally.skipped_diagnostic += 1
                continue
            kept.append(name)
        dirnames[:] = kept

        if exclude_prefixes:
            try:
                relative = current.relative_to(root).as_posix() + "/"
            except ValueError:
                relative = ""
            if relative and any(relative.startswith(p) for p in exclude_prefixes):
                log.debug("Walker skipping excluded prefix: %s", relative)
                dirnames[:] = []
                continue

        for name in filenames:
            tally.files_seen += 1
            if _is_hidden(name):
                continue

            if is_diagnostic_file(name):
                tally.skipped_diagnostic += 1
                continue

            path = current / name
            if not is_indexable(path):
                tally.skipped_extension += 1
                continue

            if not include_code and is_code_path(path):
                tally.skipped_code += 1
                continue

            try:
                st = path.stat()
            except OSError as err:
                log.debug("Walker failed to stat %s: %s", path, err)
                tally.unreadable += 1
                continue

            stub = is_placeholder(path, st=st)
            if stub:
                log.debug("Walker found cloud placeholder: %s", path)
                tally.placeholders += 1
            elif st.st_size == 0:
                continue
            elif st.st_size > limit:
                log.debug("Walker skipping oversized file (%d bytes > %d limit): %s", st.st_size, limit, path)
                tally.skipped_too_large += 1
                continue

            tally.yielded += 1
            yield Candidate(
                path=path,
                size=st.st_size,
                mtime=datetime.fromtimestamp(st.st_mtime, tz=UTC),
                placeholder=stub,
            )


def default_exclude_prefixes(root: Path) -> tuple[str, ...]:
    """Source-specific subtree exclusions.

    Dropbox keeps application bundles and binary objects in known top-level
    folders; walking them yields nothing but wasted stats and, worse, wasted
    materialization budget.
    """
    from garage_rag.attribute.pathrules import EXCLUDED_PREFIXES

    if root.name == "Dropbox" or (root / ".dropbox.device").exists():
        return EXCLUDED_PREFIXES
    return ()
