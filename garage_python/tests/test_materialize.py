"""Placeholder materialization: timeouts must not pile up blocked reader threads."""

from __future__ import annotations

import threading
from pathlib import Path

import pytest

from garage_rag.ingest import materialize as mat


@pytest.fixture(autouse=True)
def _no_stalled_reads():
    mat._stalled_reads.clear()
    yield
    mat._stalled_reads.clear()


@pytest.fixture
def stalled_read(monkeypatch):
    """Make every read block until the test releases it."""
    release = threading.Event()

    def blocked(path: Path) -> int:
        release.wait(10)
        return 0

    monkeypatch.setattr(mat, "_force_read", blocked)
    yield release
    release.set()


def _budget(**overrides) -> mat.MaterializationBudget:
    return mat.MaterializationBudget(**{"enabled": True, "timeout_seconds": 0.05, **overrides})


def test_a_timed_out_read_runs_on_a_daemon_thread(tmp_path, stalled_read):
    budget = _budget()

    assert mat.materialize(tmp_path / "stub", budget) is False

    assert budget.failed == 1
    assert len(mat._stalled_reads) == 1
    # Interpreter shutdown does not wait for daemon threads.
    assert all(thread.daemon for thread in mat._stalled_reads)


def test_stalled_reads_are_bounded(tmp_path, stalled_read):
    budget = _budget()

    for index in range(mat.MAX_STALLED_READS + 3):
        mat.materialize(tmp_path / f"stub-{index}", budget)

    assert len(mat._stalled_reads) == mat.MAX_STALLED_READS
    assert budget.failed == mat.MAX_STALLED_READS
    assert budget.deferred == 3


def test_finished_reads_free_their_slot(tmp_path, stalled_read):
    budget = _budget()
    for index in range(mat.MAX_STALLED_READS):
        mat.materialize(tmp_path / f"stub-{index}", budget)

    stalled_read.set()
    for thread in list(mat._stalled_reads):
        thread.join(5)

    assert mat._stalled_count() == 0


def test_read_errors_count_as_failures(tmp_path):
    budget = _budget(timeout_seconds=5)

    # No such file: the read raises OSError on the reader thread, and it is reported here.
    assert mat.materialize(tmp_path / "missing", budget) is False
    assert budget.failed == 1
    assert not mat._stalled_reads


# --- the dataless-file policy -------------------------------------------------


class _FakeIOPolicy:
    """Stands in for libc's setiopolicy_np/getiopolicy_np, per thread like the real thing."""

    def __init__(self) -> None:
        self.policies: dict[int, int] = {}
        self.calls: list[tuple[int, int, int]] = []

    def get(self, iotype: int, scope: int) -> int:
        assert (iotype, scope) == (mat.IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, mat.IOPOL_SCOPE_THREAD)
        return self.policies.get(threading.get_ident(), mat.IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT)

    def set(self, iotype: int, scope: int, policy: int) -> int:
        self.calls.append((threading.get_ident(), scope, policy))
        self.policies[threading.get_ident()] = policy
        return 0


@pytest.fixture
def iopolicy(monkeypatch) -> _FakeIOPolicy:
    fake = _FakeIOPolicy()
    monkeypatch.setattr(mat, "_iopolicy", (fake.set, fake.get))
    return fake


def test_refusing_sets_the_thread_policy_off_and_restores_it(iopolicy):
    me = threading.get_ident()
    with mat.refusing_dataless_reads():
        assert iopolicy.policies[me] == mat.IOPOL_MATERIALIZE_DATALESS_FILES_OFF
        with mat.allowing_dataless_reads():
            assert iopolicy.policies[me] == mat.IOPOL_MATERIALIZE_DATALESS_FILES_ON
        assert iopolicy.policies[me] == mat.IOPOL_MATERIALIZE_DATALESS_FILES_OFF
    assert iopolicy.policies[me] == mat.IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT
    assert all(scope == mat.IOPOL_SCOPE_THREAD for _, scope, _ in iopolicy.calls)


def test_the_download_thread_turns_materialization_on_for_itself_only(tmp_path, monkeypatch, iopolicy):
    seen: dict[str, int] = {}

    def fake_read(path: Path) -> int:
        seen["thread"] = threading.get_ident()
        seen["policy"] = iopolicy.policies[threading.get_ident()]
        return 5

    monkeypatch.setattr(mat, "_force_read", fake_read)
    with mat.refusing_dataless_reads():
        assert mat._read_with_timeout(tmp_path / "stub", 5) == 5
        assert iopolicy.policies[threading.get_ident()] == mat.IOPOL_MATERIALIZE_DATALESS_FILES_OFF

    assert seen["thread"] != threading.get_ident()
    assert seen["policy"] == mat.IOPOL_MATERIALIZE_DATALESS_FILES_ON


def test_a_failed_policy_call_is_a_no_op(monkeypatch):
    monkeypatch.setattr(mat, "_iopolicy", (lambda *a: -1, lambda *a: -1))
    with mat.refusing_dataless_reads(), mat.allowing_dataless_reads():
        pass


def test_without_the_binding_the_guards_are_no_ops(monkeypatch):
    monkeypatch.setattr(mat, "_iopolicy", None)
    assert mat._set_thread_dataless_policy(mat.IOPOL_MATERIALIZE_DATALESS_FILES_OFF) is None
    with mat.refusing_dataless_reads(), mat.allowing_dataless_reads():
        pass


def test_refused_dataless_read_recognises_the_kernel_errnos():
    import errno

    assert mat.refused_dataless_read(OSError(errno.EDEADLK, "Resource deadlock avoided"))
    assert mat.refused_dataless_read(OSError(errno.EAGAIN, "Resource temporarily unavailable"))
    assert not mat.refused_dataless_read(OSError(errno.ENOENT, "No such file"))
    assert not mat.refused_dataless_read(ValueError("not an OSError"))
