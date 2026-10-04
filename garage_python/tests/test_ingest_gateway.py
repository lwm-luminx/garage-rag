"""Tests for IngestStorageGateway and gRPC Ingest Database Facade."""

from __future__ import annotations

import threading
import time
from contextlib import contextmanager
from datetime import UTC, datetime
from pathlib import Path
from unittest.mock import MagicMock, patch

import grpc
import pytest

from garage_rag.attribute.resolver import SelfIdentity
from garage_rag.db.models import CorpusClass, Document, IngestState, Source, TrustTier
from garage_rag.extract.base import ExtractionError, file_sha256
from garage_rag.extract.placeholder import PlaceholderFile
from garage_rag.ingest import materialize as materialize_mod
from garage_rag.ingest.gateway import (
    AuthorPayload,
    ChunkPayload,
    ExistingDocStat,
    GrpcIngestStorageGateway,
    SourceContext,
    SqlAlchemyIngestStorageGateway,
)
from garage_rag.ingest.materialize import MaterializationBudget, materialize
from garage_rag.ingest.pipeline import IngestCounters, ingest_one, ingest_source
from garage_rag.ingest.scanner import SourceScanResult
from garage_rag.ingest.walker import Candidate
from garage_rag.proto.garage_pb2 import (
    BeginIngestSessionRequest,
    BeginIngestSessionResponse,
    CheckDocumentStatRequest,
    CheckDocumentStatResponse,
    FinalizeIngestSessionRequest,
    FinalizeIngestSessionResponse,
    ListSourcesResponse,
    PersistDocumentRequest,
    PersistDocumentResponse,
    PersistScanRequest,
    SourceInfo,
)
from garage_rag.service.client import GarageClient
from garage_rag.service.server import GarageRpcServicer, create_grpc_server


@pytest.fixture
def grpc_server():
    """Start an in-memory / local gRPC server on an ephemeral port."""
    stop_event = threading.Event()
    server, servicer = create_grpc_server(host="127.0.0.1", port=0, stop_event=stop_event)
    bound_port = server.add_insecure_port("127.0.0.1:0")
    server.start()
    yield bound_port, servicer
    server.stop(grace=None)


def test_grpc_database_facade_servicer_methods():
    servicer = GarageRpcServicer()
    mock_context = MagicMock()

    mock_source = MagicMock(spec=Source)
    mock_source.id = 101
    mock_source.slug = "facade-test-slug"
    mock_source.root = "/tmp/test"
    mock_source.kind = "filesystem"
    mock_source.default_class = CorpusClass.DOCUMENT
    mock_source.default_trust = TrustTier.AUTHORED

    with (
        patch("garage_rag.db.engine.session_scope") as mock_scope,
        patch("garage_rag.attribute.resolver.ensure_self_author"),
    ):
        mock_session = MagicMock()
        mock_session.query.return_value.filter_by.return_value.one_or_none.return_value = mock_source
        mock_session.query.return_value.filter_by.return_value.all.return_value = [mock_source]
        mock_session.query.return_value.order_by.return_value.all.return_value = [mock_source]
        mock_scope.return_value.__enter__.return_value = mock_session

        # 1. BeginIngestSession
        begin_req = BeginIngestSessionRequest(source_slug="facade-test-slug")
        begin_resp = servicer.BeginIngestSession(begin_req, mock_context)
        assert begin_resp.source_id == 101
        assert begin_resp.slug == "facade-test-slug"
        assert begin_resp.root == "/tmp/test"

        # 2. PersistScan
        with patch("garage_rag.ingest.scanner.persist_scan_result") as mock_persist_scan:
            scan_req = PersistScanRequest(
                source_slug="facade-test-slug",
                item_count=5,
                item_type="files",
                duration_seconds=0.12,
            )
            scan_resp = servicer.PersistScan(scan_req, mock_context)
            assert scan_resp.success is True
            mock_persist_scan.assert_called_once()

        # 3. CheckDocumentStat
        mock_doc = MagicMock()
        mock_doc.byte_size = 1234
        mock_doc.mtime = None
        mock_doc.source_sha256 = b"\xaa\xbb"
        mock_doc.content_sha256 = b"\xcc\xdd"
        mock_doc.chunker = "document:sentence"
        mock_doc.state = IngestState.OK

        mock_session.query.return_value.filter_by.return_value.one_or_none.return_value = mock_doc
        stat_req = CheckDocumentStatRequest(source_slug="facade-test-slug", uri="doc1.txt")
        stat_resp = servicer.CheckDocumentStat(stat_req, mock_context)
        assert stat_resp.exists is True
        assert stat_resp.byte_size == 1234
        assert stat_resp.source_sha256 == "aabb"
        assert stat_resp.content_sha256 == "ccdd"

        # 4. PersistDocument (action=replace)
        with patch("garage_rag.attribute.resolver.get_or_create_author") as mock_author:
            mock_auth_obj = MagicMock()
            mock_auth_obj.id = 55
            mock_author.return_value = mock_auth_obj

            doc_req = PersistDocumentRequest(
                run_id=1,
                source_slug="facade-test-slug",
                uri="doc1.txt",
                action="replace",
                title="Doc 1",
                byte_size=1234,
                mtime=1700000000.0,
                content_sha256="ccdd",
                extractor="text",
                extractor_version="1",
                chunker="document:sentence",
                content="Hello world content",
            )
            doc_resp = servicer.PersistDocument(doc_req, mock_context)
            assert doc_resp.success is True

        # 4b. PersistDocument (action=seen): touches no document field, only ingest_seen
        mock_session.execute.reset_mock()
        seen_req = PersistDocumentRequest(run_id=1, source_slug="facade-test-slug", uri="doc1.txt", action="seen")
        seen_resp = servicer.PersistDocument(seen_req, mock_context)
        assert seen_resp.success is True
        assert seen_resp.chunks_written == 0
        assert mock_session.execute.call_count == 1
        assert mock_doc.state == IngestState.OK

        # 5. FinalizeIngestSession
        final_req = FinalizeIngestSessionRequest(
            run_id=1,
            completed=True,
            seen_count=10,
            indexed_count=8,
            skipped_count=2,
        )
        final_resp = servicer.FinalizeIngestSession(final_req, mock_context)
        assert final_resp.success is True


def test_grpc_ingest_storage_gateway():
    client = GarageClient(in_process=True)
    gateway = GrpcIngestStorageGateway(client)

    with (
        patch.object(client, "begin_ingest_session") as mock_begin,
        patch.object(client, "persist_scan") as mock_scan,
        patch.object(client, "check_document_stat") as mock_stat,
        patch.object(client, "persist_document") as mock_doc,
        patch.object(client, "finalize_ingest_session") as mock_final,
    ):
        mock_begin.return_value = BeginIngestSessionResponse(
            source_id=1,
            slug="grpc-src",
            root="/tmp/src",
            default_class="document",
            default_trust="authored",
            run_id=42,
            source_slugs=["grpc-src"],
        )

        ctx = gateway.begin_session("grpc-src")
        assert ctx.source_id == 1
        assert ctx.slug == "grpc-src"
        assert ctx.run_id == 42
        assert ctx.default_class == CorpusClass.DOCUMENT
        assert ctx.default_trust == TrustTier.AUTHORED

        scan_result = SourceScanResult(
            source_slug="grpc-src",
            kind="filesystem",
            root=Path("/tmp/src"),
            item_count=10,
            item_type="files",
        )
        gateway.persist_scan("grpc-src", scan_result)
        mock_scan.assert_called_once()

        mock_stat.return_value = CheckDocumentStatResponse(
            exists=True,
            byte_size=500,
            mtime=1700000000.0,
            content_sha256="abc",
            chunker="test",
            state="OK",
            source_sha256="def",
        )
        stat = gateway.check_stat("grpc-src", "file.txt")
        assert stat.exists is True
        assert stat.byte_size == 500
        assert stat.content_sha256 == "abc"

        mock_doc.return_value = PersistDocumentResponse(success=True, chunks_written=3)
        written = gateway.replace_document(
            run_id=42,
            source_slug="grpc-src",
            uri="file.txt",
            title="File",
            lang="en",
            byte_size=500,
            mtime=1700000000.0,
            source_sha256="def",
            content_sha256="abc",
            extractor="text",
            extractor_version="1",
            chunker="test",
            content="test content",
            meta={},
            corpus_class="document",
            trust_tier="authored",
            authors=[AuthorPayload(name="Author", role="author")],
            chunks=[ChunkPayload(ord=0, text="test content", chunk_sha256="123")],
        )
        assert written == 3

        mock_doc.reset_mock()
        gateway.record_seen(42, "grpc-src", "unchanged.txt")
        seen_req = mock_doc.call_args.args[0]
        assert seen_req.action == "seen"
        assert seen_req.run_id == 42
        assert seen_req.uri == "unchanged.txt"

        gateway.finalize_session(
            run_id=42,
            completed=True,
            seen=1,
            indexed=1,
            skipped=0,
            failed=0,
            placeholders=0,
            materialized=0,
            materialized_bytes=0,
            errors=[],
        )
        mock_final.assert_called_once()

    with patch.object(client, "list_sources") as mock_list:
        mock_list.return_value = ListSourcesResponse(
            sources=[
                SourceInfo(slug="on", enabled=True),
                SourceInfo(slug="off", enabled=False),
                SourceInfo(slug="also-on", enabled=True),
            ]
        )
        assert gateway.list_enabled_sources() == ["on", "also-on"]


def test_ingest_source_with_grpc_gateway(tmp_path: Path):
    (tmp_path / "hello.txt").write_text("Hello from gRPC facade test", encoding="utf-8")

    client = GarageClient(in_process=True)
    gateway = GrpcIngestStorageGateway(client)

    with (
        patch.object(client, "begin_ingest_session") as mock_begin,
        patch.object(client, "persist_scan") as mock_scan,
        patch.object(client, "check_document_stat") as mock_stat,
        patch.object(client, "persist_document") as mock_doc,
        patch.object(client, "finalize_ingest_session") as mock_final,
    ):
        mock_begin.return_value = BeginIngestSessionResponse(
            source_id=1,
            slug="mock-slug",
            root=str(tmp_path),
            default_class="document",
            default_trust="authored",
            run_id=10,
            source_slugs=["mock-slug"],
        )

        mock_stat.return_value = CheckDocumentStatResponse(exists=False)
        mock_doc.return_value = PersistDocumentResponse(success=True, chunks_written=1)
        mock_final.return_value = FinalizeIngestSessionResponse(success=True)

        counters, walk_stats, budget = ingest_source(
            source_slug="mock-slug",
            gateway=gateway,
        )

        assert counters.seen == 1
        assert counters.indexed == 1
        assert counters.chunks_written == 1
        mock_begin.assert_called_once()
        mock_scan.assert_called_once()
        mock_doc.assert_called_once()
        mock_final.assert_called_once()


def test_ingest_gateway_via_live_grpc_server(grpc_server, tmp_path: Path):
    port, servicer = grpc_server
    client = GarageClient(host="127.0.0.1", port=port, in_process=False)
    gateway = GrpcIngestStorageGateway(client)

    test_file = tmp_path / "doc.txt"
    test_file.write_text("Hello live gRPC ingest", encoding="utf-8")

    mock_source = MagicMock(spec=Source)
    mock_source.id = 1
    mock_source.slug = "live-grpc-src"
    mock_source.root = str(tmp_path)
    mock_source.kind = "filesystem"
    mock_source.default_class = CorpusClass.DOCUMENT
    mock_source.default_trust = TrustTier.AUTHORED

    with (
        patch("garage_rag.db.engine.session_scope") as mock_scope,
        patch("garage_rag.attribute.resolver.ensure_self_author"),
        patch("garage_rag.ingest.scanner.persist_scan_result"),
        patch("garage_rag.attribute.resolver.get_or_create_author") as mock_author,
    ):
        # Every facade RPC looks up the Source first and then the Document with the
        # same ``session.query(...).filter_by(...).one_or_none()`` chain, so the
        # query mock has to answer per model rather than with one shared return value.
        existing_doc: dict[str, object | None] = {"doc": None}

        def fake_query(model, *cols):
            q = MagicMock()
            if model is Source:
                q.filter_by.return_value.one_or_none.return_value = mock_source
                q.filter_by.return_value.all.return_value = [mock_source]
                q.order_by.return_value.all.return_value = [mock_source]
            elif model is Document:
                q.filter_by.return_value.one_or_none.return_value = existing_doc["doc"]
            return q

        mock_session = MagicMock()
        mock_session.query.side_effect = fake_query
        mock_scope.return_value.__enter__.return_value = mock_session

        mock_auth_obj = MagicMock()
        mock_auth_obj.id = 10
        mock_author.return_value = mock_auth_obj

        # 1. begin_session over live gRPC
        ctx = gateway.begin_session("live-grpc-src")
        assert ctx.source_id == 1
        assert ctx.slug == "live-grpc-src"

        # 2. persist_scan over live gRPC. The details are what the sqlite scanner records for a
        # Messages source: lists and a nested table as well as counts, which the request used to
        # carry as a string-to-int map and so refused with "'list' object cannot be interpreted
        # as an integer".
        scan_result = SourceScanResult(
            source_slug="live-grpc-src",
            kind="filesystem",
            root=tmp_path,
            item_count=1,
            item_type="files",
            details={"databases_count": 1, "databases": ["chat.db"], "tables": {"message": 3}, "ok": True},
        )
        with patch("garage_rag.ingest.scanner.persist_scan_result") as persisted:
            gateway.persist_scan("live-grpc-src", scan_result)
        stored = persisted.call_args.args[1]
        assert stored.details == {"databases_count": 1, "databases": ["chat.db"], "tables": {"message": 3}, "ok": True}
        assert stored.item_count == 1
        assert stored.error is None

        # 3. check_stat over live gRPC (no Document row yet)
        stat = gateway.check_stat("live-grpc-src", "doc.txt")
        assert stat.exists is False

        # 4. replace_document over live gRPC
        written = gateway.replace_document(
            run_id=ctx.run_id,
            source_slug="live-grpc-src",
            uri="doc.txt",
            title="Doc",
            lang="en",
            byte_size=len("Hello live gRPC ingest"),
            mtime=1700000000.0,
            source_sha256="11",
            content_sha256="22",
            extractor="text",
            extractor_version="1",
            chunker="test",
            content="Hello live gRPC ingest",
            meta={},
            corpus_class="document",
            trust_tier="authored",
            authors=[AuthorPayload(name="Author", role="author")],
            chunks=[ChunkPayload(ord=0, text="Hello live gRPC ingest", chunk_sha256="33")],
        )
        assert written == 1

        # 5. finalize_session over live gRPC
        gateway.finalize_session(
            run_id=ctx.run_id,
            completed=True,
            seen=1,
            indexed=1,
            skipped=0,
            failed=0,
            placeholders=0,
            materialized=0,
            materialized_bytes=0,
            errors=[],
        )


def test_sqlalchemy_storage_gateway_hash_types():
    """Verify SqlAlchemyIngestStorageGateway handles bytes and hex str hashes without error."""
    mock_session = MagicMock()
    mock_source = MagicMock(spec=Source)
    mock_source.id = 1
    mock_source.slug = "test-src"
    mock_source.default_class = CorpusClass.DOCUMENT
    mock_source.default_trust = TrustTier.AUTHORED

    mock_doc = MagicMock()
    mock_session.query.return_value.filter_by.return_value.one_or_none.side_effect = [
        mock_source,
        mock_doc,  # replace_document call 1
        mock_source,
        mock_doc,  # replace_document call 2
        mock_source,
        mock_doc,  # refresh_metadata call 1
        mock_source,
        mock_doc,  # refresh_metadata call 2
    ]
    # The gateway uses the factory as a context manager (``with self.factory() as session``),
    # so the mock must hand back itself from ``__enter__`` for the query chain above to apply.
    mock_session.__enter__.return_value = mock_session

    gateway = SqlAlchemyIngestStorageGateway(session_factory=lambda: mock_session)

    with patch("garage_rag.attribute.resolver.get_or_create_author") as mock_author:
        mock_auth_obj = MagicMock()
        mock_auth_obj.id = 10
        mock_author.return_value = mock_auth_obj

        # 1. replace_document with str hashes
        written1 = gateway.replace_document(
            run_id=1,
            source_slug="test-src",
            uri="doc1.txt",
            title="Doc 1",
            lang="en",
            byte_size=10,
            mtime=1700000000.0,
            source_sha256="aabb",
            content_sha256="ccdd",
            extractor="text",
            extractor_version="1",
            chunker="test",
            content="test",
            meta={},
            corpus_class="document",
            trust_tier="authored",
            authors=[AuthorPayload(name="Author", role="author")],
            chunks=[ChunkPayload(ord=0, text="test", chunk_sha256="eeff")],
        )
        assert written1 == 1
        assert mock_doc.source_sha256 == b"\xaa\xbb"
        assert mock_doc.content_sha256 == b"\xcc\xdd"

        # 2. replace_document with bytes hashes
        written2 = gateway.replace_document(
            run_id=1,
            source_slug="test-src",
            uri="doc2.txt",
            title="Doc 2",
            lang="en",
            byte_size=10,
            mtime=1700000000.0,
            source_sha256=b"\x11\x22",
            content_sha256=b"\x33\x44",
            extractor="text",
            extractor_version="1",
            chunker="test",
            content="test",
            meta={},
            corpus_class="document",
            trust_tier="authored",
            authors=[AuthorPayload(name="Author", role="author")],
            chunks=[ChunkPayload(ord=0, text="test", chunk_sha256=b"\x55\x66")],
        )
        assert written2 == 1
        assert mock_doc.source_sha256 == b"\x11\x22"
        assert mock_doc.content_sha256 == b"\x33\x44"

        # 3. refresh_metadata with str hash
        gateway.refresh_metadata(
            run_id=1,
            source_slug="test-src",
            uri="doc1.txt",
            byte_size=10,
            mtime=1700000000.0,
            source_sha256="aabb",
            corpus_class="document",
            trust_tier="authored",
        )
        assert mock_doc.source_sha256 == b"\xaa\xbb"

        # 4. refresh_metadata with bytes hash
        gateway.refresh_metadata(
            run_id=1,
            source_slug="test-src",
            uri="doc2.txt",
            byte_size=10,
            mtime=1700000000.0,
            source_sha256=b"\x11\x22",
            corpus_class="document",
            trust_tier="authored",
        )
        assert mock_doc.source_sha256 == b"\x11\x22"


def _mock_source(tmp_path: Path, slug: str = "seen-src") -> MagicMock:
    mock_source = MagicMock(spec=Source)
    mock_source.id = 1
    mock_source.slug = slug
    mock_source.root = str(tmp_path)
    mock_source.kind = "filesystem"
    mock_source.default_class = CorpusClass.DOCUMENT
    mock_source.default_trust = TrustTier.AUTHORED
    return mock_source


def test_stat_skipped_file_is_recorded_as_seen(tmp_path: Path):
    """A second run that skips an unchanged file on stat alone must still write its
    ingest_seen row, or reconcile would treat the whole unchanged corpus as deleted."""
    note = tmp_path / "note.txt"
    note.write_text("Unchanged between runs", encoding="utf-8")
    st = note.stat()

    mock_source = _mock_source(tmp_path)
    existing: dict[str, object | None] = {"doc": None}

    def fake_query(model, *cols):
        q = MagicMock()
        if model is Source:
            q.filter_by.return_value.one_or_none.return_value = mock_source
        elif model is Document:
            q.filter_by.return_value.one_or_none.return_value = existing["doc"]
        return q

    session = MagicMock()
    session.query.side_effect = fake_query
    session.__enter__.return_value = session
    gateway = SqlAlchemyIngestStorageGateway(session_factory=lambda: session)

    fake_run = MagicMock()
    fake_run.id = 7

    with (
        patch("garage_rag.attribute.resolver.ensure_self_author"),
        patch("garage_rag.attribute.resolver.get_or_create_author") as mock_author,
        patch("garage_rag.db.models.IngestRun", return_value=fake_run),
        patch.object(gateway, "record_seen", wraps=gateway.record_seen) as record_seen,
    ):
        mock_author.return_value = MagicMock(id=10)

        # Run 1: nothing in the DB, the file is indexed (replace_document records seen itself).
        run1, _, _ = ingest_source(gateway=gateway, source_slug="seen-src")
        assert run1.indexed == 1
        record_seen.assert_not_called()

        # Run 2: the row now exists with the same size/mtime and state OK -> stat skip.
        doc = MagicMock()
        doc.byte_size = st.st_size
        doc.mtime = datetime.fromtimestamp(st.st_mtime, tz=UTC)
        doc.state = IngestState.OK
        doc.source_sha256 = b""
        doc.content_sha256 = b""
        doc.chunker = ""
        existing["doc"] = doc
        session.execute.reset_mock()

        run2, _, _ = ingest_source(gateway=gateway, source_slug="seen-src")
        assert run2.skipped == 1
        assert run2.indexed == 0
        record_seen.assert_called_once_with(7, "seen-src", str(note))
        # ...and the SQL implementation actually issued the ingest_seen insert.
        assert session.execute.call_count == 1
        statement = str(session.execute.call_args.args[0])
        assert "ingest_seen" in statement


def test_no_chunks_file_is_rejected_without_a_document(tmp_path: Path):
    """Extraction succeeds but the chunker yields nothing: no document, and not a failure."""
    (tmp_path / "empty.txt").write_text("Text that the (patched) chunker drops", encoding="utf-8")
    mock_source = _mock_source(tmp_path)

    def fake_query(model, *cols):
        q = MagicMock()
        q.filter_by.return_value.one_or_none.return_value = mock_source if model is Source else None
        return q

    session = MagicMock()
    session.query.side_effect = fake_query
    session.__enter__.return_value = session
    gateway = SqlAlchemyIngestStorageGateway(session_factory=lambda: session)
    fake_run = MagicMock()
    fake_run.id = 3

    with (
        patch("garage_rag.attribute.resolver.ensure_self_author"),
        patch("garage_rag.db.models.IngestRun", return_value=fake_run),
        patch("garage_rag.ingest.pipeline.chunk_text", return_value=[]),
        patch.object(gateway, "record_rejected") as record_rejected,
        patch.object(gateway, "replace_document") as replace_document,
    ):
        counters, _, _ = ingest_source(gateway=gateway, source_slug="seen-src")

    assert counters.failed == 0
    assert counters.rejected == 1
    assert counters.indexed == 0
    record_rejected.assert_called_once_with(3, "seen-src", str(tmp_path / "empty.txt"))
    replace_document.assert_not_called()


# --- ingest_one against a mock gateway -------------------------------------------------


def _ingest_one(tmp_path: Path, candidate: Candidate, existing: ExistingDocStat, **kwargs) -> tuple:
    gateway = MagicMock()
    gateway.check_stat.return_value = existing
    ctx = SourceContext(
        source_id=1,
        slug="src",
        root=tmp_path,
        default_class=CorpusClass.DOCUMENT,
        default_trust=TrustTier.AUTHORED,
        run_id=9,
    )
    counters = IngestCounters()
    ingest_one(
        gateway,
        ctx,
        candidate,
        self_identity=SelfIdentity("", []),
        budget=MaterializationBudget(),
        counters=counters,
        **kwargs,
    )
    return gateway, counters


def _candidate(path: Path, *, placeholder: bool = False, size: int | None = None, mtime: float | None = None):
    st = path.stat()
    return Candidate(
        path=path,
        size=st.st_size if size is None else size,
        mtime=datetime.fromtimestamp(st.st_mtime if mtime is None else mtime, tz=UTC),
        placeholder=placeholder,
    )


def test_whitespace_only_file_is_rejected_and_its_old_document_dropped(tmp_path: Path):
    blank = tmp_path / "blank.txt"
    blank.write_text("  \n\t\n", encoding="utf-8")
    gateway, counters = _ingest_one(tmp_path, _candidate(blank), ExistingDocStat(exists=False))

    assert counters.rejected == 1
    assert counters.failed == 0
    candidate = _candidate(blank)
    gateway.record_no_text.assert_called_once_with(
        9,
        "src",
        str(blank),
        byte_size=candidate.size,
        mtime=candidate.mtime.timestamp(),
        source_sha256=file_sha256(blank).hex(),
    )
    gateway.replace_document.assert_not_called()


@pytest.mark.parametrize("name", ["blank.py", "blank.docx"])
def test_extractor_that_finds_no_text_is_no_text_not_a_failure(tmp_path: Path, name: str):
    """The code and Office extractors report a file without text as NoTextFound too."""
    path = tmp_path / name
    if path.suffix == ".docx":
        import docx

        docx.Document().save(str(path))
    else:
        path.write_text("   \n\n\t\n", encoding="utf-8")
    gateway, counters = _ingest_one(tmp_path, _candidate(path), ExistingDocStat(exists=False))

    assert counters.rejected == 1
    assert counters.failed == 0
    gateway.record_no_text.assert_called_once()
    gateway.record_extract_failed.assert_not_called()


@pytest.mark.parametrize("state", ["no_text", "failed"])
def test_remembered_outcome_with_unchanged_stat_is_not_read_again(tmp_path: Path, state: str):
    """A textless image is not OCR'd, and a failed file not retried, while its stat is unchanged."""
    photo = tmp_path / "photo.png"
    photo.write_bytes(b"not really a png")
    candidate = _candidate(photo)
    existing = ExistingDocStat(
        exists=True, byte_size=candidate.size, mtime=candidate.mtime.timestamp(), state=state, source_sha256="ab" * 32
    )
    with patch("garage_rag.ingest.pipeline.extract") as extract:
        gateway, counters = _ingest_one(tmp_path, candidate, existing)

    extract.assert_not_called()
    assert counters.skipped == 1
    assert counters.failed == 0
    gateway.record_seen.assert_called_once_with(9, "src", str(photo))


def test_remembered_no_text_with_unchanged_bytes_refreshes_its_stat(tmp_path: Path):
    photo = tmp_path / "photo.png"
    photo.write_bytes(b"not really a png")
    raw = file_sha256(photo)
    assert raw is not None
    candidate = _candidate(photo)
    existing = ExistingDocStat(
        exists=True,
        byte_size=candidate.size,
        mtime=candidate.mtime.timestamp() - 60,
        state="no_text",
        source_sha256=raw.hex(),
    )
    with patch("garage_rag.ingest.pipeline.extract") as extract:
        gateway, counters = _ingest_one(tmp_path, candidate, existing)

    extract.assert_not_called()
    assert counters.skipped == 1
    gateway.record_no_text.assert_called_once_with(
        9, "src", str(photo), byte_size=candidate.size, mtime=candidate.mtime.timestamp(), source_sha256=raw.hex()
    )


def test_failed_document_without_a_current_outcome_is_retried(tmp_path: Path):
    """A document left in EXTRACT_FAILED is retried when no outcome for the current
    extractor version says to skip it, even with an unchanged stat and hash."""
    doc = tmp_path / "broken.pdf"
    doc.write_bytes(b"%PDF-1.4 unchanged")
    candidate = _candidate(doc)
    existing = ExistingDocStat(
        exists=True,
        byte_size=candidate.size,
        mtime=candidate.mtime.timestamp(),
        content_sha256="cd" * 32,
        state="extract_failed",
        source_sha256=file_sha256(doc).hex(),
    )
    with patch("garage_rag.ingest.pipeline.extract", side_effect=ExtractionError("still broken")) as extract:
        _, counters = _ingest_one(tmp_path, candidate, existing)

    extract.assert_called_once()
    assert counters.failed == 1


def test_remembered_failure_is_retried_when_the_bytes_change(tmp_path: Path):
    doc = tmp_path / "broken.pdf"
    doc.write_bytes(b"%PDF-1.4 changed")
    candidate = _candidate(doc)
    existing = ExistingDocStat(
        exists=True,
        byte_size=candidate.size,
        mtime=candidate.mtime.timestamp() - 60,
        state="failed",
        source_sha256="ab" * 32,
    )
    with patch("garage_rag.ingest.pipeline.extract", side_effect=ExtractionError("still broken")) as extract:
        gateway, counters = _ingest_one(tmp_path, candidate, existing)

    extract.assert_called_once()
    assert counters.failed == 1
    gateway.record_extract_failed.assert_called_once_with(
        9,
        "src",
        str(doc),
        "still broken",
        byte_size=candidate.size,
        mtime=candidate.mtime.timestamp(),
        source_sha256=file_sha256(doc).hex(),
    )


def test_unmaterialized_placeholder_writes_no_document(tmp_path: Path):
    stub = tmp_path / "stub.pdf"
    stub.write_bytes(b"")
    with patch("garage_rag.ingest.pipeline.ensure_local", side_effect=PlaceholderFile(stub, "Dropbox")):
        gateway, counters = _ingest_one(tmp_path, _candidate(stub, placeholder=True), ExistingDocStat(exists=False))

    assert counters.placeholders == 1
    gateway.record_placeholder.assert_called_once()
    gateway.replace_document.assert_not_called()


def test_a_placeholder_found_at_extraction_is_a_placeholder_not_a_failure(tmp_path: Path):
    """extract() checks for a cloud stub itself; that PlaceholderFile must not reach
    the per-candidate error handler, which would count the file as an ingest error."""
    stub = tmp_path / "online-only.pdf"
    stub.write_bytes(b"%PDF-1.4 dataless stand-in")
    candidate = _candidate(stub)
    with patch("garage_rag.ingest.pipeline.extract", side_effect=PlaceholderFile(stub, "iCloud Drive")):
        gateway, counters = _ingest_one(tmp_path, candidate, ExistingDocStat(exists=False))

    assert counters.placeholders == 1
    assert counters.failed == 0
    assert counters.errors == []
    gateway.record_placeholder.assert_called_once_with(
        9, "src", str(stub), candidate.mtime.timestamp(), stub.stem, "not materialized"
    )
    gateway.record_extract_failed.assert_not_called()
    gateway.record_no_text.assert_not_called()
    gateway.replace_document.assert_not_called()


def test_a_read_the_kernel_refused_is_a_placeholder_not_a_failure(tmp_path: Path):
    import errno

    stub = tmp_path / "online-only.pdf"
    stub.write_bytes(b"%PDF-1.4 dataless stand-in")
    refused = OSError(errno.EDEADLK, "Resource deadlock avoided")
    with patch("garage_rag.ingest.pipeline.extract", side_effect=refused):
        gateway, counters = _ingest_one(tmp_path, _candidate(stub), ExistingDocStat(exists=False))

    assert counters.placeholders == 1
    assert counters.failed == 0
    gateway.record_placeholder.assert_called_once()
    gateway.record_extract_failed.assert_not_called()
    gateway.replace_document.assert_not_called()


def test_ingest_source_runs_with_dataless_reads_refused(tmp_path: Path):
    entered: list[bool] = []

    @contextmanager
    def fake_guard():
        entered.append(True)
        yield

    inner = MagicMock(return_value=(IngestCounters(), None, MaterializationBudget()))
    with (
        patch("garage_rag.ingest.pipeline.refusing_dataless_reads", fake_guard),
        patch("garage_rag.ingest.pipeline._ingest_source", inner),
    ):
        ingest_source(gateway=MagicMock(), source_slug="src")

    assert entered == [True]
    inner.assert_called_once()


def test_sql_record_placeholder_only_records_the_file_as_seen(tmp_path: Path):
    session = MagicMock()
    session.__enter__.return_value = session
    session.query.return_value.filter_by.return_value.one_or_none.return_value = _mock_source(tmp_path)
    gateway = SqlAlchemyIngestStorageGateway(session_factory=lambda: session)

    with patch.object(gateway, "record_seen") as record_seen:
        gateway.record_placeholder(5, "seen-src", "/cloud/stub.pdf", 1.7e9, "stub")

    session.add.assert_not_called()
    record_seen.assert_called_once_with(5, "seen-src", "/cloud/stub.pdf")


@pytest.mark.parametrize("state", ["ok", "placeholder"])
def test_evicted_placeholder_with_unchanged_mtime_is_not_downloaded(tmp_path: Path, state: str):
    """Dropbox evicted a file that was already indexed: skip it on mtime without opening it."""
    stub = tmp_path / "report.pdf"
    stub.write_bytes(b"")
    candidate = _candidate(stub, placeholder=True)
    existing = ExistingDocStat(
        exists=True,
        byte_size=48_213,
        mtime=candidate.mtime.timestamp(),
        content_sha256="ab" * 32,
        state=state,
    )
    with patch("garage_rag.ingest.pipeline.ensure_local") as ensure_local:
        gateway, counters = _ingest_one(tmp_path, candidate, existing)

    ensure_local.assert_not_called()
    assert counters.skipped == 1
    gateway.record_seen.assert_called_once_with(9, "src", str(stub))


def test_placeholder_changed_in_the_cloud_is_downloaded(tmp_path: Path):
    stub = tmp_path / "report.pdf"
    stub.write_bytes(b"")
    candidate = _candidate(stub, placeholder=True)
    existing = ExistingDocStat(
        exists=True, byte_size=48_213, mtime=candidate.mtime.timestamp() - 3600, content_sha256="ab" * 32, state="ok"
    )
    with patch("garage_rag.ingest.pipeline.ensure_local", side_effect=PlaceholderFile(stub)) as ensure_local:
        _, counters = _ingest_one(tmp_path, candidate, existing)

    ensure_local.assert_called_once()
    assert counters.placeholders == 1


def test_file_placeholder_with_a_new_size_is_downloaded(tmp_path: Path):
    """A File Provider stub reports its real size, so a size change counts even at the same mtime."""
    stub = tmp_path / "report.pdf"
    stub.write_bytes(b"")
    candidate = _candidate(stub, placeholder=True, size=50_000)
    existing = ExistingDocStat(
        exists=True, byte_size=48_213, mtime=candidate.mtime.timestamp(), content_sha256="ab" * 32, state="ok"
    )
    with patch("garage_rag.ingest.pipeline.ensure_local", side_effect=PlaceholderFile(stub)) as ensure_local:
        _ingest_one(tmp_path, candidate, existing)

    ensure_local.assert_called_once()


def test_touched_file_with_unchanged_bytes_skips_extraction(tmp_path: Path):
    note = tmp_path / "note.txt"
    note.write_text("Same bytes, new mtime", encoding="utf-8")
    raw = file_sha256(note)
    assert raw is not None
    candidate = _candidate(note)
    existing = ExistingDocStat(
        exists=True,
        byte_size=candidate.size,
        mtime=candidate.mtime.timestamp() - 3600,
        content_sha256="cd" * 32,
        state="ok",
        source_sha256=raw.hex(),
    )
    with patch("garage_rag.ingest.pipeline.extract") as extract:
        gateway, counters = _ingest_one(tmp_path, candidate, existing)

    extract.assert_not_called()
    assert counters.skipped == 1
    gateway.refresh_metadata.assert_called_once_with(
        9, "src", str(note), candidate.size, candidate.mtime.timestamp(), raw.hex(), "", ""
    )


def test_force_reindexes_despite_an_unchanged_source_hash(tmp_path: Path):
    note = tmp_path / "note.txt"
    note.write_text("Same bytes, forced", encoding="utf-8")
    raw = file_sha256(note)
    assert raw is not None
    candidate = _candidate(note)
    existing = ExistingDocStat(
        exists=True, byte_size=candidate.size, mtime=candidate.mtime.timestamp(), state="ok", source_sha256=raw.hex()
    )
    with patch("garage_rag.attribute.resolver.ensure_self_author"):
        gateway, counters = _ingest_one(tmp_path, candidate, existing, force=True)

    gateway.refresh_metadata.assert_not_called()
    gateway.replace_document.assert_called_once()


def test_image_without_text_is_rejected_not_failed(tmp_path: Path):
    """An image OCR finds no text in is an outcome, not an error: rejected, no error recorded."""
    from garage_rag.extract.base import NoTextFound

    (tmp_path / "photo.txt").write_text("stands in for an image", encoding="utf-8")
    mock_source = _mock_source(tmp_path)

    def fake_query(model, *cols):
        q = MagicMock()
        q.filter_by.return_value.one_or_none.return_value = mock_source if model is Source else None
        return q

    session = MagicMock()
    session.query.side_effect = fake_query
    session.__enter__.return_value = session
    gateway = SqlAlchemyIngestStorageGateway(session_factory=lambda: session)
    fake_run = MagicMock()
    fake_run.id = 5

    with (
        patch("garage_rag.attribute.resolver.ensure_self_author"),
        patch("garage_rag.db.models.IngestRun", return_value=fake_run),
        patch("garage_rag.ingest.pipeline.extract", side_effect=NoTextFound("no usable text in image")),
        patch.object(gateway, "record_no_text") as record_no_text,
        patch.object(gateway, "record_extract_failed") as record_extract_failed,
    ):
        counters, _, _ = ingest_source(gateway=gateway, source_slug="seen-src")

    assert counters.rejected == 1
    assert counters.failed == 0
    assert counters.errors == []
    record_no_text.assert_called_once()
    assert record_no_text.call_args.args == (5, "seen-src", str(tmp_path / "photo.txt"))
    record_extract_failed.assert_not_called()


def test_unexpected_ingest_error_is_recorded_as_seen(tmp_path: Path):
    (tmp_path / "boom.txt").write_text("this one explodes", encoding="utf-8")
    mock_source = _mock_source(tmp_path)

    def fake_query(model, *cols):
        q = MagicMock()
        q.filter_by.return_value.one_or_none.return_value = mock_source if model is Source else None
        return q

    session = MagicMock()
    session.query.side_effect = fake_query
    session.__enter__.return_value = session
    gateway = SqlAlchemyIngestStorageGateway(session_factory=lambda: session)
    fake_run = MagicMock()
    fake_run.id = 4

    with (
        patch("garage_rag.attribute.resolver.ensure_self_author"),
        patch("garage_rag.db.models.IngestRun", return_value=fake_run),
        patch("garage_rag.ingest.pipeline.ingest_one", side_effect=RuntimeError("kaboom")),
        patch.object(gateway, "record_seen") as record_seen,
    ):
        counters, _, _ = ingest_source(gateway=gateway, source_slug="seen-src")

    assert counters.failed == 1
    assert counters.errors == ["boom.txt: kaboom"]
    record_seen.assert_called_once_with(4, "seen-src", str(tmp_path / "boom.txt"))


def test_materialize_timeout_returns_within_budget(tmp_path: Path):
    """A read stalled on the sync client must not hold the run past ``timeout_seconds``.

    The old ``with ThreadPoolExecutor(...)`` joined the stuck worker on exit, so a
    0.2s timeout still waited for the whole read."""
    stub = tmp_path / "stub.pdf"
    stub.write_bytes(b"")
    release = threading.Event()

    def stalled_read(path: Path) -> int:
        release.wait(10.0)
        return 0

    budget = MaterializationBudget(enabled=True, timeout_seconds=0.2)
    with patch.object(materialize_mod, "_force_read", stalled_read):
        started = time.monotonic()
        try:
            ok = materialize(stub, budget)
            elapsed = time.monotonic() - started
        finally:
            release.set()  # let the orphaned worker finish so the interpreter exits cleanly

    assert ok is False
    assert elapsed < 2.0, f"materialize blocked for {elapsed:.2f}s despite a 0.2s timeout"
    assert budget.failed == 1
    assert budget.files_done == 0
    assert budget.bytes_done == 0


def test_materialize_still_placeholder_does_not_consume_budget(tmp_path: Path):
    """An empty read-back is a failure, not a download, so it must not count against
    ``max_files``/``max_bytes``."""
    stub = tmp_path / "stub.pdf"
    stub.write_bytes(b"")
    budget = MaterializationBudget(enabled=True, max_files=1)

    with patch.object(materialize_mod, "_force_read", return_value=0):
        assert materialize(stub, budget) is False

    assert budget.failed == 1
    assert budget.files_done == 0
    assert budget.bytes_done == 0
    assert not budget.exhausted


def test_chunk_offset_zero_survives_the_grpc_facade():
    """0 is a real offset (the first chunk); only an unknown offset may be unset."""
    from garage_rag.proto.garage_pb2 import DocumentChunkPayload, PersistDocumentRequest
    from garage_rag.service.server import GarageRpcServicer

    client = GarageClient(in_process=True)
    gateway = GrpcIngestStorageGateway(client)
    with patch.object(client, "persist_document") as mock_doc:
        mock_doc.return_value = PersistDocumentResponse(success=True, chunks_written=2)
        gateway.replace_document(
            run_id=1,
            source_slug="s",
            uri="a.md",
            title="A",
            lang="en",
            byte_size=10,
            mtime=0.0,
            source_sha256="aa",
            content_sha256="bb",
            extractor="text",
            extractor_version="1",
            chunker="recursive",
            content="first second",
            meta={},
            corpus_class="document",
            trust_tier="authored",
            authors=[],
            chunks=[
                ChunkPayload(
                    ord=0, text="first", char_start=0, char_end=5, chunk_sha256="01", direction="sent", sender="me"
                ),
                ChunkPayload(ord=1, text="reflowed", chunk_sha256="02"),
            ],
        )
    sent = mock_doc.call_args.args[0].chunks
    assert sent[0].HasField("char_start") and sent[0].char_start == 0
    assert not sent[1].HasField("char_start")
    assert [(c.direction, c.sender) for c in sent] == [("sent", "me"), ("", "")]

    server_side = MagicMock()
    server_side.replace_document.return_value = 2
    request = PersistDocumentRequest(
        run_id=1,
        source_slug="s",
        uri="a.md",
        action="replace",
        chunks=[
            DocumentChunkPayload(
                ord=0, text="first", char_start=0, char_end=5, chunk_sha256="01", direction="received", sender="a@b.c"
            ),
            DocumentChunkPayload(ord=1, text="reflowed", chunk_sha256="02"),
        ],
    )
    with patch.object(GarageRpcServicer, "_ingest_gateway", return_value=server_side):
        GarageRpcServicer().PersistDocument(request, MagicMock())
    received = server_side.replace_document.call_args.kwargs["chunks"]
    assert (received[0].char_start, received[0].char_end) == (0, 5)
    assert (received[1].char_start, received[1].char_end) == (None, None)
    # Empty proto strings arrive as None, so a chunk that is not a message has no direction.
    assert [(c.direction, c.sender) for c in received] == [("received", "a@b.c"), (None, None)]


def test_session_kind_crosses_the_grpc_facade():
    """The scanner is chosen by kind; over gRPC it used to arrive as "filesystem"."""
    from garage_rag.ingest.gateway import SourceContext
    from garage_rag.proto.garage_pb2 import BeginIngestSessionRequest
    from garage_rag.service.server import GarageRpcServicer

    server_side = MagicMock()
    server_side.begin_session.return_value = SourceContext(
        source_id=7,
        slug="apple-sms",
        root=Path("/Users/me/Library/Messages"),
        default_class=CorpusClass.COMMUNICATION,
        default_trust=TrustTier.RECEIVED,
        run_id=3,
        kind="sqlite",
        source_slugs=["apple-sms"],
    )
    with patch.object(GarageRpcServicer, "_ingest_gateway", return_value=server_side):
        response = GarageRpcServicer().BeginIngestSession(
            BeginIngestSessionRequest(source_slug="apple-sms"), MagicMock()
        )
    assert response.kind == "sqlite"

    client = GarageClient(in_process=True)
    with patch.object(client, "begin_ingest_session", return_value=response):
        ctx = GrpcIngestStorageGateway(client).begin_session("apple-sms")
    assert ctx.kind == "sqlite"


def _chunk_row(id: int, ord: int, text: str, sha: bytes, chunker: str = "markdown", fact_id: int | None = None):
    """A stored ``chunks`` row as replace_document reads it back."""
    from types import SimpleNamespace

    return SimpleNamespace(
        id=id,
        ord=ord,
        text=text,
        chunk_sha256=sha,
        chunker=chunker,
        fact_id=fact_id,
        token_count=None,
        char_start=0,
        char_end=len(text),
        heading_path=None,
    )


def test_replace_document_keeps_unchanged_chunks_and_replaces_the_rest():
    """A chunk whose ord, hash, text and chunker are unchanged keeps its row (and so its
    vectors in every model table); every other chunk, and every fact chunk, is replaced."""
    from garage_rag.db.models import Chunk

    unchanged = _chunk_row(101, 0, "Intro paragraph.", b"\x01")
    edited = _chunk_row(102, 1, "Old second paragraph.", b"\x02")
    rechunked = _chunk_row(103, 2, "Same text, new chunker.", b"\x03")
    fact = _chunk_row(104, 3, "A fact.", b"\x04", chunker="facts:default", fact_id=9)
    dropped = _chunk_row(105, 4, "A paragraph the new version cut.", b"\x05")

    source = MagicMock(spec=Source)
    source.id = 1
    source.default_class = CorpusClass.DOCUMENT
    source.default_trust = TrustTier.AUTHORED
    doc = MagicMock()
    doc.id = 7

    session = MagicMock()
    session.__enter__.return_value = session
    chunk_query = MagicMock()
    chunk_query.filter.return_value.all.return_value = [unchanged, edited, rechunked, fact, dropped]
    by_entity = {Source: source, Document: doc}

    def query(entity, *rest):
        if entity is Chunk:
            return chunk_query
        found = MagicMock()
        found.filter_by.return_value.one_or_none.return_value = by_entity.get(entity)
        return found

    session.query.side_effect = query
    gateway = SqlAlchemyIngestStorageGateway(session_factory=lambda: session)

    written = gateway.replace_document(
        run_id=0,
        source_slug="notes",
        uri="note.md",
        title="Note",
        lang="en",
        byte_size=100,
        mtime=1700000000.0,
        source_sha256="aa",
        content_sha256="bb",
        extractor="text",
        extractor_version="1",
        chunker="markdown",
        content="...",
        meta={},
        corpus_class="document",
        trust_tier="authored",
        authors=[],
        chunks=[
            ChunkPayload(
                ord=0,
                text="Intro paragraph.",
                chunk_sha256="01",
                char_start=5,
                char_end=21,
                heading_path="H",
                direction="sent",
                sender="me",
            ),
            ChunkPayload(
                ord=1, text="New second paragraph.", chunk_sha256="12", direction="received", sender="+15551234567"
            ),
            ChunkPayload(ord=2, text="Same text, new chunker.", chunk_sha256="03", chunker="heading"),
        ],
    )

    assert written == 3
    # Only the stale rows are deleted and let go of; the unchanged one stays in the session.
    chunk_query.filter.return_value.delete.assert_called_once_with(synchronize_session=False)
    expunged = [c.args[0] for c in session.expunge.call_args_list]
    assert expunged == [edited, rechunked, fact, dropped]
    # The kept row is updated in place with the new offsets and heading, not re-added.
    # A message chunk's direction and sender are rewritten in place too: they cost no re-embedding.
    assert (unchanged.char_start, unchanged.char_end, unchanged.heading_path) == (5, 21, "H")
    assert (unchanged.direction, unchanged.sender) == ("sent", "me")
    added = [c.args[0] for c in session.add.call_args_list]
    assert all(isinstance(row, Chunk) for row in added)
    assert [(row.ord, row.text, row.chunker, bytes(row.chunk_sha256)) for row in added] == [
        (1, "New second paragraph.", "markdown", b"\x12"),
        (2, "Same text, new chunker.", "heading", b"\x03"),
    ]
    assert [(row.direction, row.sender) for row in added] == [("received", "+15551234567"), (None, None)]
    session.commit.assert_called_once()


def test_replace_document_with_identical_chunks_deletes_nothing():
    from garage_rag.db.models import Chunk

    rows = [_chunk_row(201, 0, "One.", b"\xaa"), _chunk_row(202, 1, "Two.", b"\xbb")]
    source = MagicMock(spec=Source)
    source.id = 1
    source.default_class = CorpusClass.DOCUMENT
    source.default_trust = TrustTier.AUTHORED
    doc = MagicMock()
    doc.id = 8

    session = MagicMock()
    session.__enter__.return_value = session
    chunk_query = MagicMock()
    chunk_query.filter.return_value.all.return_value = rows
    by_entity = {Source: source, Document: doc}

    def query(entity, *rest):
        if entity is Chunk:
            return chunk_query
        found = MagicMock()
        found.filter_by.return_value.one_or_none.return_value = by_entity.get(entity)
        return found

    session.query.side_effect = query
    gateway = SqlAlchemyIngestStorageGateway(session_factory=lambda: session)
    gateway.replace_document(
        run_id=0,
        source_slug="notes",
        uri="same.md",
        title="Same",
        lang="en",
        byte_size=8,
        mtime=0.0,
        source_sha256="cc",
        content_sha256="dd",
        extractor="text",
        extractor_version="1",
        chunker="markdown",
        content="One. Two.",
        meta={},
        corpus_class="document",
        trust_tier="authored",
        authors=[],
        chunks=[
            ChunkPayload(ord=0, text="One.", chunk_sha256=b"\xaa"),
            ChunkPayload(ord=1, text="Two.", chunk_sha256="bb"),
        ],
    )

    chunk_query.filter.return_value.delete.assert_not_called()
    session.expunge.assert_not_called()
    session.add.assert_not_called()


def test_persist_document_larger_than_grpcs_default_limit_is_accepted(grpc_server):
    """PersistDocument carries a document's whole text; a long Messages thread outgrows gRPC's
    4 MiB default, which the server raises so such a document can be stored at all."""
    from garage_rag.proto.garage_pb2 import DocumentChunkPayload
    from garage_rag.proto.garage_pb2_grpc import GarageServiceStub

    port, _ = grpc_server
    content = "a long thread of messages. " * (6 * 1024 * 1024 // 27)
    assert len(content) > 4 * 1024 * 1024
    server_side = MagicMock()
    server_side.replace_document.return_value = 1
    request = PersistDocumentRequest(
        run_id=1,
        source_slug="apple-sms",
        uri="thread-1",
        action="replace",
        content=content,
        chunks=[DocumentChunkPayload(ord=0, text=content[:1000], chunk_sha256="01")],
    )
    with (
        patch.object(GarageRpcServicer, "_ingest_gateway", return_value=server_side),
        grpc.insecure_channel(f"127.0.0.1:{port}") as channel,
    ):
        response = GarageServiceStub(channel).PersistDocument(request)
    assert response.success
    assert server_side.replace_document.call_args.kwargs["content"] == content


def _replace_over(existing: list) -> dict[type, MagicMock]:
    """Re-ingest one document whose stored chunks are ``existing``; return each queried model's mock."""
    source = MagicMock(spec=Source)
    source.id = 1
    source.default_class = CorpusClass.DOCUMENT
    source.default_trust = TrustTier.AUTHORED
    doc = MagicMock()
    doc.id = 9
    by_entity = {Source: source, Document: doc}
    queries: dict[type, MagicMock] = {}

    def query(entity, *rest):
        q = queries.setdefault(entity, MagicMock())
        q.filter_by.return_value.one_or_none.return_value = by_entity.get(entity)
        q.filter.return_value.all.return_value = existing
        return q

    session = MagicMock()
    session.__enter__.return_value = session
    session.query.side_effect = query
    SqlAlchemyIngestStorageGateway(session_factory=lambda: session).replace_document(
        run_id=0,
        source_slug="notes",
        uri="note.md",
        title="Note",
        lang="en",
        byte_size=100,
        mtime=1700000000.0,
        source_sha256="aa",
        content_sha256="bb",
        extractor="text",
        extractor_version="1",
        chunker="markdown",
        content="One.",
        meta={},
        corpus_class="document",
        trust_tier="authored",
        authors=[],
        chunks=[ChunkPayload(ord=0, text="One.", chunk_sha256="aa")],
    )
    return queries


def test_force_reingest_that_drops_fact_chunks_clears_the_document_fact_runs():
    """Re-index Everything keeps the text but drops the fact chunks; the document's fact_runs go with
    them, so a stale-only Glean Facts extracts it again instead of counting it as current."""
    from garage_rag.db.models import FactRun
    from garage_rag.enrich.facts import default_prompt, is_stale

    queries = _replace_over(
        [_chunk_row(301, 0, "One.", b"\xaa"), _chunk_row(302, 1, "A fact.", b"\x04", chunker="facts:x", fact_id=5)]
    )

    fact_runs = queries[FactRun]
    fact_runs.filter.return_value.delete.assert_called_once_with(synchronize_session=False)
    (criterion,) = fact_runs.filter.call_args.args
    assert str(criterion.compile(compile_kwargs={"literal_binds": True})) == "fact_runs.document_id = 9"
    # With its run gone, the document reads as stale whatever its content hash.
    assert is_stale(None, MagicMock(spec=Document, content_sha256=b"\xbb"), default_prompt(), "m")


def test_reingest_without_fact_chunks_keeps_the_fact_runs():
    from garage_rag.db.models import FactRun

    queries = _replace_over([_chunk_row(311, 0, "Old one.", b"\x01")])

    assert FactRun not in queries
