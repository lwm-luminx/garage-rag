"""The ingest pipeline.

Idempotency contract, per document, each in its own transaction so a crash
leaves earlier documents committed and the current one untouched:

1. **stat only.** If a row exists whose ``mtime`` and ``byte_size`` match and
   whose state is OK, skip -- without opening or parsing the file. A cloud
   placeholder whose row still holds content is judged by ``mtime`` alone when
   the stub reports no size, and is skipped without being materialized: it was
   indexed before the sync client evicted it, and nothing has changed since.
   A file remembered in ``ingest_outcomes`` as holding no text, or as failing
   extraction, is skipped the same way while its extractor's version is the one
   that gave up on it.
2. **raw hash.** If the stat changed but ``source_sha256`` did not (a touch, a
   copy that kept the bytes), refresh the stat fields and skip extraction.
3. **extract**, then hash the extracted text. A file with no text makes no
   document: any older row for it is dropped, it is counted as rejected, and its
   stat and hash are remembered, as they are for a failed extraction.
4. If ``content_sha256`` is unchanged *and* the chunker signature is unchanged,
   the chunks are still valid: refresh the stat fields, done. (Embeddings are
   not touched here; ``garage backfill`` fills in missing model vectors.)
5. Otherwise replace: upsert the document, delete its chunks (which cascades
   into every per-model embedding table), re-chunk, insert.

The two hashes are not redundant. ``source_sha256`` is over raw bytes and is
refreshed whenever a file is opened. ``content_sha256`` is over extracted text
and drives step 4, so upgrading an extractor correctly rebuilds chunks even
though the file on disk never changed.

Every candidate the walk yields -- indexed, skipped, failed, or placeholder --
is recorded in ``ingest_seen`` for its run, because reconciliation treats any
document absent from the latest completed run's observations as deleted.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field
from pathlib import Path

from garage_rag.attribute.resolver import SelfIdentity, resolve
from garage_rag.config import get_settings
from garage_rag.extract.base import ContentKind, ExtractionError, ExtractResult, NoTextFound, file_sha256, sha256_text
from garage_rag.extract.contact_names import ContactNames
from garage_rag.extract.dispatch import IMAGE_EXTENSIONS, extract
from garage_rag.extract.placeholder import PlaceholderFile
from garage_rag.extract.quality import assess
from garage_rag.ingest.author_names import name_authors
from garage_rag.ingest.chunking import TextChunk, chunk_text, image_chunk
from garage_rag.ingest.classify import classify
from garage_rag.ingest.gateway import (
    AuthorPayload,
    ChunkPayload,
    ExistingDocStat,
    IngestStorageGateway,
    SourceContext,
    get_storage_gateway,
)
from garage_rag.ingest.materialize import (
    MaterializationBudget,
    ensure_local,
    refused_dataless_read,
    refusing_dataless_reads,
)
from garage_rag.ingest.scanner import scan_source
from garage_rag.ingest.walker import Candidate, SourceUnavailable, WalkStats, default_exclude_prefixes, walk

log = logging.getLogger(__name__)


@dataclass
class IngestCounters:
    seen: int = 0
    indexed: int = 0
    skipped: int = 0
    failed: int = 0
    placeholders: int = 0
    rejected: int = 0
    chunks_written: int = 0
    total_items: int = 0
    item_type: str = "items"
    errors: list[str] = field(default_factory=list)

    def note_error(self, message: str) -> None:
        self.failed += 1
        if len(self.errors) < 50:
            self.errors.append(message)


def _chunker_signature(result: ExtractResult, chunks: list[TextChunk]) -> str:
    """Identifies the chunking configuration that produced these chunks.

    Stored so a change in chunk size or strategy triggers a rebuild the same way
    a content change does.
    """
    label = chunks[0].chunker if chunks else "none"
    return f"{result.kind}:{label}"


def _stat_matches(existing: ExistingDocStat, candidate: Candidate) -> bool:
    """Whether ``candidate`` looks unchanged since ``existing`` was indexed, from its stat alone.

    A placeholder is compared on ``mtime`` only when it reports no size: older Dropbox
    stubs are zero bytes on disk, while File Provider stubs report the real size.
    """
    same_mtime = existing.mtime > 0 and abs(existing.mtime - candidate.mtime.timestamp()) < 1.0
    if not same_mtime:
        return False
    if candidate.placeholder and candidate.size == 0:
        return True
    return existing.byte_size == candidate.size


def _has_indexed_content(existing: ExistingDocStat) -> bool:
    """An OK row, or one an older build marked as a placeholder after indexing it."""
    state = existing.state.upper()
    if state == "OK":
        return True
    return state == "PLACEHOLDER" and bool(existing.content_sha256)


# Outcomes of a file that made no document, remembered (with its stat and hash) so an
# unchanged file is not extracted again. The gateway reports one only while the file's
# extractor is the version that produced it. A document in state EXTRACT_FAILED with no
# current outcome is not among them: it is retried.
_REMEMBERED_OUTCOMES = frozenset({"NO_TEXT", "FAILED"})


def _is_settled(existing: ExistingDocStat) -> bool:
    """Whether an unchanged file needs nothing done: it is indexed, or known to hold no text or to fail."""
    return existing.exists and (_has_indexed_content(existing) or existing.state.upper() in _REMEMBERED_OUTCOMES)


def _reject_empty(
    gateway: IngestStorageGateway,
    source_ctx: SourceContext,
    candidate: Candidate,
    counters: IngestCounters,
    reason: str,
) -> None:
    """Nothing to index: no document for it, and any older one is dropped."""
    log.info("Rejected %s: %s", candidate.uri, reason)
    counters.rejected += 1
    gateway.record_rejected(source_ctx.run_id, source_ctx.slug, candidate.uri)


# Extensions whose extractor changed the content kind, with the chunker prefix a
# current row carries. A row without it was indexed by the old extractor, so an
# unchanged file is still re-extracted: ``.eml`` was plain text (a document), and
# is now mail (a communication, which must not leave the machine).
_CURRENT_CHUNKER_PREFIX = {".eml": f"{ContentKind.CONVERSATION}:"}


def _indexed_by_a_retired_extractor(path: Path, existing: ExistingDocStat) -> bool:
    """Whether indexed content came from an older extractor. A remembered outcome carries
    no chunker, and the gateway already drops one whose extractor has changed."""
    prefix = _CURRENT_CHUNKER_PREFIX.get(path.suffix.lower())
    return prefix is not None and _has_indexed_content(existing) and not existing.chunker.startswith(prefix)


def ingest_one(
    gateway: IngestStorageGateway,
    source_ctx: SourceContext,
    candidate: Candidate,
    *,
    self_identity: SelfIdentity,
    budget: MaterializationBudget,
    counters: IngestCounters,
    force: bool = False,
    contact_names: ContactNames | None = None,
) -> None:
    """Index a single file, replacing any previous version of it.

    ``contact_names`` names authors that arrive known only by an email address or number.
    """
    log.debug("Evaluating %s (size=%d bytes, placeholder=%s)", candidate.uri, candidate.size, candidate.placeholder)

    existing_stat = gateway.check_stat(source_ctx.slug, candidate.uri)

    # --- step 1: skip on unchanged stat, without opening the file -----------
    # For a placeholder this is what avoids a download: opening it is what fetches it.
    if (
        not force
        and _is_settled(existing_stat)
        and _stat_matches(existing_stat, candidate)
        and not _indexed_by_a_retired_extractor(candidate.path, existing_stat)
    ):
        log.debug(
            "Skipped %s: stat matches the %s recorded in DB%s",
            candidate.uri,
            existing_stat.state.lower(),
            " (placeholder left in the cloud)" if candidate.placeholder else "",
        )
        counters.skipped += 1
        gateway.record_seen(source_ctx.run_id, source_ctx.slug, candidate.uri)
        return

    # --- materialize if this is a cloud stub --------------------------------
    try:
        ensure_local(candidate.path, budget)
    except PlaceholderFile:
        # No document for a file with no local content; an older row, if any, keeps
        # its chunks until the file is downloaded again.
        log.info("Placeholder file %s not materialized; no document written", candidate.uri)
        counters.placeholders += 1
        gateway.record_placeholder(
            source_ctx.run_id,
            source_ctx.slug,
            candidate.uri,
            candidate.mtime.timestamp(),
            candidate.path.stem,
            "not materialized",
        )
        return

    # --- step 2: skip on unchanged bytes ---------------------------------------
    try:
        raw_hash_bytes = file_sha256(candidate.path)
        raw_hash_hex = raw_hash_bytes.hex() if raw_hash_bytes else None
    except OSError:
        raw_hash_hex = None

    if not force and raw_hash_hex and existing_stat.source_sha256 == raw_hash_hex and _is_settled(existing_stat):
        log.debug("Skipped %s: source hash %s unchanged, refreshing stat", candidate.uri, raw_hash_hex[:8])
        counters.skipped += 1
        state = existing_stat.state.upper()
        if state == "NO_TEXT":
            gateway.record_no_text(
                source_ctx.run_id,
                source_ctx.slug,
                candidate.uri,
                byte_size=candidate.size,
                mtime=candidate.mtime.timestamp(),
                source_sha256=raw_hash_hex,
            )
            return
        if state == "FAILED":
            # Its stored error stays; the next run hashes it again.
            gateway.record_seen(source_ctx.run_id, source_ctx.slug, candidate.uri)
            return
        # Empty class and trust leave the row's own values in place.
        gateway.refresh_metadata(
            source_ctx.run_id,
            source_ctx.slug,
            candidate.uri,
            candidate.size,
            candidate.mtime.timestamp(),
            raw_hash_hex,
            "",
            "",
        )
        return

    # --- step 3: extract ----------------------------------------------------
    log.debug("Extracting %s", candidate.uri)
    try:
        result = extract(candidate.path)
        log.debug(
            "Extraction succeeded for %s (%s, %d characters)", candidate.path.name, result.extractor, len(result.text)
        )
    except NoTextFound as exc:
        # Read fine and holds no text (empty, an icon, a photo): nothing to index, and
        # nothing wrong. This also drops a document an older version left, and
        # remembers the file so it is not read again while it stays the same.
        log.info("No text in %s: %s", candidate.uri, exc)
        counters.rejected += 1
        gateway.record_no_text(
            source_ctx.run_id,
            source_ctx.slug,
            candidate.uri,
            byte_size=candidate.size,
            mtime=candidate.mtime.timestamp(),
            source_sha256=raw_hash_hex or "",
        )
        return
    except (ExtractionError, OSError) as exc:
        if refused_dataless_read(exc):
            # The kernel declined to download it: a placeholder the budget did not cover
            # (materialization is off outside the materialize thread), not a broken file.
            log.info("Placeholder file %s left in the cloud; no document written", candidate.uri)
            counters.placeholders += 1
            gateway.record_placeholder(
                source_ctx.run_id,
                source_ctx.slug,
                candidate.uri,
                candidate.mtime.timestamp(),
                candidate.path.stem,
                "not materialized",
            )
            return
        counters.note_error(f"{candidate.path.name}: {exc}")
        log.warning("Extraction failed for %s: %s", candidate.uri, exc)
        gateway.record_extract_failed(
            source_ctx.run_id,
            source_ctx.slug,
            candidate.uri,
            str(exc),
            byte_size=candidate.size,
            mtime=candidate.mtime.timestamp(),
            source_sha256=raw_hash_hex or "",
        )
        return

    settings = get_settings()

    # Content-based backstop for machine output the path rules missed. A picture's
    # text is its file name, which is not prose to judge.
    if settings.reject_machine_generated and result.kind is not ContentKind.IMAGE:
        verdict = assess(result.text)
        if verdict.machine_generated:
            counters.rejected += 1
            log.info("Rejected machine-generated file %s: %s", candidate.path.name, verdict.reason_text)
            gateway.record_rejected(
                source_ctx.run_id,
                source_ctx.slug,
                candidate.uri,
            )
            return

    content_hash_bytes = sha256_text(result.text)
    content_hash_hex = content_hash_bytes.hex()

    chunks = chunk_text(result.text, result.kind, extension=candidate.path.suffix.lower())
    if not chunks:
        _reject_empty(gateway, source_ctx, candidate, counters, f"0 chunks from {len(result.text)} characters")
        return
    is_image_file = candidate.path.suffix.lower() in IMAGE_EXTENSIONS
    if settings.index_images and is_image_file and result.kind is not ContentKind.IMAGE:
        # A screenshot or scan: its text is chunked for the text models above, and one
        # image chunk lets an image embedding model embed the picture itself.
        chunks.append(image_chunk(result.title or candidate.path.stem, ord=len(chunks)))

    # Final safety net: no single document may dominate the index.
    truncated_chunks = 0
    if len(chunks) > settings.max_chunks_per_document:
        truncated_chunks = len(chunks) - settings.max_chunks_per_document
        chunks = chunks[: settings.max_chunks_per_document]
        log.info(
            "%s produced %d chunks; truncated to %d",
            candidate.path.name,
            len(chunks) + truncated_chunks,
            settings.max_chunks_per_document,
        )
    signature = _chunker_signature(result, chunks)

    corpus_class = classify(candidate.path, result.kind, source_default=source_ctx.default_class)
    attribution = resolve(
        candidate.path,
        Path(source_ctx.root),
        source_default_trust=source_ctx.default_trust,
        author_hints=result.author_hints,
        self_identity=self_identity,
        communication=result.kind is ContentKind.CONVERSATION,
    )

    # --- step 4: content unchanged -> keep chunks, refresh metadata ---------
    if (
        existing_stat.exists
        and not force
        and existing_stat.content_sha256 == content_hash_hex
        and existing_stat.chunker == signature
        and existing_stat.state.upper() == "OK"
    ):
        log.debug("Skipped %s: content hash %s unchanged, refreshing metadata", candidate.uri, content_hash_hex[:8])
        gateway.refresh_metadata(
            source_ctx.run_id,
            source_ctx.slug,
            candidate.uri,
            candidate.size,
            candidate.mtime.timestamp(),
            raw_hash_hex or "",
            corpus_class.value,
            attribution.trust.value,
        )
        counters.skipped += 1
        return

    # --- step 5: replace ----------------------------------------------------
    meta = {
        **result.meta,
        **attribution.meta,
        "attribution": attribution.evidence,
        **({"truncated_chunks": truncated_chunks} if truncated_chunks else {}),
    }

    authors = [
        AuthorPayload(
            name=cand.name,
            role=cand.role.value,
            confidence=cand.confidence,
            evidence=cand.evidence,
            identities=dict(cand.identity_pairs),
            is_self=self_identity.matches(name=cand.name, email=cand.email),
        )
        for cand in attribution.authors
        if cand.name
    ]
    authors = name_authors(authors, contact_names)

    chunk_payloads = [
        ChunkPayload(
            ord=chunk.ord,
            text=chunk.text,
            token_count=chunk.token_estimate,
            char_start=chunk.char_start,
            char_end=chunk.char_end,
            heading_path=chunk.heading_path,
            chunk_sha256=chunk.sha256.hex(),
            chunker=chunk.chunker,
        )
        for chunk in chunks
    ]

    written = gateway.replace_document(
        run_id=source_ctx.run_id,
        source_slug=source_ctx.slug,
        uri=candidate.uri,
        title=result.title,
        lang=result.lang,
        byte_size=candidate.size,
        mtime=candidate.mtime.timestamp(),
        source_sha256=raw_hash_hex,
        content_sha256=content_hash_hex,
        extractor=result.extractor,
        extractor_version=result.extractor_version,
        chunker=signature,
        content=result.text,
        meta=meta,
        corpus_class=corpus_class.value,
        trust_tier=attribution.trust.value,
        authors=authors,
        chunks=chunk_payloads,
    )

    counters.chunks_written += written
    counters.indexed += 1
    log.info(
        "Indexed %s -> %d chunks (%s, %s, author=%s)",
        candidate.path.name,
        written,
        corpus_class.name,
        attribution.trust.name,
        attribution.authors[0].name if attribution.authors else "unknown",
    )


def ingest_source(
    session_factory=None,
    source_slug: str = "",
    *,
    gateway: IngestStorageGateway | None = None,
    include_code: bool = False,
    limit: int | None = None,
    force: bool = False,
    progress=None,
    is_cancelled=None,
    contact_names: ContactNames | None = None,
) -> tuple[IngestCounters, WalkStats, MaterializationBudget]:
    """Walk and index one source, recording coverage for reconciliation.

    Runs with dataless-file materialization off on this thread, so the only read that
    can download a cloud placeholder is the budgeted one in ``materialize``.
    """
    with refusing_dataless_reads():
        return _ingest_source(
            session_factory,
            source_slug,
            gateway=gateway,
            include_code=include_code,
            limit=limit,
            force=force,
            progress=progress,
            is_cancelled=is_cancelled,
            contact_names=contact_names,
        )


def _ingest_source(
    session_factory=None,
    source_slug: str = "",
    *,
    gateway: IngestStorageGateway | None = None,
    include_code: bool = False,
    limit: int | None = None,
    force: bool = False,
    progress=None,
    is_cancelled=None,
    contact_names: ContactNames | None = None,
) -> tuple[IngestCounters, WalkStats, MaterializationBudget]:
    gw = get_storage_gateway(session_factory=session_factory, gateway=gateway)

    counters = IngestCounters()
    walk_stats = WalkStats()
    budget = MaterializationBudget.from_settings()

    source_ctx = gw.begin_session(source_slug, include_code=include_code)
    root = Path(source_ctx.root)
    source_class = source_ctx.default_class
    run_id = source_ctx.run_id

    log.info(
        "Beginning ingest_source for %r (id=%s, root=%s, class=%s, include_code=%s, limit=%s, force=%s)",
        source_slug,
        source_ctx.source_id,
        root,
        source_class.name,
        include_code,
        limit,
        force,
    )

    self_identity = SelfIdentity.from_settings()
    prefixes = default_exclude_prefixes(root)
    completed = False

    # --- Step 0: Scan Phase ---
    log.info("Starting source scan for %r...", source_slug)
    scan_result = scan_source(source_ctx, include_code=include_code)
    counters.total_items = scan_result.item_count
    counters.item_type = scan_result.item_type
    if scan_result.details.get("root_problem"):
        # A root that cannot be read would walk as empty and finish "complete" with nothing
        # seen. That is not up to date; it is a failed run, and the previous scan's count stays.
        problem = scan_result.error or "source root unavailable"
        counters.note_error(problem)
        _finalize(gw, run_id, source_slug, counters, budget, completed=False)
        raise SourceUnavailable(problem)
    log.info(
        "Source scan completed for %r in %.2fs: found %d %s",
        source_slug,
        scan_result.duration_seconds,
        scan_result.item_count,
        scan_result.item_type,
    )

    gw.persist_scan(source_slug, scan_result)

    def _call_progress(phase: str, current_item: str | None = None) -> None:
        if progress is None:
            return
        progress(
            counters,
            budget,
            total_items=counters.total_items,
            phase=phase,
            scan_result=scan_result,
            current_item=current_item,
        )

    _call_progress(phase="scan")

    if source_ctx.kind == "sqlite":
        # A Messages database is read conversation by conversation, not walked.
        from garage_rag.ingest.conversations import ingest_messages_source

        try:
            completed = ingest_messages_source(
                gw,
                source_ctx,
                counters,
                self_identity=self_identity,
                force=force,
                limit=limit,
                is_cancelled=is_cancelled,
                on_item=lambda title: _call_progress(phase="ingest", current_item=title),
                contact_names=contact_names,
            )
        finally:
            _finalize(gw, run_id, source_slug, counters, budget, completed=completed)
        if is_cancelled is not None and is_cancelled():
            _call_progress(phase="cancelled")
        return counters, walk_stats, budget

    log.info("Starting file walk for %r (root=%s)", source_slug, root)
    try:
        for candidate in walk(
            root,
            include_code=include_code,
            exclude_prefixes=prefixes,
            stats=walk_stats,
        ):
            if is_cancelled is not None and is_cancelled():
                log.info("Ingest cancelled by user for source %s", source_slug)
                _call_progress(phase="cancelled", current_item=candidate.path.name)
                break

            counters.seen += 1
            try:
                ingest_one(
                    gw,
                    source_ctx,
                    candidate,
                    self_identity=self_identity,
                    budget=budget,
                    counters=counters,
                    force=force,
                    contact_names=contact_names,
                )
            except Exception as exc:  # noqa: BLE001 - one file must not end the run
                counters.note_error(f"{candidate.path.name}: {exc}")
                log.warning("Ingest failed for %s: %s", candidate.path, exc, exc_info=True)
                # The file is still there; without a seen row reconcile would treat it as deleted.
                try:
                    gw.record_seen(run_id, source_slug, candidate.uri)
                except Exception as seen_exc:  # noqa: BLE001
                    log.warning("Could not record %s as seen: %s", candidate.path, seen_exc)

            _call_progress(phase="ingest", current_item=candidate.path.name)
            if limit is not None and counters.seen >= limit:
                log.info("Hit candidate limit (%d) for source %r", limit, source_slug)
                break
        else:
            # Only a walk that ran to exhaustion counts as full coverage; a
            # ``limit`` or cancellation breaks out before the else clause.
            completed = True
    finally:
        _finalize(gw, run_id, source_slug, counters, budget, completed=completed)

    return counters, walk_stats, budget


def _finalize(
    gw: IngestStorageGateway,
    run_id: int,
    source_slug: str,
    counters: IngestCounters,
    budget: MaterializationBudget,
    *,
    completed: bool,
) -> None:
    """Close the run, recording whether it covered the whole source."""
    gw.finalize_session(
        run_id=run_id,
        completed=completed,
        seen=counters.seen,
        indexed=counters.indexed,
        skipped=counters.skipped,
        failed=counters.failed,
        placeholders=counters.placeholders,
        materialized=budget.files_done,
        materialized_bytes=budget.bytes_done,
        errors=counters.errors,
    )

    log.info(
        "Finished ingest for %r: total_items=%d, seen=%d, indexed=%d, skipped=%d, failed=%d, "
        "placeholders=%d, chunks=%d, errors=%d",
        source_slug,
        counters.total_items,
        counters.seen,
        counters.indexed,
        counters.skipped,
        counters.failed,
        counters.placeholders,
        counters.chunks_written,
        len(counters.errors),
    )
