"""Tests for ingest_xpc synchronous and progress functionality."""

from unittest.mock import MagicMock, patch

from garage_rag.ingest import (
    IngestProgress,
    cancel_ingest,
    ingest_xpc,
    is_ingest_cancelled,
)
from garage_rag.ingest.pipeline import IngestCounters, MaterializationBudget, WalkStats


def test_ingest_progress_model():
    p = IngestProgress(
        source="test-source",
        phase="ingest",
        seen=5,
        total_items=10,
        indexed=4,
        skipped=1,
        failed=0,
        placeholders=1,
        rejected=2,
        chunks_written=12,
        item_type="documents",
        progress=0.5,
        message="Halfway there",
        current_item="note.md",
    )
    assert p.source == "test-source"
    assert p.progress == 0.5
    assert p.placeholders == 1
    assert p.rejected == 2
    assert p.chunks_written == 12
    assert p.item_type == "documents"
    assert p.current_item == "note.md"
    d = p.to_dict()
    assert d["source"] == "test-source"
    assert d["seen"] == 5
    assert d["total_items"] == 10
    assert d["placeholders"] == 1
    assert d["rejected"] == 2
    assert d["chunks_written"] == 12
    assert d["current_item"] == "note.md"


def test_ingest_xpc_progress():
    mock_counters = IngestCounters()
    mock_counters.seen = 10
    mock_counters.total_items = 10
    mock_counters.indexed = 8
    mock_counters.skipped = 2
    mock_counters.failed = 0
    mock_counters.placeholders = 1
    mock_counters.rejected = 3
    mock_counters.chunks_written = 24

    mock_walk_stats = WalkStats()
    mock_budget = MaterializationBudget()

    progress_events: list[IngestProgress] = []

    def progress_handler(prog: IngestProgress):
        progress_events.append(prog)

    def fake_ingest_source(*, gateway, source_slug, **kwargs):
        progress_fn = kwargs.get("progress")
        if progress_fn:
            progress_fn(mock_counters, mock_budget, total_items=10, phase="scan")
            progress_fn(mock_counters, mock_budget, total_items=10, phase="ingest", current_item="file1.txt")
        return mock_counters, mock_walk_stats, mock_budget

    with patch("garage_rag.ingest.pipeline.ingest_source", side_effect=fake_ingest_source):
        mock_factory = MagicMock()
        ingest_xpc(
            source="my-source",
            progress_callback=progress_handler,
            session_factory=mock_factory,
        )

    assert len(progress_events) >= 3
    # Check scan event
    assert progress_events[0].phase == "scan"
    # Check ingest event with current_item
    assert any(e.current_item == "file1.txt" for e in progress_events)
    # Check completion event
    assert progress_events[-1].phase == "complete"
    assert progress_events[-1].source == "my-source"
    assert progress_events[-1].progress == 1.0
    assert progress_events[-1].chunks_written == 24
    # Every counter the pipeline tracks is copied through, including rejections.
    assert progress_events[-1].rejected == 3
    assert all(e.rejected == 3 for e in progress_events if e.phase == "ingest")


def test_ingest_xpc_wildcard_lists_sources_without_opening_a_run():
    """``*`` must expand via list_enabled_sources, not via a begin_session("*") that
    leaves an orphaned ingest_runs row behind."""
    counters = IngestCounters()
    seen_slugs: list[str] = []

    def fake_ingest_source(*, gateway, source_slug, **kwargs):
        seen_slugs.append(source_slug)
        return counters, WalkStats(), MaterializationBudget()

    gw = MagicMock()
    gw.list_enabled_sources.return_value = ["alpha", "beta"]

    with patch("garage_rag.ingest.pipeline.ingest_source", side_effect=fake_ingest_source):
        ingest_xpc(source="*", gateway=gw)

    assert seen_slugs == ["alpha", "beta"]
    gw.list_enabled_sources.assert_called_once_with()
    gw.begin_session.assert_not_called()


def test_ingest_xpc_cancellation():
    mock_counters = IngestCounters()
    mock_counters.seen = 5
    mock_counters.total_items = 10
    mock_counters.indexed = 5

    mock_walk_stats = WalkStats()
    mock_budget = MaterializationBudget()

    progress_events: list[IngestProgress] = []

    def progress_handler(prog: IngestProgress):
        progress_events.append(prog)
        if prog.phase == "ingest":
            cancel_ingest()

    def fake_ingest_source(*, gateway, source_slug, **kwargs):
        # Mirrors the real pipeline: it notices the cancel flag on the next
        # candidate and emits exactly one ``cancelled`` event naming that item.
        progress_fn = kwargs.get("progress")
        is_cancelled = kwargs.get("is_cancelled")
        if progress_fn:
            progress_fn(mock_counters, mock_budget, total_items=10, phase="scan")
            progress_fn(mock_counters, mock_budget, total_items=10, phase="ingest", current_item="file1.txt")
            if is_cancelled and is_cancelled():
                progress_fn(mock_counters, mock_budget, total_items=10, phase="cancelled", current_item="file2.txt")
        return mock_counters, mock_walk_stats, mock_budget

    with patch("garage_rag.ingest.pipeline.ingest_source", side_effect=fake_ingest_source):
        mock_factory = MagicMock()
        ingest_xpc(
            source="cancel-source",
            progress_callback=progress_handler,
            session_factory=mock_factory,
        )

    assert is_ingest_cancelled()
    assert len(progress_events) >= 2
    cancelled = [e for e in progress_events if e.phase == "cancelled"]
    assert len(cancelled) == 1, "ingest_xpc must not emit a second cancelled event"
    assert progress_events[-1] is cancelled[0]
    assert progress_events[-1].source == "cancel-source"
    assert progress_events[-1].current_item == "file2.txt"
    assert not any(e.phase == "complete" for e in progress_events)


def test_set_c_log_callback():
    import ctypes
    import logging
    import sys

    from garage_rag.ingest import OSLogHandler, StreamToLog, set_c_log_callback

    logs_received = []

    @ctypes.CFUNCTYPE(None, ctypes.c_int, ctypes.c_char_p)
    def test_log_sink(level, msg_ptr):
        msg = ctypes.string_at(msg_ptr).decode("utf-8")
        logs_received.append((level, msg))

    root_logger = logging.getLogger()
    garage_logger = logging.getLogger("garage_rag")
    orig_stdout, orig_stderr, orig_excepthook = sys.stdout, sys.stderr, sys.excepthook
    orig_root_level, orig_garage_level = root_logger.level, garage_logger.level

    # Keep a reference to callback
    func_ptr = ctypes.cast(test_log_sink, ctypes.c_void_p).value
    set_c_log_callback(func_ptr)

    assert isinstance(sys.stdout, StreamToLog)
    assert isinstance(sys.stderr, StreamToLog)
    assert sys.excepthook is not orig_excepthook
    assert any(isinstance(h, OSLogHandler) for h in root_logger.handlers)

    log = logging.getLogger("test_logger")
    log.info("Test message for OSLog")
    log.error("Test error message")

    set_c_log_callback(0)

    assert any("Test message for OSLog" in msg for lvl, msg in logs_received)
    assert any("Test error message" in msg for lvl, msg in logs_received)

    # Unregistering must put the interpreter back the way it was found.
    assert sys.stdout is orig_stdout
    assert sys.stderr is orig_stderr
    assert sys.excepthook is orig_excepthook
    assert root_logger.level == orig_root_level
    assert garage_logger.level == orig_garage_level
    assert not any(isinstance(h, OSLogHandler) for h in root_logger.handlers)

    # A second unregister is a harmless no-op.
    set_c_log_callback(0)
    assert sys.stdout is orig_stdout


def test_ingest_xpc_with_grpc_options():
    mock_counters = IngestCounters()
    mock_counters.seen = 1
    mock_counters.total_items = 1
    mock_counters.indexed = 1
    mock_walk_stats = WalkStats()
    mock_budget = MaterializationBudget()

    progress_events: list[IngestProgress] = []

    def fake_ingest_source(*, gateway, source_slug, **kwargs):
        return mock_counters, mock_walk_stats, mock_budget

    with (
        patch("garage_rag.ingest.pipeline.ingest_source", side_effect=fake_ingest_source),
        patch("garage_rag.ingest.gateway.GrpcIngestStorageGateway") as mock_gw_cls,
        patch("garage_rag.service.client.GarageClient") as mock_client_cls,
    ):
        mock_gw = MagicMock()
        mock_gw_cls.return_value = mock_gw

        ingest_xpc(
            source="grpc-options-source",
            progress_callback=lambda p: progress_events.append(p),
            grpc_host="127.0.0.1",
            grpc_port=50051,
        )

        mock_client_cls.assert_called_once_with(host="127.0.0.1", port=50051, in_process=False, socket_path=None)
        mock_gw_cls.assert_called_once()
        assert len(progress_events) >= 2
        assert progress_events[-1].phase == "complete"
