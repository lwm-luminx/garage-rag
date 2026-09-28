"""Authorship from git history.

The obvious implementation -- ``git log --follow`` per file -- is unusable here:
across ~18k tracked documents in 60 repositories it means 18k git invocations,
each walking history. Instead this runs **one** ``git log`` per repository,
streaming every commit with its touched paths, and builds a path -> authors map
in memory. Sixty subprocesses instead of eighteen thousand.

The tradeoff is ``--no-renames``: following renames requires per-file history. A
renamed file is attributed from the commits that touched its current path, which
in practice still identifies the right person.
"""

from __future__ import annotations

import logging
import shutil
import subprocess
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path
from urllib.parse import urlsplit

log = logging.getLogger(__name__)

# Record separators chosen to not occur in names or email addresses.
_COMMIT_MARK = "\x01"
_FIELD_SEP = "\x1f"

_GIT_TIMEOUT = 300.0

# macOS ships /usr/bin/git as a stub. Without the Command Line Tools or Xcode, running it opens
# the "install the command line developer tools" dialog, once per call, and then fails.
_MACOS_GIT_STUB = "/usr/bin/git"


@lru_cache(maxsize=1)
def git_executable() -> str | None:
    """The git binary to run, or None when there is none that works without a prompt.

    On macOS the stub at ``/usr/bin/git`` counts only when ``xcode-select -p`` names a developer
    folder that exists. That check never prompts, so an XPC service on a Mac without the
    developer tools skips git attribution quietly instead of opening the install dialog.
    """
    found = shutil.which("git")
    if found is None:
        log.info("git not found; skipping git attribution")
        return None
    if sys.platform == "darwin" and Path(found).resolve() == Path(_MACOS_GIT_STUB) and not _has_developer_dir():
        log.info("git needs the Xcode Command Line Tools, which are not installed; skipping git attribution")
        return None
    return found


def _has_developer_dir() -> bool:
    try:
        result = subprocess.run(  # noqa: S603 - fixed argv, no shell
            ["/usr/bin/xcode-select", "-p"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return False
    path = result.stdout.strip()
    return result.returncode == 0 and bool(path) and Path(path).is_dir()


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


# Settings that stop a repository's own configuration from running code when Garage reads it. A
# checkout is user-chosen data, and ``.git/config`` may name a ``core.fsmonitor`` command that git
# would start; passing the override on the command line wins over every config file.
GIT_HARDENING: tuple[str, ...] = ("-c", "core.fsmonitor=false")


def _run_git(args: list[str], cwd: Path, *, timeout: float = _GIT_TIMEOUT) -> str | None:
    git = git_executable()
    if git is None:
        return None
    try:
        result = subprocess.run(  # noqa: S603 - fixed argv, no shell
            [git, *GIT_HARDENING, *args],
            cwd=cwd,
            capture_output=True,
            text=True,
            errors="replace",
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        log.warning("git %s failed in %s: %s", args[0], cwd, exc)
        return None
    if result.returncode != 0:
        log.debug("git %s returned %d in %s", args[0], result.returncode, cwd)
        return None
    return result.stdout


def find_repo_root(path: Path) -> Path | None:
    """Nearest enclosing git repository root, or None."""
    current = path if path.is_dir() else path.parent
    for candidate in [current, *current.parents]:
        if (candidate / ".git").exists():
            return candidate
    return None


def repo_remote(root: Path) -> str | None:
    out = _run_git(["remote", "get-url", "origin"], root, timeout=15.0)
    return out.strip() if out and out.strip() else None


def load_repo_attribution(root: Path, *, max_commits: int | None = None) -> RepoAttribution:
    """Single-pass authorship extraction for one repository."""
    attribution = RepoAttribution(root=root, remote=repo_remote(root))

    args = [
        # quotepath=false keeps non-ASCII filenames literal instead of escaped.
        "-c",
        "core.quotepath=false",
        "log",
        f"--format={_COMMIT_MARK}%aN{_FIELD_SEP}%aE",
        "--name-only",
        # Renames would need per-file history; see module docstring.
        "--no-renames",
        # Merges restate their parents' paths and would double-count.
        "--no-merges",
    ]
    if max_commits:
        args.append(f"--max-count={max_commits}")

    output = _run_git(args, root)
    if output is None:
        return attribution

    by_path: dict[str, dict[tuple[str, str], AuthorTally]] = defaultdict(dict)
    name = email = ""
    commits = 0

    for line in output.split("\n"):
        if not line:
            continue
        if line.startswith(_COMMIT_MARK):
            payload = line[1:]
            name, _, email = payload.partition(_FIELD_SEP)
            commits += 1
            continue
        if not name:
            continue

        key = (name, email.lower())
        tallies = by_path[line]
        tally = tallies.get(key)
        if tally is None:
            tallies[key] = AuthorTally(name=name, email=email, commits=1)
        else:
            tally.commits += 1

    attribution.by_path = dict(by_path)
    attribution.commit_count = commits
    log.debug("%s: %d commits, %d tracked paths", root.name, commits, len(attribution.by_path))
    return attribution


@lru_cache(maxsize=128)
def cached_repo_attribution(root_str: str, max_commits: int | None = None) -> RepoAttribution:
    """Memoized per-repository attribution.

    A walk visits thousands of files per repository; without this the ``git log``
    would be re-run for each one. Keyed on a string so the cache key is exactly
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
