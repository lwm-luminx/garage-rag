"""On-demand materialization of cloud placeholder files.

Reading a placeholder makes the sync client download it. That is the mechanism,
and it is also the hazard: walking a large online-only tree would pull hundreds
of gigabytes with no upper bound and no way to stop partway.

So materialization is metered. A :class:`MaterializationBudget` caps both the
number of files and the bytes any single run will pull, and the run reports what
it fetched and what it deferred. Because ingest is idempotent, stopping at the
budget is not a failure: the next run skips everything already indexed and
spends its budget on the next slice, converging on the full corpus over several
passes instead of one unbounded one.

The budget only governs reads that go through :func:`materialize`. Any other read of
a dataless file -- an extractor opened directly, a hash, a library peeking at a header
-- would download it just the same, with no accounting. On macOS the kernel offers a
switch for exactly this: the ``IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES`` I/O policy
(``setiopolicy_np(3)``), which ``ls`` and Spotlight use to walk File Provider trees
without pulling them down. With it *off*, opening a dataless file fails with
``EDEADLK`` instead of blocking on a download. The pipeline runs with it off on its
thread (:func:`refusing_dataless_reads`) and turns it on only inside the one thread
that performs a budgeted download (:func:`allowing_dataless_reads`), so nothing else
can start one. Elsewhere, and where the call is unavailable, both are no-ops.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import errno
import logging
import sys
import threading
from collections.abc import Iterator
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path

from garage_rag.config import get_settings
from garage_rag.extract.placeholder import PlaceholderFile, is_placeholder

log = logging.getLogger(__name__)

# Reads that outlived their timeout are left running (a blocking read on a stalled provider cannot be
# cancelled). They are daemon threads, so interpreter shutdown does not wait for them, and at most
# this many may be outstanding: past that, placeholders are deferred instead of starting another.
MAX_STALLED_READS = 4
_stalled_reads: set[threading.Thread] = set()
_stalled_lock = threading.Lock()

# sys/resource.h: setiopolicy_np(int iotype, int scope, int policy).
IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES = 3
IOPOL_SCOPE_PROCESS = 0
IOPOL_SCOPE_THREAD = 1
IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT = 0  # the thread follows the process policy
IOPOL_MATERIALIZE_DATALESS_FILES_OFF = 1
IOPOL_MATERIALIZE_DATALESS_FILES_ON = 2

# What a read of a dataless file raises while materialization is off. The kernel reports
# EDEADLK; EAGAIN has been seen from providers that decline a fetch.
DATALESS_REFUSED_ERRNOS: frozenset[int] = frozenset({errno.EDEADLK, errno.EAGAIN})


def _load_iopolicy() -> tuple | None:
    """Bind libc ``setiopolicy_np``/``getiopolicy_np``, or return None where they do not exist."""
    if not sys.platform.startswith("darwin"):
        return None
    try:
        libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
        setter, getter = libc.setiopolicy_np, libc.getiopolicy_np
    except (OSError, AttributeError):  # pragma: no cover - platform dependent
        return None
    setter.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_int]
    setter.restype = ctypes.c_int
    getter.argtypes = [ctypes.c_int, ctypes.c_int]
    getter.restype = ctypes.c_int
    return setter, getter


_iopolicy = _load_iopolicy()


def _set_thread_dataless_policy(policy: int) -> int | None:
    """Set this thread's dataless-file policy; returns the previous one, or None when unavailable."""
    if _iopolicy is None:
        return None
    setter, getter = _iopolicy
    previous = getter(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
    if previous < 0 or setter(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, policy) != 0:
        log.debug("setiopolicy_np unavailable for the dataless policy (errno %d)", ctypes.get_errno())
        return None
    return previous


@contextmanager
def _thread_dataless_policy(policy: int) -> Iterator[None]:
    previous = _set_thread_dataless_policy(policy)
    try:
        yield
    finally:
        if previous is not None:
            _set_thread_dataless_policy(previous)


@contextmanager
def refusing_dataless_reads() -> Iterator[None]:
    """Run the body with dataless-file materialization off for the current thread.

    Inside, opening a placeholder raises ``OSError`` with an errno in
    :data:`DATALESS_REFUSED_ERRNOS` instead of downloading it. Threads the body starts do
    not inherit a thread-scoped policy, which is what lets the materialize thread opt back in.
    """
    with _thread_dataless_policy(IOPOL_MATERIALIZE_DATALESS_FILES_OFF):
        yield


@contextmanager
def allowing_dataless_reads() -> Iterator[None]:
    """Run the body with materialization on for the current thread: the budgeted download."""
    with _thread_dataless_policy(IOPOL_MATERIALIZE_DATALESS_FILES_ON):
        yield


def refused_dataless_read(exc: BaseException) -> bool:
    """Whether ``exc`` is the kernel declining to materialize a dataless file.

    Extractors wrap the read's ``OSError`` in an ``ExtractionError`` (``raise ... from exc``),
    so the cause and context chain is searched, not just the exception itself.
    """
    seen: set[int] = set()
    current: BaseException | None = exc
    while current is not None and id(current) not in seen:
        seen.add(id(current))
        if isinstance(current, OSError) and current.errno in DATALESS_REFUSED_ERRNOS:
            return True
        current = current.__cause__ or current.__context__
    return False


def _stalled_count() -> int:
    with _stalled_lock:
        _stalled_reads.difference_update([t for t in _stalled_reads if not t.is_alive()])
        return len(_stalled_reads)


def _read_with_timeout(path: Path, timeout: float) -> int | None:
    """``_force_read(path)`` on a daemon thread; None when it has not finished within ``timeout``.

    An ``OSError`` from the read is re-raised here.
    """
    outcome: dict[str, int | OSError] = {}

    def run() -> None:
        try:
            with allowing_dataless_reads():
                outcome["size"] = _force_read(path)
        except OSError as exc:
            outcome["error"] = exc

    reader = threading.Thread(target=run, name=f"materialize:{path.name}", daemon=True)
    reader.start()
    reader.join(timeout)
    if reader.is_alive():
        with _stalled_lock:
            _stalled_reads.add(reader)
        return None
    error = outcome.get("error")
    if isinstance(error, OSError):
        raise error
    size = outcome.get("size", 0)
    return size if isinstance(size, int) else 0


@dataclass
class MaterializationBudget:
    """Per-run cap on placeholder downloads."""

    enabled: bool = False
    max_files: int = 0  # 0 = unlimited
    max_bytes: int = 0  # 0 = unlimited
    timeout_seconds: float = 120.0

    files_done: int = 0
    bytes_done: int = 0
    deferred: int = 0
    failed: int = 0

    @classmethod
    def from_settings(cls) -> MaterializationBudget:
        settings = get_settings()
        return cls(
            enabled=settings.materialize_placeholders,
            max_files=settings.materialize_limit,
            max_bytes=settings.materialize_max_bytes,
            timeout_seconds=settings.materialize_timeout_seconds,
        )

    @property
    def exhausted(self) -> bool:
        if self.max_files and self.files_done >= self.max_files:
            return True
        return bool(self.max_bytes and self.bytes_done >= self.max_bytes)

    def summary(self) -> str:
        gib = self.bytes_done / 1024**3
        parts = [f"materialized {self.files_done:,} files ({gib:.2f} GiB)"]
        if self.deferred:
            parts.append(f"deferred {self.deferred:,}")
        if self.failed:
            parts.append(f"failed {self.failed:,}")
        return ", ".join(parts)


def _force_read(path: Path) -> int:
    """Read a file end to end, which is what triggers the download.

    Returns the byte count. The content is discarded; the extractor re-reads the
    file immediately afterwards, by which point it is local and warm in cache.
    """
    total = 0
    with path.open("rb") as handle:
        while block := handle.read(1 << 20):
            total += len(block)
    return total


def materialize(path: Path, budget: MaterializationBudget) -> bool:
    """Attempt to download one placeholder.

    Returns True when the file is now local. Respects the budget and never
    raises; the caller treats False as "still a placeholder".
    """
    if not budget.enabled or budget.exhausted:
        budget.deferred += 1
        return False

    stalled = _stalled_count()
    if stalled >= MAX_STALLED_READS:
        log.warning("%d earlier downloads are still stalled; deferring %s", stalled, path)
        budget.deferred += 1
        return False

    try:
        size = _read_with_timeout(path, budget.timeout_seconds)
    except OSError as exc:
        log.warning("materialization failed for %s: %s", path, exc)
        budget.failed += 1
        return False
    if size is None:
        log.warning("materialization timed out after %.0fs: %s", budget.timeout_seconds, path)
        budget.failed += 1
        return False

    # The provider may hand back an empty file rather than an error; that is
    # neither a successful materialization nor a charge against the budget.
    if size == 0 or is_placeholder(path):
        log.debug("still a placeholder after read: %s", path)
        budget.failed += 1
        return False

    budget.files_done += 1
    budget.bytes_done += size
    log.debug("materialized %s (%d bytes)", path.name, size)
    return True


def ensure_local(path: Path, budget: MaterializationBudget) -> None:
    """Materialize ``path`` if needed, or raise :class:`PlaceholderFile`.

    The single entry point the pipeline uses, so that budget accounting cannot be
    bypassed by calling the extractor directly.
    """
    if not is_placeholder(path):
        return
    if materialize(path, budget):
        return
    raise PlaceholderFile(path, "cloud")
