"""ingest"""

from __future__ import annotations

import contextlib
import ctypes
import json
import logging
import sys
import threading
from collections.abc import Callable
from dataclasses import asdict, dataclass
from typing import Any

log = logging.getLogger(__name__)

_global_c_callback: Any = None
_global_c_log_callback: Any = None
# What set_c_log_callback replaced, so unregistering (address 0) can put it back.
_saved_log_state: dict[str, Any] | None = None
_global_cancel_requested: bool = False
# Guards (re)registration of the C callbacks; the Swift host may register them from
# several threads (pythonDidBecomeReady, each ingest request).
_c_callback_lock = threading.RLock()


class OSLogHandler(logging.Handler):
    """Logging handler that routes Python log records to Swift/OSLog via C callback."""

    def emit(self, record: logging.LogRecord) -> None:
        if _global_c_log_callback is not None:
            try:
                msg = self.format(record)
                level = record.levelno
                _global_c_log_callback(level, msg.encode("utf-8", errors="replace"))
            except Exception:
                pass


class StreamToLog:
    """Redirects writes to a stream (stdout/stderr) to OSLog callback."""

    def __init__(self, level: int, original_stream: Any, name: str = "") -> None:
        self.level = level
        self.original_stream = original_stream
        self.name = name
        self._buf = ""

    def write(self, buf: str) -> None:
        self._buf += buf
        while "\n" in self._buf:
            line, self._buf = self._buf.split("\n", 1)
            line = line.strip()
            if line and _global_c_log_callback is not None:
                try:
                    prefix = f"[{self.name}] " if self.name else ""
                    _global_c_log_callback(self.level, f"{prefix}{line}".encode("utf-8", errors="replace"))
                except Exception:
                    pass
        if self.original_stream and hasattr(self.original_stream, "write"):
            with contextlib.suppress(Exception):
                self.original_stream.write(buf)

    def flush(self) -> None:
        if self._buf.strip() and _global_c_log_callback is not None:
            try:
                prefix = f"[{self.name}] " if self.name else ""
                _global_c_log_callback(self.level, f"{prefix}{self._buf.strip()}".encode("utf-8", errors="replace"))
                self._buf = ""
            except Exception:
                pass
        if self.original_stream and hasattr(self.original_stream, "flush"):
            with contextlib.suppress(Exception):
                self.original_stream.flush()


def set_c_log_callback(callback_address: int) -> None:
    """Register a C ABI function pointer (address) for real-time logging to OSLog.

    Registering redirects the root logger, ``sys.stdout``/``sys.stderr`` and
    ``sys.excepthook`` to the callback. Registering address 0 undoes all of that
    and restores whatever was in place before the first registration.
    """
    global _global_c_log_callback, _saved_log_state
    with _c_callback_lock:
        if not callback_address:
            _global_c_log_callback = None
            saved = _saved_log_state
            _saved_log_state = None
            if saved is None:
                return
            root_logger = logging.getLogger()
            for handler in list(root_logger.handlers):
                if isinstance(handler, OSLogHandler):
                    root_logger.removeHandler(handler)
            root_logger.setLevel(saved["root_level"])
            garage_logger = logging.getLogger("garage_rag")
            garage_logger.setLevel(saved["garage_level"])
            garage_logger.propagate = saved["garage_propagate"]
            sys.stdout = saved["stdout"]
            sys.stderr = saved["stderr"]
            sys.excepthook = saved["excepthook"]
            return

        callback_type = ctypes.CFUNCTYPE(None, ctypes.c_int, ctypes.c_char_p)
        _global_c_log_callback = callback_type(callback_address)

        root_logger = logging.getLogger()
        garage_logger = logging.getLogger("garage_rag")
        if _saved_log_state is None:
            _saved_log_state = {
                "root_level": root_logger.level,
                "garage_level": garage_logger.level,
                "garage_propagate": garage_logger.propagate,
                "stdout": sys.stdout,
                "stderr": sys.stderr,
                "excepthook": sys.excepthook,
            }

        has_oslog_handler = any(isinstance(h, OSLogHandler) for h in root_logger.handlers)
        if not has_oslog_handler:
            handler = OSLogHandler()
            formatter = logging.Formatter("[%(name)s] %(message)s")
            handler.setFormatter(formatter)
            handler.setLevel(logging.DEBUG)
            root_logger.addHandler(handler)
            if root_logger.level == logging.NOTSET or root_logger.level > logging.DEBUG:
                root_logger.setLevel(logging.DEBUG)

        garage_logger.setLevel(logging.DEBUG)
        garage_logger.propagate = True

        if not isinstance(sys.stdout, StreamToLog):
            sys.stdout = StreamToLog(20, sys.__stdout__, name="stdout")  # INFO
        if not isinstance(sys.stderr, StreamToLog):
            sys.stderr = StreamToLog(40, sys.__stderr__, name="stderr")  # ERROR

        def custom_excepthook(exc_type, exc_value, exc_traceback):
            import traceback

            tb_str = "".join(traceback.format_exception(exc_type, exc_value, exc_traceback))
            if _global_c_log_callback is not None:
                with contextlib.suppress(Exception):
                    _global_c_log_callback(
                        40, f"Uncaught Python exception:\n{tb_str}".encode("utf-8", errors="replace")
                    )
            log.critical("Uncaught Python exception: %s\n%s", exc_value, tb_str)

        sys.excepthook = custom_excepthook


def _ensure_logging() -> None:
    """Ensure python logging is configured to output to stderr if not already initialized."""
    root_logger = logging.getLogger()
    if not root_logger.handlers:
        logging.basicConfig(
            level=logging.INFO,
            format="%(asctime)s [%(levelname)s] [%(name)s] %(message)s",
            stream=sys.stderr,
        )


@dataclass
class IngestProgress:
    source: str
    phase: str = "ingest"
    seen: int = 0
    total_items: int = 0
    indexed: int = 0
    skipped: int = 0
    failed: int = 0
    placeholders: int = 0
    rejected: int = 0
    chunks_written: int = 0
    item_type: str = "items"
    progress: float = 0.0
    message: str = ""
    error: str | None = None
    current_item: str | None = None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def cancel_ingest() -> None:
    """Request cancellation of any active ingest operation."""
    global _global_cancel_requested
    _global_cancel_requested = True


def is_ingest_cancelled() -> bool:
    """Check if cancellation has been requested."""
    return _global_cancel_requested


def reset_ingest_cancel() -> None:
    """Reset the cancellation flag."""
    global _global_cancel_requested
    _global_cancel_requested = False


def set_c_progress_callback(callback_address: int) -> None:
    """Register a C ABI function pointer (address) for real-time progress updates."""
    global _global_c_callback
    with _c_callback_lock:
        if not callback_address:
            _global_c_callback = None
        else:
            callback_type = ctypes.CFUNCTYPE(None, ctypes.c_char_p)
            _global_c_callback = callback_type(callback_address)


def _notify_c_progress(prog: IngestProgress) -> None:
    if _global_c_callback is not None:
        try:
            payload = json.dumps(prog.to_dict()).encode("utf-8")
            _global_c_callback(payload)
        except Exception:
            pass


def ingest_xpc(
    source: str,
    progress_callback: Callable[[Any], Any] | None = None,
    *,
    include_code: bool = False,
    limit: int | None = None,
    force: bool = False,
    session_factory: Any = None,
    gateway: Any = None,
    grpc_client: Any = None,
    grpc_host: str | None = None,
    grpc_port: int | None = None,
    grpc_socket: str | None = None,
) -> None:
    _ensure_logging()
    log.info(
        "ingest_xpc called for source=%r (include_code=%s, limit=%s, force=%s, grpc_port=%s, grpc_socket=%s)",
        source,
        include_code,
        limit,
        force,
        grpc_port,
        grpc_socket,
    )

    from garage_rag.ingest.gateway import get_storage_gateway
    from garage_rag.ingest.pipeline import ingest_source

    reset_ingest_cancel()

    gw = get_storage_gateway(
        session_factory=session_factory,
        gateway=gateway,
        grpc_client=grpc_client,
        grpc_host=grpc_host,
        grpc_port=grpc_port,
        grpc_socket=grpc_socket,
    )

    if source == "*":
        sources = gw.list_enabled_sources()
        if not sources:
            raise RuntimeError("No sources registered")
        log.info("Wildcard source expanded to %d source(s): %s", len(sources), sources)
    else:
        sources = [source]

    def _emit_progress(prog: IngestProgress) -> None:
        if prog.phase == "error":
            log.error("[%s] (error) %s: %s", prog.source, prog.message, prog.error)
        elif prog.phase == "cancelled":
            log.warning("[%s] (cancelled) %s", prog.source, prog.message)
        elif prog.phase in ("scan", "complete"):
            log.info("[%s] (%s) %s", prog.source, prog.phase, prog.message)
        else:
            log.info("[%s] (%s %.1f%%) %s", prog.source, prog.phase, prog.progress * 100.0, prog.message)

        _notify_c_progress(prog)
        if progress_callback is not None:
            try:
                progress_callback(prog)
            except Exception as e:
                log.warning("progress_callback raised exception: %s", e)

    for current_source in sources:
        if is_ingest_cancelled():
            log.warning("Ingest cancelled before processing source %r", current_source)
            break

        log.info("Initiating ingestion for source %r", current_source)
        start_prog = IngestProgress(
            source=current_source,
            phase="scan",
            seen=0,
            total_items=0,
            progress=0.0,
            message=f"Starting ingestion for {current_source}...",
        )
        _emit_progress(start_prog)

        def _handle_pipeline_progress(*args: Any, _source: str = current_source, **kwargs: Any) -> None:
            counters = args[0] if len(args) > 0 else None
            phase = kwargs.get("phase", "ingest")
            total_items = kwargs.get("total_items", getattr(counters, "total_items", 0))
            current_item = kwargs.get("current_item", getattr(counters, "current_item", None))

            seen = getattr(counters, "seen", 0)
            indexed = getattr(counters, "indexed", 0)
            skipped = getattr(counters, "skipped", 0)
            failed = getattr(counters, "failed", 0)
            placeholders = getattr(counters, "placeholders", 0)
            rejected = getattr(counters, "rejected", 0)
            chunks_written = getattr(counters, "chunks_written", 0)
            item_type = getattr(counters, "item_type", "items")
            errors = getattr(counters, "errors", [])
            last_error = errors[-1] if errors else None

            prog_val = min(1.0, max(0.0, float(seen) / float(total_items))) if total_items and total_items > 0 else 0.0

            if phase == "scan":
                msg = f"Scanning {_source}: found {total_items} {item_type}"
            elif phase == "cancelled":
                msg = (
                    f"Ingestion cancelled for {_source} after {seen}/{total_items} {item_type} scanned "
                    f"({indexed} ingested)"
                )
            elif current_item:
                pct = f"{(prog_val * 100):.1f}%" if total_items else "0.0%"
                msg = (
                    f"[{seen}/{total_items} scanned {pct}] {_source}: {indexed} ingested "
                    f"({skipped} skipped, {failed} failed) - {current_item}"
                )
            else:
                pct = f"{(prog_val * 100):.1f}%" if total_items else "0.0%"
                msg = (
                    f"[{seen}/{total_items} scanned {pct}] {_source}: {indexed} ingested "
                    f"({skipped} skipped, {failed} failed, {chunks_written} chunks)"
                )

            prog = IngestProgress(
                source=_source,
                phase=phase,
                seen=seen,
                total_items=total_items,
                indexed=indexed,
                skipped=skipped,
                failed=failed,
                placeholders=placeholders,
                rejected=rejected,
                chunks_written=chunks_written,
                item_type=item_type,
                progress=prog_val,
                message=msg,
                error=last_error,
                current_item=current_item,
            )

            _emit_progress(prog)

        try:
            log.info("Running pipeline.ingest_source for %r", current_source)
            counters, walk_stats, budget = ingest_source(
                gateway=gw,
                source_slug=current_source,
                include_code=include_code,
                limit=limit,
                force=force,
                progress=_handle_pipeline_progress,
                is_cancelled=is_ingest_cancelled,
            )
            log.info(
                "Completed pipeline.ingest_source for %r: seen=%d/%d, indexed=%d, skipped=%d, failed=%d, "
                "placeholders=%d, chunks=%d",
                current_source,
                counters.seen,
                counters.total_items,
                counters.indexed,
                counters.skipped,
                counters.failed,
                counters.placeholders,
                counters.chunks_written,
            )
        except Exception as exc:
            log.exception("Pipeline exception while ingesting %r: %s", current_source, exc)
            err_prog = IngestProgress(
                source=current_source,
                phase="error",
                error=str(exc),
                message=f"Error ingesting {current_source}: {exc}",
                progress=0.0,
            )
            _emit_progress(err_prog)
            raise

        if is_ingest_cancelled():
            # The pipeline already emitted the phase="cancelled" event (with the
            # item it stopped on); do not send a second one.
            log.warning("Ingest run marked cancelled for %r", current_source)
            break

        final_prog = IngestProgress(
            source=current_source,
            phase="complete",
            seen=counters.seen,
            total_items=counters.total_items,
            indexed=counters.indexed,
            skipped=counters.skipped,
            failed=counters.failed,
            placeholders=counters.placeholders,
            rejected=counters.rejected,
            chunks_written=counters.chunks_written,
            item_type=counters.item_type,
            progress=1.0,
            message=(
                f"Ingested {current_source}: seen {counters.seen}/{counters.total_items}, "
                f"indexed {counters.indexed}, skipped {counters.skipped}, failed {counters.failed}, "
                f"{counters.chunks_written} chunks written"
            ),
        )
        _emit_progress(final_prog)
