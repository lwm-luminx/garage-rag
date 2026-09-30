"""Both git readers report what ``git`` itself reports.

garage_rag.attribute.git reads history through ``_garage_git`` (built into the app's
Python, libgit2 linked statically) or pygit2 (elsewhere). Each test builds a repository
with ``git``, reads it through every reader this Python has, and compares with ``git log``,
``git remote get-url`` and ``git ls-files`` run on the same repository. A reader that is
not installed skips; CI compiles ``_garage_git`` as an ordinary extension to cover it
(``tools/garage_git/build_extension.sh``).
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

from garage_rag.attribute import git as git_mod

pytestmark = pytest.mark.skipif(shutil.which("git") is None, reason="needs git to build the fixture repository")

_ENV = {
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_COMMITTER_NAME": "Committer",
    "GIT_COMMITTER_EMAIL": "committer@example.com",
}


class _Repo:
    def __init__(self, root: Path) -> None:
        self.root = root
        self.clock = 1_700_000_000
        self.git("init", "-q", "-b", "main")

    def git(self, *args: str, env: dict[str, str] | None = None) -> None:
        subprocess.run(["git", *args], cwd=self.root, check=True, env={**os.environ, **_ENV, **(env or {})})

    def write(self, relative: str, text: str) -> None:
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self, author: str, email: str, message: str) -> None:
        self.clock += 60
        stamp = f"{self.clock} +0000"
        self.git("add", "-A")
        self.git(
            "commit",
            "-q",
            "--allow-empty",
            "-m",
            message,
            env={
                "GIT_AUTHOR_NAME": author,
                "GIT_AUTHOR_EMAIL": email,
                "GIT_AUTHOR_DATE": stamp,
                "GIT_COMMITTER_DATE": stamp,
            },
        )


def _reader(name: str) -> git_mod.GitReader:
    module = pytest.importorskip(name)
    return module if name == "_garage_git" else git_mod._Pygit2Reader(module)


@pytest.fixture(params=["_garage_git", "pygit2"])
def reader(request, monkeypatch) -> git_mod.GitReader:
    """Each reader in turn, installed as the one garage_rag.attribute.git uses."""
    # Only the repository's own configuration: no url.insteadOf or the like from the
    # environment, which git would apply and libgit2 does not see.
    for key, value in _ENV.items():
        if key.startswith("GIT_CONFIG"):
            monkeypatch.setenv(key, value)
    monkeypatch.delenv("GIT_CONFIG_COUNT", raising=False)
    chosen = _reader(request.param)
    monkeypatch.setattr(git_mod, "git_reader", lambda: chosen)
    return chosen


def _git(root: Path, *args: str) -> str:
    return subprocess.run(["git", *args], cwd=root, check=True, capture_output=True, text=True).stdout


def _git_log(root: Path, max_commits: int | None = None) -> list[tuple[str, str, list[str]]]:
    """What the readers must reproduce, from git itself."""
    args = [
        "-c",
        "core.quotepath=false",
        "log",
        "--format=\x01%aN\x1f%aE",
        "--name-only",
        "--no-renames",
        "--no-merges",
    ]
    if max_commits is not None:
        args.append(f"--max-count={max_commits}")
    commits: list[tuple[str, str, list[str]]] = []
    for line in _git(root, *args).splitlines():
        if line.startswith("\x01"):
            name, _, email = line[1:].partition("\x1f")
            commits.append((name, email, []))
        elif line:
            commits[-1][2].append(line)
    return commits


def _as_sets(commits):
    return [(name, email, sorted(paths)) for name, email, paths in commits]


@pytest.fixture
def history(tmp_path) -> _Repo:
    (tmp_path / "repo").mkdir()
    repo = _Repo(tmp_path / "repo")
    repo.write("README.md", "hello\n")
    repo.write("docs/guide.md", "guide\n")
    repo.commit("Ada Lovelace", "ada@example.com", "root")

    repo.write("docs/guide.md", "guide, longer\n")
    repo.write("docs/café notes.md", "non-ASCII path\n")
    repo.commit("Grace Hopper", "GRACE@Example.com", "notes")

    repo.git("checkout", "-q", "-b", "side")
    repo.write("src/side.py", "print('side')\n")
    repo.commit("Ada Lovelace", "ada@old.example.com", "side work")
    repo.git("checkout", "-q", "main")
    repo.write("src/main.py", "print('main')\n")
    repo.commit("Grace Hopper", "grace@example.com", "main work")
    repo.clock += 60
    stamp = f"{repo.clock} +0000"
    repo.git(
        "merge",
        "-q",
        "--no-ff",
        "-m",
        "merge side",
        "side",
        env={
            "GIT_AUTHOR_NAME": "Merger",
            "GIT_AUTHOR_EMAIL": "m@example.com",
            "GIT_AUTHOR_DATE": stamp,
            "GIT_COMMITTER_DATE": stamp,
        },
    )

    repo.git("mv", "src/side.py", "src/renamed.py")
    (repo.root / "README.md").unlink()
    repo.commit("Ada Lovelace", "ada@example.com", "rename and delete")
    repo.commit("Nobody", "nobody@example.com", "empty")

    # %aN/%aE apply .mailmap; libgit2 must too.
    repo.write(".mailmap", "Ada Lovelace <ada@example.com> <ada@old.example.com>\n")
    repo.commit("Ada Lovelace", "ada@example.com", "mailmap")
    repo.git("remote", "add", "origin", "git@github.com:someone/repo.git")
    return repo


def test_history_matches_git_log(history, reader):
    commits = reader.commit_paths(history.root)
    assert _as_sets(commits) == _as_sets(_git_log(history.root))
    assert len(commits) == 7, "every commit but the merge"
    attribution = git_mod.load_repo_attribution(history.root)
    assert attribution.commit_count == 7
    assert "src/renamed.py" in attribution.by_path and "src/side.py" in attribution.by_path, "no rename detection"
    tallies = [(t.name, t.email, t.commits) for t in attribution.authors_for("src/side.py")]
    assert tallies == [("Ada Lovelace", "ada@example.com", 2)], "mailmap applied"
    assert "docs/café notes.md" in attribution.by_path
    assert attribution.remote == "git@github.com:someone/repo.git"


@pytest.mark.parametrize("max_commits", [0, 1, 3, 6])
def test_max_commits_matches_git_log(history, reader, max_commits):
    commits = reader.commit_paths(history.root, max_commits)
    assert _as_sets(commits) == _as_sets(_git_log(history.root, max_commits))


def test_remote_and_tracked_files_match_git(history, reader):
    assert git_mod.repo_remote(history.root) == _git(history.root, "remote", "get-url", "origin").strip()
    tracked = len(_git(history.root, "ls-files", "-z").split("\0")) - 1
    assert git_mod.count_tracked_files(history.root) == tracked == 5


def test_a_repository_with_no_commits(tmp_path, reader):
    repo = _Repo(tmp_path)
    repo.write("a.txt", "a\n")
    repo.git("add", "a.txt")
    assert reader.commit_paths(tmp_path) == []
    assert git_mod.repo_remote(tmp_path) is None
    assert git_mod.count_tracked_files(tmp_path) == 1


def test_not_a_repository(tmp_path, reader):
    assert git_mod.count_tracked_files(tmp_path) is None
    assert git_mod.repo_remote(tmp_path) is None
    assert git_mod.load_repo_attribution(tmp_path).commit_count == 0


def test_no_reader_skips_git_attribution(history, monkeypatch):
    monkeypatch.setattr(git_mod, "git_reader", lambda: None)
    assert git_mod.load_repo_attribution(history.root).by_path == {}
    assert git_mod.count_tracked_files(history.root) is None
