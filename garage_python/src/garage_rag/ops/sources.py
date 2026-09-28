"""Registering, removing, scanning and syncing sources."""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field
from pathlib import Path
from typing import Literal

from pydantic import ValidationError
from sqlalchemy import func

from garage_rag.config import (
    CONFIG_FILENAME,
    ConfigError,
    Settings,
    expand_home,
    flatten,
    get_settings,
    read_config_document,
    save_config,
)
from garage_rag.db.engine import session_scope
from garage_rag.db.models import CorpusClass, Document, Source, TrustTier
from garage_rag.ingest.scanner import SourceScanResult, persist_scan_result, scan_source


class SourceArgumentError(ValueError):
    """A rejected argument, naming the parameter so the CLI can point at it."""

    def __init__(self, message: str, param_hint: str) -> None:
        super().__init__(message)
        self.param_hint = param_hint


@dataclass
class AddSourceResult:
    slug: str
    root: Path
    corpus_class: CorpusClass
    trust: TrustTier
    created: bool

    @property
    def message(self) -> str:
        if self.created:
            return f"added source {self.slug} -> {self.root} ({self.corpus_class}/{self.trust})"
        return f"updated source {self.slug} -> {self.root}"


def add_source(
    slug: str,
    root: str | Path,
    *,
    kind: str = "filesystem",
    corpus_class: str = "document",
    trust: str = "authored",
) -> AddSourceResult:
    """Register a source root, or update the one already registered under ``slug``."""
    tier = TrustTier(trust)
    klass = CorpusClass(corpus_class)

    expanded = expand_home(root)
    try:
        expanded.stat()
    except PermissionError:
        # A sandboxed caller (the App Store build's XPC service) may not look outside its container;
        # the ingest service, which holds the folder grant, reads the root.
        pass
    except OSError:
        raise SourceArgumentError(f"{expanded} does not exist", "ROOT") from None

    with session_scope() as session:
        existing = session.query(Source).filter_by(slug=slug).one_or_none()
        if existing is not None:
            existing.root = str(expanded)
            existing.kind = kind
            existing.default_trust = tier
            existing.default_class = klass
        else:
            session.add(
                Source(
                    slug=slug,
                    kind=kind,
                    root=str(expanded),
                    default_trust=tier,
                    default_class=klass,
                )
            )
    return AddSourceResult(slug=slug, root=expanded, corpus_class=klass, trust=tier, created=existing is None)


def document_count(slug: str) -> int:
    """How many documents removing ``slug`` would delete."""
    with session_scope() as session:
        source = session.query(Source).filter_by(slug=slug).one_or_none()
        if source is None:
            raise LookupError(f"no such source: {slug}")
        return session.query(func.count(Document.id)).filter(Document.source_id == source.id).scalar() or 0


@dataclass
class RemoveSourceResult:
    slug: str
    deleted_documents: int
    # The config file the source was also dropped from, when it was declared there.
    config_path: Path | None = None
    # Why the config file could not be updated, when it could not.
    config_error: str | None = None

    @property
    def message(self) -> str:
        text = f"removed {self.slug} ({self.deleted_documents:,} documents)"
        if self.config_path is not None:
            text += f" and dropped it from {self.config_path}"
        if self.config_error:
            text += f"; {self.config_error}"
        return text


def remove_source(slug: str) -> RemoveSourceResult:
    """Deregister a source; its documents, chunks and vectors cascade away with it."""
    count = 0
    with session_scope() as session:
        source = session.query(Source).filter_by(slug=slug).one_or_none()
        if source is not None:
            count = session.query(func.count(Document.id)).filter(Document.source_id == source.id).scalar() or 0
            session.delete(source)
    try:
        config_path = _drop_from_config(slug)
    except (ConfigError, OSError) as exc:
        if source is None:
            raise
        return RemoveSourceResult(
            slug=slug,
            deleted_documents=int(count),
            config_error=f"it is still declared in the config file, so Sync will add it again: {exc}",
        )
    # A source only the config file declares (never synced) is removed from the file alone.
    if source is None and config_path is None:
        raise LookupError(f"no such source: {slug}")
    return RemoveSourceResult(slug=slug, deleted_documents=int(count), config_path=config_path)


def _drop_from_config(slug: str) -> Path | None:
    """Remove ``slug`` from the config file's sources; the file's path when it was declared there.

    Sync registers every source the file declares (and the app's Sync first copies every
    database source into the file), so a source removed only from the database would come
    back. Like :func:`import_sources_into_config`, the file is rebuilt from what it already
    says, never from the loaded settings, which carry the app-managed database URL.
    """
    target = get_settings().config_path
    if target is None:
        return None
    target = target.expanduser()
    try:
        settings = Settings(**flatten(read_config_document(target)))
    except ValidationError as exc:
        raise ConfigError(f"{target}: {exc}") from exc
    kept = [spec for spec in settings.sources if spec.slug != slug]
    if len(kept) == len(settings.sources):
        return None
    settings.sources = kept
    save_config(settings, target)
    return target


ScanPhase = Literal["progress", "source"]


@dataclass(frozen=True)
class ScanEvent:
    """One step of a scan.

    ``progress``: ``source_items`` found so far in ``source`` while it is walked.
    ``source``: ``source`` is done and ``result`` holds its count. ``total_items``
    runs across every source the call scans.
    """

    phase: ScanPhase
    source: str
    source_items: int
    total_items: int
    result: SourceScanResult | None = None


def scan_sources(
    source: str = "*",
    *,
    include_code: bool = False,
    on_event: Callable[[ScanEvent], None] | None = None,
) -> list[SourceScanResult]:
    """Count items per source and record the expected totals.

    ``*`` means every *enabled* source; a disabled one must be named to be scanned.
    """
    with session_scope() as session:
        if source == "*":
            sources = list(session.query(Source).filter_by(enabled=True).order_by(Source.id).all())
        else:
            row = session.query(Source).filter_by(slug=source).one_or_none()
            if row is None:
                raise LookupError(f"no such source: {source}")
            sources = [row]
        session.expunge_all()

    def emit(event: ScanEvent) -> None:
        if on_event is not None:
            on_event(event)

    results: list[SourceScanResult] = []
    found_before = 0
    with session_scope() as session:
        for src in sources:
            slug = src.slug

            def on_progress(count: int, slug: str = slug, before: int = found_before) -> None:
                emit(ScanEvent("progress", slug, count, before + count))

            emit(ScanEvent("progress", slug, 0, found_before))
            result = scan_source(src, include_code=include_code, on_progress=on_progress)
            results.append(result)
            persist_scan_result(session, result)
            found_before += result.item_count
            emit(ScanEvent("source", slug, result.item_count, found_before, result))
    return results


@dataclass
class SyncResult:
    config_path: Path | None
    declared: int
    applied: bool
    created: list[str] = field(default_factory=list)
    updated: list[str] = field(default_factory=list)
    undeclared: list[tuple[str, int]] = field(default_factory=list)

    @property
    def lines(self) -> list[str]:
        if not self.declared:
            return [f"no sources declared in {self.config_path or 'the config file'}"]
        verb = "" if self.applied else "would "
        out: list[str] = []
        if self.created:
            out.append(f"{verb}create: {', '.join(self.created)}")
        if self.updated:
            out.append(f"{verb}update: {', '.join(self.updated)}")
        if not self.created and not self.updated:
            out.append("database already matches the config")
        if self.undeclared:
            out.append("in the database but not declared (left untouched):")
            out.extend(f"  {slug} ({count:,} documents)" for slug, count in self.undeclared)
        return out


def sync_sources(*, apply: bool = True, settings: Settings | None = None) -> SyncResult:
    """Apply the sources declared in the config file to the database.

    Declared sources win: each is created or updated to match the file. Sources
    that exist only in the database are reported, never deleted, since that
    would discard indexed documents on the strength of an edit.
    """
    settings = settings or get_settings()
    result = SyncResult(config_path=settings.config_path, declared=len(settings.sources), applied=apply)
    if not settings.sources:
        return result

    with session_scope() as session:
        declared = {spec.slug for spec in settings.sources}
        for spec in settings.sources:
            klass = CorpusClass(spec.corpus_class)
            tier = TrustTier(spec.trust)
            row = session.query(Source).filter_by(slug=spec.slug).one_or_none()
            if row is None:
                if apply:
                    session.add(
                        Source(
                            slug=spec.slug,
                            kind=spec.kind,
                            root=str(spec.expanded_root),
                            default_class=klass,
                            default_trust=tier,
                            enabled=spec.enabled,
                            config={"include_code": spec.include_code},
                        )
                    )
                result.created.append(spec.slug)
                continue

            changed = (
                row.kind != spec.kind
                or row.root != str(spec.expanded_root)
                or row.default_class != klass
                or row.default_trust != tier
                or row.enabled != spec.enabled
                or bool((row.config or {}).get("include_code", False)) != spec.include_code
            )
            if changed:
                if apply:
                    row.kind = spec.kind
                    row.root = str(spec.expanded_root)
                    row.default_class = klass
                    row.default_trust = tier
                    row.enabled = spec.enabled
                    row.config = {**(row.config or {}), "include_code": spec.include_code}
                result.updated.append(spec.slug)

        result.undeclared = [
            (slug, int(count))
            for slug, count in (
                session.query(Source.slug, func.count(Document.id))
                .outerjoin(Document, Document.source_id == Source.id)
                .group_by(Source.slug)
                .all()
            )
            if slug not in declared
        ]
    return result


@dataclass
class ImportSourcesResult:
    path: Path
    added: list[str]

    @property
    def message(self) -> str:
        if not self.added:
            return "config already lists every database source"
        return f"added {len(self.added)} sources to {self.path}: {', '.join(self.added)}"


def import_sources_into_config(path: Path | None = None) -> ImportSourcesResult:
    """Copy the database's sources into the config file, so it becomes the source of truth.

    The file is rebuilt from what it already says, not from the loaded settings:
    those carry ``GARAGE_DATABASE_URL``, the app-managed credential, which must
    never be written to disk.
    """
    from garage_rag.config import SourceSpec

    target = (path or get_settings().config_path or (Path.cwd() / CONFIG_FILENAME)).expanduser()
    try:
        settings = Settings(**flatten(read_config_document(target)))
    except ValidationError as exc:
        raise ConfigError(f"{target}: {exc}") from exc

    with session_scope() as session:
        rows = session.query(Source).order_by(Source.slug).all()
        existing = {spec.slug for spec in settings.sources}
        added: list[str] = []
        for row in rows:
            if row.slug in existing:
                continue
            settings.sources.append(
                SourceSpec(
                    slug=row.slug,
                    root=str(row.root),
                    kind=row.kind,
                    **{"class": str(row.default_class)},
                    trust=str(row.default_trust),
                    include_code=bool((row.config or {}).get("include_code", False)),
                    enabled=bool(row.enabled),
                )
            )
            added.append(row.slug)

    if added:
        save_config(settings, target)
    return ImportSourcesResult(path=target, added=added)
