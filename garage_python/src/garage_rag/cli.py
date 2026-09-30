"""``garage`` command line interface."""

from __future__ import annotations

import json
import logging
import sys
from pathlib import Path
from typing import Annotated

import typer
from rich.console import Console
from rich.table import Table
from sqlalchemy import func
from sqlalchemy.exc import DBAPIError

from garage_rag.config import (
    CONFIG_FILENAME,
    SCHEMA_URL,
    USER_CONFIG_FILENAME,
    ConfigError,
    Settings,
    candidate_paths,
    default_config_path,
    get_settings,
    json_schema,
    load_config,
    nest,
    repo_schema_path,
    resolve_setting,
    save_config,
    set_settings,
    setting_names,
    setting_value,
)
from garage_rag.config.fact_prompts import EffectivePrompt
from garage_rag.db.emb_tables import (
    count_vectors,
    list_models,
)
from garage_rag.db.engine import session_scope
from garage_rag.db.migrate import apply_migrations, redact_url, schema_summary
from garage_rag.db.models import Document, Source
from garage_rag.mcp_server.install import MULTI_TARGETS, target_keys
from garage_rag.search import Direction, SearchMode

app = typer.Typer(
    add_completion=False,
    help="Local-first personal RAG pipeline over Postgres + pgvector.",
    no_args_is_help=True,
)


class _StdoutConsole(Console):
    """A console that keeps following ``sys.stdout``.

    In-process runners (Click's ``CliRunner``) swap
    ``sys.stdout`` for a capture buffer around a command. rich resolves the file
    lazily only while none is set, so a caller that reads ``console.file``,
    redirects it, and later assigns the old value back would pin the console to
    whatever stream ``sys.stdout`` happened to be at that moment -- typically a
    pytest capture -- and every later ``console.print`` would miss the runner's
    buffer. Assigning the live ``sys.stdout`` therefore means "back to default".
    """

    def _set_file(self, new_file) -> None:
        self._file = None if new_file is sys.stdout else new_file

    file = property(Console.file.fget, _set_file)


console = _StdoutConsole()
log = logging.getLogger(__name__)


def _setup_logging(verbose: bool) -> None:
    logging.basicConfig(
        level=logging.DEBUG if verbose else logging.INFO,
        format="%(levelname)s %(name)s: %(message)s",
    )


@app.callback()
def main(
    verbose: Annotated[bool, typer.Option("--verbose", "-v")] = False,
    config: Annotated[
        Path | None,
        typer.Option(
            "--config",
            "-c",
            help=f"Config file. Default: ./{CONFIG_FILENAME}, then ~/{USER_CONFIG_FILENAME}.",
        ),
    ] = None,
) -> None:
    _setup_logging(verbose)
    try:
        set_settings(load_config(config))
    except ConfigError as exc:
        console.print(f"[red]config error[/red]: {exc}")
        raise typer.Exit(code=2) from None

    # A leftover .env is worse than no .env: it looks like configuration and has
    # no effect. Say so rather than letting someone edit it for an hour.
    legacy = Path.cwd() / ".env"
    if legacy.is_file():
        console.print(
            f"[yellow]note[/yellow]: {legacy.name} is no longer read. Move its values "
            f"into {CONFIG_FILENAME} (see 'garage config init'), then delete it."
        )


# ---------------------------------------------------------------------------
# configuration
# ---------------------------------------------------------------------------
config_app = typer.Typer(help="Inspect and create the configuration file.", no_args_is_help=True)
app.add_typer(config_app, name="config")


@config_app.command("init")
def config_init(
    path: Annotated[Path | None, typer.Option("--path", help=f"Where to write. Default ./{CONFIG_FILENAME}.")] = None,
    user: Annotated[
        bool,
        typer.Option("--user", help=f"Write to ~/{USER_CONFIG_FILENAME} instead of the project."),
    ] = False,
    force: Annotated[bool, typer.Option("--force", help="Overwrite an existing file.")] = False,
) -> None:
    """Write a configuration file with every setting at its default."""
    target = path or (default_config_path() if user else Path.cwd() / CONFIG_FILENAME)
    target = target.expanduser()

    if target.exists() and not force:
        console.print(f"[yellow]{target} already exists[/yellow]; pass --force to overwrite")
        raise typer.Exit(code=1)

    settings = Settings()
    save_config(settings, target)

    console.print(f"[green]wrote[/green] {target}")
    # No schema file is written beside the config: `$schema` names the published
    # URL, so editors resolve field documentation without a local copy.
    console.print(f"  [dim]$schema -> {SCHEMA_URL}[/dim]")
    if not settings.self_name:
        console.print(
            "\n[yellow]next[/yellow]: set [cyan]identity.name[/cyan] and "
            "[cyan]identity.identities[/cyan] so your own writing can be told "
            "apart from reference material"
        )


@config_app.command("import-sources")
def config_import_sources(
    path: Annotated[Path | None, typer.Option("--path", help="Config file to update. Default: the one in use.")] = None,
) -> None:
    """Copy the database's sources into the config file.

    Useful once, when moving from `add-source` to declared sources: it captures
    what already exists so the file becomes the source of truth without you
    retyping it.
    """
    from garage_rag.ops.sources import import_sources_into_config

    result = import_sources_into_config(path)
    if not result.added:
        console.print("[green]config already lists every database source[/green]")
        return
    console.print(f"[green]added {len(result.added)} sources[/green] to {result.path}")
    for slug in result.added:
        console.print(f"  {slug}")


@config_app.command("show")
def config_show(
    defaults: Annotated[bool, typer.Option("--defaults/--diff", help="Show all values, or only overrides.")] = True,
) -> None:
    """Print the effective configuration."""
    settings = get_settings()
    origin = settings.config_path or "(defaults; no file found)"
    console.print(f"[dim]loaded from: {origin}[/dim]")
    console.print(json.dumps(nest(settings, include_defaults=defaults), indent=2))


@config_app.command("path")
def config_path_cmd() -> None:
    """Show which config file is in use, and the search order."""
    settings = get_settings()
    console.print(f"in use : {settings.config_path or '[yellow](none)[/yellow]'}")
    console.print("search order:")
    for candidate in candidate_paths():
        mark = "[green]found[/green]" if candidate.is_file() else "[dim]absent[/dim]"
        console.print(f"  {mark}  {candidate}")


def _format_setting(value: object) -> str:
    """Strings print bare; everything else as JSON, so `true`/`42`/`["a","b"]` parse unambiguously."""
    return value if isinstance(value, str) else json.dumps(value)


@config_app.command("get")
def config_get(
    name: Annotated[str, typer.Argument(help="Setting as SECTION.KEY, e.g. facts.model.", metavar="SECTION.KEY")],
) -> None:
    """Print one effective setting (after --config and environment overrides)."""
    try:
        _section, _key, field = resolve_setting(name)
    except ConfigError as exc:
        console.print(f"[red]{exc}[/red]")
        raise typer.Exit(code=2) from None
    # typer.echo, not the rich console: a long URL must not be wrapped at the terminal width.
    typer.echo(_format_setting(setting_value(get_settings(), field)))


@config_app.command("set")
def config_set(
    name: Annotated[str, typer.Argument(help="Setting as SECTION.KEY, e.g. facts.model.", metavar="SECTION.KEY")],
    value: Annotated[
        str,
        typer.Argument(
            help="New value. Booleans take true/false, yes/no, on/off, 1/0; lists are comma-separated.",
        ),
    ],
    path: Annotated[
        Path | None,
        typer.Option("--path", help="Config file to update. Default: the one in use, else ~/.garage.json."),
    ] = None,
) -> None:
    """Change one setting in the config file, validating it before writing.

    The file in use (--config, ./garage.json, then ~/.garage.json) is rewritten
    in its nested layout with the one value changed; when no file exists yet,
    one is created from the defaults, as `config init --user` would.
    """
    from garage_rag.ops.settings import set_setting

    try:
        written, stored = set_setting(name, value, path=path)
    except ConfigError as exc:
        console.print(f"[red]{exc}[/red]")
        if "unknown" in str(exc) or "expected SECTION.KEY" in str(exc):
            console.print("[dim]valid keys:[/dim] " + ", ".join(setting_names()))
        raise typer.Exit(code=2) from None
    # stdout is exactly the assignment, for callers that parse it; the note goes to stderr.
    typer.echo(f"{name} = {_format_setting(stored)}")
    typer.echo(f"wrote {written}", err=True)


@config_app.command("schema")
def config_schema(
    path: Annotated[Path | None, typer.Option("--path", help="Write here instead of stdout.")] = None,
    publish: Annotated[
        bool,
        typer.Option(
            "--publish",
            help="Write to docs/.data/ in the repository, where it is committed and the website serves it.",
        ),
    ] = False,
) -> None:
    """Emit the JSON Schema describing the config file.

    Use --publish after adding or renaming a setting, then commit the result so
    the URL in every config's $schema stays accurate.
    """
    payload = json.dumps(json_schema(), indent=2) + "\n"
    target = path.expanduser() if path else (repo_schema_path() if publish else None)
    if target is None:
        console.print_json(payload)
        return
    target.write_text(payload, encoding="utf-8")
    console.print(f"[green]wrote[/green] {target}")
    if publish:
        console.print(f"  [dim]commit it so {SCHEMA_URL} resolves[/dim]")


@app.command()
def sync(
    apply: Annotated[bool, typer.Option("--apply/--dry-run", help="Write changes to the database.")] = True,
) -> None:
    """Apply sources declared in the config file to the database.

    Declared sources win: each is created or updated to match the file. Sources
    that exist only in the database are reported but never deleted, since that
    would discard indexed documents on the strength of an edit.
    """
    from garage_rag.ops.sources import SourceArgumentError, sync_sources

    try:
        result = sync_sources(apply=apply)
    except SourceArgumentError as exc:
        console.print(f"[red]{exc}[/red]")
        raise typer.Exit(code=1) from None
    if not result.declared:
        console.print(f"[yellow]no sources declared[/yellow] in {result.config_path or 'the config file'}")
        return

    verb = "" if apply else "would "
    if result.created:
        console.print(f"[green]{verb}create[/green]: {', '.join(result.created)}")
    if result.updated:
        console.print(f"[cyan]{verb}update[/cyan]: {', '.join(result.updated)}")
    if not result.created and not result.updated:
        console.print("[green]database already matches the config[/green]")
    if result.undeclared:
        console.print("\n[dim]in the database but not declared (left untouched):[/dim]")
        for slug, count in result.undeclared:
            console.print(f"  {slug} ({count:,} documents)")
        console.print("  [dim]add them to the config, or remove with 'garage remove-source <slug>'[/dim]")


# ---------------------------------------------------------------------------
# schema
# ---------------------------------------------------------------------------
@app.command("init-db")
def init_db(
    schema_dir: Annotated[
        Path | None,
        typer.Option("--schema-dir", help="Directory containing numbered SQL schema files."),
    ] = None,
) -> None:
    """Apply the schema: extensions, enums, core tables, model registry."""
    applied = apply_migrations(schema_dir=schema_dir)
    for name in applied:
        console.print(f"  applied [cyan]{name}[/cyan]")
    console.print(f"[green]schema ready[/green] ({redact_url(get_settings().database_url)})")


@app.command()
def stats() -> None:
    """Row counts across the corpus."""
    with session_scope() as session:
        summary = schema_summary(session)
        models = list_models(session)
        model_rows = [
            (
                m.slug,
                f"{m.dims}",
                f"{m.storage_kind}({m.stored_dims})",
                m.index_kind,
                "yes" if m.is_default else "",
                f"{count_vectors(session, m):,}",
            )
            for m in models
        ]

    table = Table(title="corpus")
    table.add_column("table")
    table.add_column("rows", justify="right")
    for name, count in summary.items():
        table.add_row(name, f"{count:,}")
    console.print(table)

    if model_rows:
        mt = Table(title="embedding models")
        for col in ("slug", "dims", "storage", "index", "default", "vectors"):
            mt.add_column(col, justify="right" if col in {"dims", "vectors"} else "left")
        for row in model_rows:
            mt.add_row(*row)
        console.print(mt)


# ---------------------------------------------------------------------------
# embedding models
# ---------------------------------------------------------------------------
@app.command("register-model")
def register_model_cmd(
    slug: Annotated[str, typer.Argument(help="Model slug, e.g. bge-m3.")],
    dims: Annotated[int | None, typer.Option(help="Output width. Required for unknown models.")] = None,
    model_ref: Annotated[str | None, typer.Option(help="Provider-side name, if it differs from the slug.")] = None,
    provider: Annotated[
        str | None, typer.Option(help="Embedding backend: llama_xpc | ollama | lmstudio | image_xpc.")
    ] = None,
    model_id: Annotated[str | None, typer.Option(help="Model identifier (e.g. HuggingFace repo).")] = None,
    distance: Annotated[
        str | None,
        typer.Option(help="Similarity the model was trained for: cosine | l2 | inner_product. Default: models.json."),
    ] = None,
    modality: Annotated[
        str | None,
        typer.Option(help="What the model embeds: text | image (a CLIP-style model). Default: models.json."),
    ] = None,
    default: Annotated[bool, typer.Option("--default", help="Make this the default.")] = False,
) -> None:
    """Register an embedding model and create its table and index."""
    from garage_rag.ops.models import register_model as register

    try:
        row = register(
            slug,
            dims=dims,
            model_ref=model_ref,
            provider=provider,
            model_id=model_id,
            distance=distance,
            modality=modality,
            make_default=default,
        )
    except ValueError as exc:
        console.print(f"[red]{exc}[/red]")
        raise typer.Exit(code=2) from None
    console.print(
        f"[green]registered[/green] {row.slug}{' (image model)' if row.modality == 'image' else ''}: {row.dims}-dim -> "
        f"{row.storage_kind}({row.stored_dims}), index={row.index_kind}, "
        f"distance={row.distance}, table={row.table_name}"
    )
    for note in row.notes:
        console.print(f"  [yellow]note[/yellow]: {note}")


@app.command("list-models")
def list_models_cmd(
    json_output: Annotated[bool, typer.Option("--json", help="Output as JSON.")] = False,
) -> None:
    """List registered embedding models."""
    with session_scope() as session:
        rows = [
            {
                "slug": m.slug,
                "provider": m.provider,
                "model_ref": m.model_ref,
                "model_id": m.model_id,
                "dims": m.dims,
                "stored_dims": m.stored_dims,
                "storage_kind": m.storage_kind,
                "index_kind": m.index_kind,
                "distance": m.distance,
                "modality": m.modality,
                "table_name": m.table_name,
                "is_default": bool(m.is_default),
            }
            for m in list_models(session)
        ]
    if json_output:
        console.print(json.dumps(rows, indent=2))
        return
    if not rows:
        console.print("[yellow]no models registered[/yellow]")
        return
    table = Table()
    columns = (
        "slug",
        "provider",
        "ref",
        "model_id",
        "dims",
        "stored",
        "storage",
        "index",
        "distance",
        "modality",
        "table",
        "default",
    )
    for col in columns:
        table.add_column(col)
    for row in rows:
        table.add_row(
            row["slug"],
            row["provider"],
            row["model_ref"],
            row["model_id"] or "",
            str(row["dims"]),
            str(row["stored_dims"]),
            row["storage_kind"],
            row["index_kind"],
            row["distance"],
            row["modality"],
            row["table_name"],
            "*" if row["is_default"] else "",
        )
    console.print(table)


@app.command("set-default-model")
def set_default_model_cmd(slug: str) -> None:
    """Point the default embedding model at SLUG."""
    from garage_rag.ops.models import set_default_model as set_default

    set_default(slug)
    console.print(f"[green]default model[/green] = {slug}")


@app.command("drop-model")
def drop_model_cmd(
    slug: str,
    yes: Annotated[bool, typer.Option("--yes", help="Skip confirmation.")] = False,
) -> None:
    """Deregister a model and drop its vectors."""
    from garage_rag.ops.models import drop_model as drop

    if not yes:
        typer.confirm(f"Drop model {slug} and discard all its vectors?", abort=True)
    drop(slug)
    console.print(f"[green]dropped[/green] {slug}")


# ---------------------------------------------------------------------------
# sources
# ---------------------------------------------------------------------------
@app.command("add-source")
def add_source(
    slug: Annotated[str, typer.Argument(help="Short name, e.g. dropbox.")],
    root: Annotated[Path, typer.Argument(help="Directory or file to index.")],
    kind: Annotated[str, typer.Option(help="filesystem | git | sqlite | maildir | feed")] = "filesystem",
    corpus_class: Annotated[
        str,
        typer.Option(
            "--class",
            help="Default grouping: document | code | communication",
        ),
    ] = "document",
    trust: Annotated[str, typer.Option(help="Default trust: authored | reference | received")] = "authored",
) -> None:
    """Register a source root to be walked."""
    from garage_rag.ops.sources import SourceArgumentError
    from garage_rag.ops.sources import add_source as register

    try:
        result = register(slug, root, kind=kind, corpus_class=corpus_class, trust=trust)
    except SourceArgumentError as exc:
        raise typer.BadParameter(str(exc), param_hint=exc.param_hint) from None
    if result.created:
        console.print(f"[green]added source[/green] {slug} -> {result.root} ({result.corpus_class}/{result.trust})")
    else:
        console.print(f"[green]updated source[/green] {slug} -> {result.root}")


@app.command("remove-source")
def remove_source(
    slug: str,
    yes: Annotated[bool, typer.Option("--yes", help="Skip confirmation.")] = False,
) -> None:
    """Deregister a source and delete its documents, chunks, and vectors."""
    from garage_rag.ops.sources import document_count
    from garage_rag.ops.sources import remove_source as deregister

    try:
        count = document_count(slug)
    except LookupError:
        console.print(f"[yellow]no such source[/yellow]: {slug}")
        raise typer.Exit(code=1) from None
    if not yes:
        typer.confirm(f"Remove source {slug} and delete {count:,} documents?", abort=True)
    result = deregister(slug)
    console.print(f"[green]removed[/green] {slug} ({result.deleted_documents:,} documents)")


@app.command("list-sources")
def list_sources() -> None:
    """List registered sources."""
    with session_scope() as session:
        sources = session.query(Source).order_by(Source.id).all()
        doc_counts = dict(session.query(Document.source_id, func.count(Document.id)).group_by(Document.source_id).all())
    if not sources:
        console.print("[yellow]no sources registered[/yellow]")
        return
    table = Table()
    for col in ("slug", "kind", "docs", "class", "trust", "enabled", "root"):
        table.add_column(col, justify="right" if col == "docs" else "left")
    for s in sources:
        table.add_row(
            s.slug,
            s.kind,
            f"{doc_counts.get(s.id, 0):,}",
            str(s.default_class),
            str(s.default_trust),
            "yes" if s.enabled else "no",
            s.root,
        )
    console.print(table)


# ---------------------------------------------------------------------------
# scan & ingest
# ---------------------------------------------------------------------------
@app.command()
def scan(
    source: Annotated[str, typer.Option("--source", "-s", help="Source slug to scan, or '*' for all.")] = "*",
    include_code: Annotated[
        bool,
        typer.Option("--include-code", help="Also include source code files in count."),
    ] = False,
    json_output: Annotated[bool, typer.Option("--json", help="Output as JSON.")] = False,
) -> None:
    """Scan sources and count items by source type before ingesting."""
    from garage_rag.ops.sources import scan_sources

    try:
        results = scan_sources(source, include_code=include_code)
    except LookupError:
        console.print(f"[red]no such source:[/red] {source}")
        raise typer.Exit(code=1) from None
    if not results:
        console.print("[yellow]no sources registered to scan[/yellow]")
        return

    if json_output:
        console.print_json(json.dumps([r.to_dict() for r in results]))
        return

    table = Table(title="source scan")
    table.add_column("slug")
    table.add_column("kind")
    table.add_column("items", justify="right")
    table.add_column("item type")
    table.add_column("time", justify="right")
    table.add_column("root")
    table.add_column("status")

    total_items = 0
    for r in results:
        total_items += r.item_count
        status_str = f"[red]error: {r.error}[/red]" if r.error else "[green]ok[/green]"
        table.add_row(
            r.source_slug,
            r.kind,
            f"{r.item_count:,}",
            r.item_type,
            f"{r.duration_seconds:.2f}s",
            str(r.root),
            status_str,
        )

    console.print(table)
    console.print(f"[dim]Total across {len(results)} source(s): {total_items:,} items[/dim]")


@app.command()
def ingest(
    source: Annotated[str, typer.Option("--source", "-s", help="Source slug to walk, or '*' for all.")] = "*",
    include_code: Annotated[
        bool,
        typer.Option("--include-code", help="Also index source files, not just documents."),
    ] = False,
    limit: Annotated[int | None, typer.Option(help="Stop after this many candidates (for trials).")] = None,
    force: Annotated[bool, typer.Option("--force", help="Re-extract and re-chunk even if unchanged.")] = False,
) -> None:
    """Walk a source and index it. Safe to re-run; unchanged files are skipped."""
    from garage_rag.db.engine import get_session_factory
    from garage_rag.ingest.pipeline import ingest_source

    factory = get_session_factory()
    with factory() as session:
        if source == "*":
            # '*' means every *enabled* source; a disabled one must be named to be ingested.
            sources = [s.slug for s in session.query(Source).filter_by(enabled=True).order_by(Source.id).all()]
        else:
            s = session.query(Source).filter_by(slug=source).one_or_none()
            if s is None:
                console.print(f"[red]no such source:[/red] {source}")
                raise typer.Exit(code=1)
            sources = [s.slug]

    if not sources:
        console.print("[yellow]no sources registered to ingest[/yellow]")
        return

    from garage_rag.ingest.walker import SourceUnavailable

    unavailable: list[str] = []
    for source in sources:
        with console.status(f"scanning {source}...") as status:
            last_reported = 0

            # slug bound as a default: the closure outlives this loop iteration.
            def on_progress(
                progress_counters,
                progress_budget,
                total_items=0,
                phase="ingest",
                scan_result=None,
                slug=source,
                current_item=None,
            ) -> None:
                nonlocal last_reported
                note = ""
                if progress_budget.files_done or progress_budget.deferred:
                    note = f" | downloaded {progress_budget.files_done:,} deferred {progress_budget.deferred:,}"
                if phase == "scan":
                    item_type = scan_result.item_type if scan_result else "items"
                    status.update(f"scanned {slug}: found {total_items:,} {item_type}")
                    console.print(f"[cyan]scanned {slug}[/cyan]: found {total_items:,} {item_type}")
                    return
                pct_str = f" [{(progress_counters.seen / total_items * 100):.1f}%]" if total_items > 0 else ""
                status_msg = (
                    f"{slug}:{pct_str} scanned {progress_counters.seen:,}/{total_items:,} "
                    f"| ingested {progress_counters.indexed:,} "
                    f"(skipped {progress_counters.skipped:,}, failed {progress_counters.failed:,}){note}"
                )
                status.update(status_msg)
                should_report = progress_counters.seen - last_reported >= 50 or progress_counters.seen == total_items
                if not console.is_terminal and should_report:
                    last_reported = progress_counters.seen
                    console.print(status_msg)

            try:
                counters, walk_stats, budget = ingest_source(
                    factory,
                    source,
                    include_code=include_code,
                    limit=limit,
                    force=force,
                    progress=on_progress,
                )
            except SourceUnavailable as exc:
                console.print(f"[red]{source}: {exc}[/red]")
                unavailable.append(source)
                continue

        table = Table(title=f"ingest: {source}")
        table.add_column("metric")
        table.add_column("count", justify="right")
        for label, value in (
            (f"scanned items ({counters.item_type})", counters.total_items),
            ("candidates seen", counters.seen),
            ("indexed", counters.indexed),
            ("skipped (unchanged)", counters.skipped),
            ("failed", counters.failed),
            ("rejected: machine-generated", counters.rejected),
            ("chunks written", counters.chunks_written),
            ("placeholders pending", counters.placeholders),
            ("dirs walked", walk_stats.dirs),
            ("files examined", walk_stats.files_seen),
            ("skipped: not indexable", walk_stats.skipped_extension),
            ("skipped: diagnostic", walk_stats.skipped_diagnostic),
            ("skipped: code", walk_stats.skipped_code),
            ("skipped: too large", walk_stats.skipped_too_large),
        ):
            table.add_row(label, f"{value:,}")
        console.print(table)

        if budget.enabled:
            console.print(f"[cyan]placeholders[/cyan]: {budget.summary()}")
            if budget.deferred:
                console.print(
                    "  [yellow]budget reached[/yellow]: re-run to continue "
                    "(unchanged files are skipped, so progress accumulates)"
                )
        elif counters.placeholders:
            console.print(
                f"[yellow]{counters.placeholders:,} placeholders skipped[/yellow] "
                "(set placeholders.materialize = true in the config to download them)"
            )

        if counters.errors:
            console.print(f"\n[red]first {min(5, len(counters.errors))} errors[/red]:")
            for message in counters.errors[:5]:
                console.print(f"  {message}")

    if unavailable:
        console.print(f"\n[red]{len(unavailable)} source(s) could not be read:[/red] {', '.join(unavailable)}")
        raise typer.Exit(code=1)


@app.command()
def backfill(
    model: Annotated[str | None, typer.Option("--model", "-m", help="Model slug. Default: all models.")] = None,
    batch_size: Annotated[int | None, typer.Option(help="Chunks per request.")] = None,
    limit: Annotated[int | None, typer.Option(help="Stop after this many chunks.")] = None,
    verify: Annotated[bool, typer.Option("--verify/--no-verify", help="Probe the model's width first.")] = True,
) -> None:
    """Embed chunks that a model has no vectors for. Pure insert; safe to re-run."""
    from garage_rag.ops.backfill import BackfillEvent
    from garage_rag.ops.backfill import backfill as run_backfill

    status = None

    def on_event(event: BackfillEvent) -> None:
        nonlocal status
        if event.phase == "complete":
            console.print(f"[green]{event.model}[/green]: already complete")
        elif event.phase == "skipped":
            console.print(f"[red]{event.model}[/red]: {event.message.removeprefix(event.model + ': ')}")
        elif event.phase == "started":
            console.print(f"[cyan]{event.model}[/cyan]: embedding {event.total:,} chunks")
            status = console.status(f"{event.model}...")
            status.start()
        elif event.phase == "progress" and status is not None:
            status.update(f"{event.model}: {event.embedded:,}/{event.total:,} ({event.batches} batches)")
        elif event.phase == "finished":
            if status is not None:
                status.stop()
                status = None
            summary = f"embedded {event.embedded:,}"
            if event.failed:
                summary += f", [red]failed {event.failed:,}[/red]"
            if event.remaining:
                summary += f", remaining {event.remaining:,}"
            console.print(f"  {event.model}: {summary}")

    try:
        run_backfill(model, batch_size=batch_size, limit=limit, verify=verify, on_event=on_event)
    except LookupError as exc:
        if str(exc) == "no models registered":
            console.print("[yellow]no models registered[/yellow]")
            raise typer.Exit(code=1) from None
        raise
    finally:
        if status is not None:
            status.stop()


@app.command(name="enrich-facts")
def enrich_facts(
    source: Annotated[str, typer.Option("--source", "-s", help='Source slug, or "*" for all sources.')] = "*",
    document_id: Annotated[
        int | None,
        typer.Option("--document-id", help="Extract facts for just this one document, ignoring --source."),
    ] = None,
    model: Annotated[
        str | None,
        typer.Option("--model", "-m", help="Fact-distillation model slug/alias. Default: facts.model from the config."),
    ] = None,
    provider: Annotated[
        str | None,
        typer.Option(
            "--provider",
            help=(
                'Local inference backend: "llama_xpc" (the app\'s LlamaXPCService on loopback) or "ollama" '
                "(a local Ollama server). Default: facts.provider from the config."
            ),
        ),
    ] = None,
    prompt: Annotated[
        list[str] | None,
        typer.Option(
            "--prompt",
            "-p",
            help=(
                "Run only this fact prompt (repeatable), even if disabled. Default: every enabled prompt that "
                "applies to the document; see 'garage facts prompts list'."
            ),
        ),
    ] = None,
    stale_only: Annotated[
        bool,
        typer.Option(
            "--stale-only",
            help="Skip a prompt whose last run on the document had the same prompt text, content and model.",
        ),
    ] = False,
) -> None:
    """Distill documents into atomic facts, once per prompt. Re-extraction replaces that prompt's prior facts."""
    from garage_rag.ops.facts import EnrichEvent
    from garage_rag.ops.facts import enrich_facts as run_enrich

    status = None

    def on_start(total: int, model_id: str, backend: str) -> None:
        nonlocal status
        console.print(f"[cyan]enriching[/cyan] {total:,} document(s) via [cyan]{backend}[/cyan]/{model_id}")
        status = console.status("enriching...")
        status.start()

    def on_event(event: EnrichEvent) -> None:
        if status is not None:
            status.update(f"{event.index}/{event.total}: {event.uri or event.document_id}")
        if event.error:
            console.print(f"  [red]{event.uri or event.document_id}[/red]: {event.error}")

    try:
        summary = run_enrich(
            source=source,
            document_id=document_id,
            model=model,
            provider=provider,
            prompts=prompt or None,
            stale_only=stale_only,
            on_start=on_start,
            on_event=on_event,
        )
    except LookupError as exc:
        console.print(f"[red]{exc}[/red]" if document_id or prompt else f"[yellow]{exc}[/yellow]")
        raise typer.Exit(code=1) from None
    finally:
        if status is not None:
            status.stop()

    line = f"{summary.enriched}/{summary.total} documents enriched, {summary.facts:,} facts extracted"
    if summary.skipped:
        line += f", {summary.skipped} skipped"
    if summary.failed:
        line += f", [red]{summary.failed} failed[/red]"
    console.print(line + f" (prompts: {', '.join(summary.prompts)})")


@app.command(name="cluster-facts")
def cluster_facts(
    model: Annotated[
        str | None,
        typer.Option("--model", "-m", help="Embedding model whose vectors are compared. Default: the default model."),
    ] = None,
    threshold: Annotated[
        float | None,
        typer.Option(
            "--threshold", help="Cosine similarity a pair must reach. Default: facts.cluster_threshold (0.9)."
        ),
    ] = None,
    neighbors: Annotated[
        int | None,
        typer.Option("--neighbors", help="Nearest neighbours fetched per fact. Default: facts.cluster_neighbors."),
    ] = None,
    distill: Annotated[
        bool,
        typer.Option(
            "--distill/--no-distill",
            help="Ask the local chat model to confirm each group and state its claim once.",
        ),
    ] = True,
    graph: Annotated[
        bool, typer.Option("--graph/--no-graph", help="Rebuild the AGE graph afterwards, where the server has AGE.")
    ] = True,
    full: Annotated[
        bool,
        typer.Option(
            "--full",
            help="Regroup the whole corpus instead of placing only new facts (a changed model or setting does too).",
        ),
    ] = False,
) -> None:
    """Distill the potential facts into distinct claims, in two levels: restatements within each document,
    then groups across the corpus, each confirmed and stated once by the local model.

    Every potential fact is linked to one distilled fact; the potential facts themselves are never changed.
    A run places only what is new since the last one unless --full. Facts need vectors first (garage
    backfill); 'garage backfill' then gives the distilled facts vectors under the other models.
    """
    from garage_rag.enrich.clusters import ClusterProgress
    from garage_rag.ops.facts import cluster_facts as run_clusters

    status = console.status("comparing each document's facts...")
    status.start()

    def on_progress(state: ClusterProgress) -> None:
        if state.message:
            status.update(state.message)

    try:
        summary = run_clusters(
            model=model,
            threshold=threshold,
            neighbors=neighbors,
            distill=distill,
            graph=graph,
            full=full,
            on_progress=on_progress,
        )
    except (LookupError, ValueError) as exc:
        console.print(f"[red]{exc}[/red]")
        raise typer.Exit(code=1) from None
    finally:
        status.stop()

    via = f" via [cyan]{summary.distill_model}[/cyan]" if summary.distill_model else ""
    console.print(f"[cyan]{summary.model}[/cyan] at {summary.threshold:g}{via}: {summary.message}")
    for error in summary.errors:
        console.print(f"  [red]{error}[/red]")
    if summary.graph:
        console.print(summary.graph)


graph_app = typer.Typer(help="The corpus as an Apache AGE graph (where the server has AGE).", no_args_is_help=True)
app.add_typer(graph_app, name="graph")


@graph_app.command("rebuild")
def graph_rebuild() -> None:
    """Re-project documents, chunks, authors, potential facts and distilled facts into the 'garage' graph."""
    from garage_rag.ops.graph import rebuild_graph

    summary = rebuild_graph()
    if not summary.available:
        console.print(f"[yellow]{summary.message}[/yellow]")
        raise typer.Exit(code=1)
    console.print(summary.message)


# ---------------------------------------------------------------------------
# fact prompts
# ---------------------------------------------------------------------------
facts_app = typer.Typer(help="Distilled facts: browse them, and the prompts enrich-facts runs.", no_args_is_help=True)
app.add_typer(facts_app, name="facts")
prompts_app = typer.Typer(
    help="The effective fact prompts: the built-in default merged with facts.prompts.", no_args_is_help=True
)
facts_app.add_typer(prompts_app, name="prompts")


def _prompt_origin(prompt: EffectivePrompt) -> str:
    if prompt.builtin:
        return "built-in, customized" if prompt.customized else "built-in"
    return "configured"


@prompts_app.command("list")
def facts_prompts_list(
    as_json: Annotated[bool, typer.Option("--json", help="Print the prompts as a JSON array.")] = False,
) -> None:
    """List every fact prompt, enabled or not, with its scope and hash."""
    from garage_rag.ops.facts import list_fact_prompts

    prompts = list_fact_prompts()
    if as_json:
        typer.echo(json.dumps([_prompt_json(p) for p in prompts], indent=2, ensure_ascii=False))
        return
    table = Table("name", "enabled", "origin", "scope", "examples", "sha256")
    for p in prompts:
        scope = ", ".join([*p.corpus_classes, *(f"source:{s}" for s in p.sources)]) or "all documents"
        table.add_row(
            p.name, "yes" if p.enabled else "no", _prompt_origin(p), scope, str(len(p.examples)), p.sha256.hex()[:12]
        )
    console.print(table)


@prompts_app.command("show")
def facts_prompts_show(
    name: Annotated[str, typer.Argument(help="Prompt name, e.g. default.")],
    as_json: Annotated[bool, typer.Option("--json", help="Print the prompt as its facts.prompts JSON entry.")] = False,
) -> None:
    """Show one prompt in full: its instructions and few-shot examples."""
    from garage_rag.ops.facts import get_fact_prompt

    try:
        prompt = get_fact_prompt(name)
    except LookupError as exc:
        console.print(f"[red]{exc}[/red]")
        raise typer.Exit(code=1) from None
    if as_json:
        typer.echo(json.dumps(prompt.to_config(), indent=2, ensure_ascii=False))
        return
    typer.echo(f"name:     {prompt.name} ({_prompt_origin(prompt)})")
    typer.echo(f"enabled:  {'yes' if prompt.enabled else 'no'}")
    typer.echo(f"classes:  {', '.join(prompt.corpus_classes) or 'all'}")
    typer.echo(f"sources:  {', '.join(prompt.sources) or 'all'}")
    typer.echo(f"sha256:   {prompt.sha256.hex()}")
    typer.echo("")
    typer.echo(prompt.description)
    for number, example in enumerate(prompt.examples, start=1):
        typer.echo("")
        typer.echo(f"Example {number}: {example.text}")
        for extraction in example.extractions:
            attributes = f" {json.dumps(extraction.attributes)}" if extraction.attributes else ""
            typer.echo(f"  - [{extraction.extraction_class}] {extraction.text}{attributes}")


def _prompt_json(prompt: EffectivePrompt) -> dict:
    return {
        **prompt.to_config(),
        "builtin": prompt.builtin,
        "customized": prompt.customized,
        "sha256": prompt.sha256.hex(),
    }


# ---------------------------------------------------------------------------
# browsing facts
# ---------------------------------------------------------------------------
_FactQuery = Annotated[
    str, typer.Option("--query", "-q", help="Full-text (websearch syntax) or substring match on the fact.")
]
_FactSource = Annotated[str, typer.Option("--source", "-s", help="Source slug.")]
_FactDocument = Annotated[int | None, typer.Option("--document-id", help="Only this document's facts.")]
_FactClass = Annotated[str, typer.Option("--class", help="Extraction class, e.g. fact.")]
_FactCorpusClass = Annotated[str, typer.Option("--corpus-class", help="document | code | communication")]


def _fact_evidence(fact) -> str:
    """The grounded span itself, cut out of the excerpt around it."""
    if fact.excerpt is None or fact.char_start is None or fact.char_end is None:
        return ""
    return fact.excerpt[fact.char_start - fact.excerpt_start : fact.char_end - fact.excerpt_start]


@facts_app.command("list")
def facts_list(
    query: _FactQuery = "",
    source: _FactSource = "",
    document_id: _FactDocument = None,
    fact_class: _FactClass = "",
    corpus_class: _FactCorpusClass = "",
    limit: Annotated[int, typer.Option(help="Facts per page.")] = 50,
    offset: Annotated[int, typer.Option(help="Facts to skip.")] = 0,
    evidence: Annotated[bool, typer.Option("--evidence", help="Show the grounded text under each fact.")] = False,
    collapse: Annotated[
        bool, typer.Option("--collapse", help="List restatements of one claim once (garage cluster-facts).")
    ] = False,
    distilled: Annotated[
        int | None, typer.Option("--distilled", help="Only the potential facts behind this distilled fact.")
    ] = None,
    json_output: Annotated[bool, typer.Option("--json", help="Output as JSON.")] = False,
) -> None:
    """List distilled facts, newest first (best match first with --query), with the document each came from."""
    from dataclasses import asdict

    from garage_rag.ops.facts import list_facts

    try:
        with session_scope() as session:
            page = list_facts(
                session,
                query=query,
                source=source,
                fact_class=fact_class,
                corpus_class=corpus_class,
                document_id=document_id,
                limit=limit,
                offset=offset,
                collapse=collapse,
                distilled_fact_id=distilled,
            )
    except ValueError as exc:
        console.print(f"[red]{exc}[/red]")
        raise typer.Exit(code=2) from None

    if json_output:
        payload = {
            "total": page.total,
            "limit": limit,
            "offset": offset,
            "facts": [{**asdict(f), "evidence": _fact_evidence(f)} for f in page.facts],
        }
        typer.echo(json.dumps(payload, indent=2, default=str, ensure_ascii=False))
        return
    if not page.facts:
        if page.total:
            console.print(f"[yellow]no facts past {offset:,} of {page.total:,}[/yellow]")
        else:
            console.print("[yellow]no facts[/yellow] (run `garage enrich-facts` to distill some)")
        return
    table = Table(title=f"facts {offset + 1:,}-{offset + len(page.facts):,} of {page.total:,}")
    for col in ("id", "class", "fact", "document", "source"):
        table.add_column(col, overflow="fold")
    for f in page.facts:
        text = f.fact
        grounded = _fact_evidence(f) if evidence else ""
        if grounded:
            text += f"\n[dim]“{grounded}”[/dim]"
        if f.distilled_size > 1:
            text += (
                f"\n[cyan]distilled {f.distilled_fact_id} ({f.distilled_size} facts): {f.distilled_statement}[/cyan]"
            )
        table.add_row(str(f.id), f.fact_class, text, f.document_title or f.document_uri, f.source_slug)
    console.print(table)


@facts_app.command("stats")
def facts_stats(
    query: _FactQuery = "",
    source: _FactSource = "",
    document_id: _FactDocument = None,
    fact_class: _FactClass = "",
    corpus_class: _FactCorpusClass = "",
    json_output: Annotated[bool, typer.Option("--json", help="Output as JSON.")] = False,
) -> None:
    """Count facts per source and per extraction class."""
    from dataclasses import asdict

    from garage_rag.ops.facts import fact_stats

    try:
        with session_scope() as session:
            stats = fact_stats(
                session,
                query=query,
                source=source,
                fact_class=fact_class,
                corpus_class=corpus_class,
                document_id=document_id,
            )
    except ValueError as exc:
        console.print(f"[red]{exc}[/red]")
        raise typer.Exit(code=2) from None

    if json_output:
        typer.echo(json.dumps(asdict(stats), indent=2, ensure_ascii=False))
        return
    console.print(stats.message)
    for title, counts in (("source", stats.by_source), ("class", stats.by_class)):
        if not counts:
            continue
        table = Table()
        table.add_column(title)
        table.add_column("facts", justify="right")
        for key, count in counts.items():
            table.add_row(key, f"{count:,}")
        console.print(table)


@app.command()
def reconcile(
    source: Annotated[str, typer.Option("--source", "-s", help="Source slug.")],
    apply: Annotated[bool, typer.Option("--apply", help="Actually delete. Default is a dry run.")] = False,
    force: Annotated[bool, typer.Option("--force", help="Override the mass-deletion guard.")] = False,
) -> None:
    """Delete documents whose source files no longer exist."""
    from garage_rag.ingest.reconcile import reconcile_source

    with session_scope() as session:
        result = reconcile_source(session, source, dry_run=not apply, force=force)

    if result.refused:
        console.print(f"[yellow]refused[/yellow]: {result.reason}")
        raise typer.Exit(code=1)

    if not result.candidates:
        console.print(f"[green]nothing to reconcile[/green] for {source}")
        return

    if apply:
        console.print(
            f"[green]deleted[/green] {result.deleted:,} of {result.total_documents:,} documents from {source}"
        )
    else:
        console.print(
            f"[cyan]dry run[/cyan]: {result.candidates:,} of "
            f"{result.total_documents:,} documents in {source} are missing "
            f"({result.fraction:.1%}). Re-run with --apply to delete."
        )


# ---------------------------------------------------------------------------
# MCP
# ---------------------------------------------------------------------------
@app.command("mcp-install")
def mcp_install(
    target: Annotated[
        str,
        typer.Option(
            "--target",
            "-t",
            help=" | ".join([*target_keys(), *MULTI_TARGETS]),
        ),
    ] = "project",
    path: Annotated[
        Path | None,
        typer.Option("--path", help="Write to this config file instead of a known target."),
    ] = None,
    all_configs: Annotated[
        bool,
        typer.Option("--all", "-a", help="Install into all detected/found client configurations."),
    ] = False,
    name: Annotated[str, typer.Option("--name", help="Server name in the config.")] = "garage-rag",
    http: Annotated[
        bool | None,
        typer.Option(
            "--http",
            help="Register the URL of a running HTTP server instead of the stdio command.",
        ),
    ] = None,
    stdio: Annotated[
        bool,
        typer.Option(
            "--stdio",
            help="Register the `garage-mcp` command, which the client starts itself (the default).",
        ),
    ] = False,
    host: Annotated[str | None, typer.Option(help="HTTP host, with --http.")] = None,
    port: Annotated[int | None, typer.Option("--port", help="HTTP port, with --http.")] = None,
    path_route: Annotated[str | None, typer.Option("--route", help="HTTP route, with --http. Default /mcp.")] = None,
    force: Annotated[bool, typer.Option("--force", help="Overwrite an existing entry of the same name.")] = False,
    dry_run: Annotated[bool, typer.Option("--dry-run", help="Show what would be written, change nothing.")] = False,
    yes: Annotated[bool, typer.Option("--yes", "-y", help="Do not prompt before writing.")] = False,
) -> None:
    """Register this MCP server in a client's config file.

    Merges into any existing config: other servers and unrelated keys are kept,
    the previous file is backed up, and the writing is atomic.
    """
    from garage_rag.ops.mcp import McpTargetOutcome, install_mcp_server

    if http is True and stdio is True:
        raise typer.BadParameter("choose either --http or --stdio")
    # stdio unless --http: the app no longer serves HTTP until the user turns it on, so a
    # URL registered by default would point at nothing.
    use_stdio = http is not True

    def announce(outcome: McpTargetOutcome) -> None:
        console.print(f"\n[bold]{outcome.label}[/bold] -> {outcome.path}")
        if outcome.note:
            console.print(f"  [dim]{outcome.note}[/dim]")
        if outcome.project_scoped and use_stdio:
            console.print(
                "  [yellow]note[/yellow]: project-scoped config records an absolute "
                "path to this virtualenv, which will not resolve on another machine"
            )
        if outcome.other_servers:
            console.print(f"  preserving: {', '.join(outcome.other_servers)}")

    def confirm(outcome: McpTargetOutcome) -> bool:
        announce(outcome)
        if yes:
            return True
        action = "Replace" if outcome.replaced_entry else "Add"
        typer.confirm(f"{action} {name!r} in {outcome.path}?", abort=True)
        return True

    try:
        report = install_mcp_server(
            target=target,
            path=path,
            all_configs=all_configs,
            name=name,
            stdio=use_stdio,
            host=host,
            port=port,
            route=path_route,
            force=force,
            dry_run=dry_run,
            confirm=confirm,
        )
    except ValueError as exc:
        raise typer.BadParameter(str(exc), param_hint="--target") from None
    except FileExistsError as exc:
        console.print(f"[yellow]{exc}[/yellow]")
        raise typer.Exit(code=1) from None
    except RuntimeError as exc:
        console.print(f"[red]{exc}[/red]")
        raise typer.Exit(code=1) from None

    if report.fell_back:
        console.print("[dim]No existing client config files found; targeting project and Claude Desktop defaults[/dim]")
    if report.url:
        console.print(f"  url     : {report.url}")
        console.print(
            "  [dim]the client connects to this URL; run `garage mcp-serve --http` "
            "or use the macOS app to keep it up[/dim]"
        )
    else:
        if report.config_file is None:
            console.print(
                "[yellow]note[/yellow]: no config file in use; the server will run "
                "on defaults. Create one with 'garage config init'."
            )
        console.print(f"  command : {report.command} {' '.join(report.args)}")

    for outcome in report.outcomes:
        if outcome.skipped:
            announce(outcome)
            console.print(f"[yellow]{outcome.skipped}[/yellow]")
        elif outcome.preview is not None:
            announce(outcome)
            console.print("\n[cyan]would write[/cyan]:")
            console.print(json.dumps(outcome.preview, indent=2))
        elif outcome.written:
            verb = "created" if outcome.created_file else "updated"
            console.print(f"[green]{verb}[/green] {outcome.path}")
            if outcome.backup:
                console.print(f"  backup: {outcome.backup.name}")

    if not dry_run:
        console.print(
            "\nRestart client(s), then try asking: [cyan]what does my reference material say about secure boot?[/cyan]"
        )


@app.command("mcp-uninstall")
def mcp_uninstall(
    target: Annotated[str, typer.Option("--target", "-t")] = "project",
    path: Annotated[Path | None, typer.Option("--path")] = None,
    name: Annotated[str, typer.Option("--name")] = "garage-rag",
) -> None:
    """Remove this server from a client's config."""
    from garage_rag.ops.mcp import uninstall_mcp_server

    try:
        config, removed = uninstall_mcp_server(target=target, path=path, name=name)
    except ValueError as exc:
        raise typer.BadParameter(str(exc), param_hint="--target") from None
    if removed:
        console.print(f"[green]removed[/green] {name} from {config}")
    else:
        console.print(f"[yellow]{name} was not configured in {config}[/yellow]")


@app.command("mcp-status")
def mcp_status() -> None:
    """Show which MCP clients this server is registered with."""
    from garage_rag.ops.mcp import mcp_status as status

    report = status()
    console.print(f"[dim]server command: {report.server_command}[/dim]\n")

    table = Table()
    for col in ("target", "client", "registered", "config"):
        table.add_column(col)
    for client in report.clients:
        if client.registered:
            state = "[green]yes[/green]"
        elif client.config_exists:
            state = "no"
        else:
            state = "[dim]no config[/dim]"
        table.add_row(client.key, client.label, state, str(client.path).replace(str(Path.home()), "~"))
    console.print(table)


@app.command("mcp-test")
def mcp_test(
    url: Annotated[str | None, typer.Option("--url", help="HTTP endpoint URL to test.")] = None,
    host: Annotated[str | None, typer.Option(help="HTTP host to test.")] = None,
    port: Annotated[int | None, typer.Option("--port", "-p", help="HTTP port to test.")] = None,
    path_route: Annotated[str | None, typer.Option("--path", help="HTTP route to test. Default /mcp.")] = None,
    query: Annotated[str, typer.Option("--query", help="Query string for search test.")] = "test search",
) -> None:
    """Test the MCP server and tool execution."""
    import time

    from garage_rag.mcp_server.server import (
        rag_generate,
        rag_list_authors,
        rag_list_sources,
        rag_search,
        rag_stats,
    )

    settings = get_settings()
    target_host = host or settings.mcp_host
    target_port = port or settings.mcp_port
    route = path_route or settings.mcp_http_path
    target_url = url or f"http://{target_host}:{target_port}{route}"

    console.print("[bold]Testing MCP Server & Tools[/bold]\n")

    # 1. Local tool execution test
    console.print("[cyan]Testing local MCP tool handlers:[/cyan]")
    tool_results = []

    # rag_stats
    t0 = time.perf_counter()
    try:
        stats = rag_stats()
        dt = (time.perf_counter() - t0) * 1000
        tool_results.append(("rag_stats", "PASS", f"{dt:.1f}ms", f"{stats.documents:,} docs, {stats.chunks:,} chunks"))
    except Exception as exc:
        dt = (time.perf_counter() - t0) * 1000
        tool_results.append(("rag_stats", "FAIL", f"{dt:.1f}ms", str(exc)))

    # rag_list_sources
    t0 = time.perf_counter()
    try:
        sources = rag_list_sources()
        dt = (time.perf_counter() - t0) * 1000
        tool_results.append(("rag_list_sources", "PASS", f"{dt:.1f}ms", f"{len(sources.sources)} sources"))
    except Exception as exc:
        dt = (time.perf_counter() - t0) * 1000
        tool_results.append(("rag_list_sources", "FAIL", f"{dt:.1f}ms", str(exc)))

    # rag_list_authors
    t0 = time.perf_counter()
    try:
        authors = rag_list_authors()
        dt = (time.perf_counter() - t0) * 1000
        tool_results.append(("rag_list_authors", "PASS", f"{dt:.1f}ms", f"{len(authors.authors)} authors"))
    except Exception as exc:
        dt = (time.perf_counter() - t0) * 1000
        tool_results.append(("rag_list_authors", "FAIL", f"{dt:.1f}ms", str(exc)))

    # rag_search
    t0 = time.perf_counter()
    try:
        search_res = rag_search(query=query, limit=3)
        dt = (time.perf_counter() - t0) * 1000
        tool_results.append(("rag_search", "PASS", f"{dt:.1f}ms", f"{len(search_res.hits)} hits for {query!r}"))
    except Exception as exc:
        dt = (time.perf_counter() - t0) * 1000
        tool_results.append(("rag_search", "FAIL", f"{dt:.1f}ms", str(exc)))

    # rag_ask / rag_generate share one local model; probe it once and skip both
    # rather than fail when nothing is loaded, since that is a state of the
    # app's Models page, not of the MCP server.
    from garage_rag.enrich.generation import LocalChatModel

    t0 = time.perf_counter()
    try:
        model = LocalChatModel()
        if model.is_available():
            generated = rag_generate(prompt="Reply with the single word: ready", max_tokens=8)
            dt = (time.perf_counter() - t0) * 1000
            tool_results.append(("rag_generate", "PASS", f"{dt:.1f}ms", f"{generated.provider}/{generated.model}"))
            tool_results.append(("rag_ask", "PASS", f"{dt:.1f}ms", "same model as rag_generate"))
        else:
            dt = (time.perf_counter() - t0) * 1000
            details = f"{model.describe()} not loaded (see the app's Models page)"
            tool_results.append(("rag_generate", "SKIP", f"{dt:.1f}ms", details))
            tool_results.append(("rag_ask", "SKIP", f"{dt:.1f}ms", details))
    except Exception as exc:
        dt = (time.perf_counter() - t0) * 1000
        tool_results.append(("rag_generate", "FAIL", f"{dt:.1f}ms", str(exc)))
        tool_results.append(("rag_ask", "FAIL", f"{dt:.1f}ms", str(exc)))

    table = Table()
    for col in ("tool", "status", "latency", "details"):
        table.add_column(col)
    styles = {"PASS": "[green]PASS[/green]", "SKIP": "[yellow]SKIP[/yellow]"}
    for row in tool_results:
        table.add_row(row[0], styles.get(row[1], "[red]FAIL[/red]"), row[2], row[3])
    console.print(table)

    # 2. HTTP Endpoint test if available
    from garage_rag.net import egress

    console.print(f"\n[cyan]Testing HTTP endpoint:[/cyan] {target_url}")
    try:
        opener = egress.url_opener(purpose="mcp-test", base_url=target_url, loopback_only=True)
    except egress.EgressBlocked:
        console.print("  [yellow]skipped[/yellow]: only an endpoint on this machine is probed")
        return
    try:
        t0 = time.perf_counter()
        status_code, _ = opener.request(
            "POST",
            target_url,
            data=json.dumps(
                {
                    "jsonrpc": "2.0",
                    "id": 1,
                    "method": "initialize",
                    "params": {
                        "protocolVersion": "2024-11-05",
                        "capabilities": {},
                        "clientInfo": {"name": "garage-cli-test", "version": "1.0"},
                    },
                }
            ).encode("utf-8"),
            headers={"Content-Type": "application/json", "Accept": "application/json, text/event-stream"},
            timeout=3,
        )
        http_latency = (time.perf_counter() - t0) * 1000
        if status_code >= 400:
            raise OSError(f"HTTP {status_code}")
        console.print(
            f"  [green]HTTP {status_code}[/green] ({http_latency:.1f}ms) - MCP server endpoint reachable and responding"
        )
    except Exception as exc:
        console.print(f"  [yellow]HTTP endpoint not active[/yellow]: {exc}")
        console.print("  [dim]Start the MCP server with `garage mcp-serve --http` or from the macOS app.[/dim]")


@app.command("mcp-serve")
def mcp_serve(
    http: Annotated[
        bool,
        typer.Option("--http", help="Serve over HTTP (streamable-http transport). The default."),
    ] = False,
    sse: Annotated[
        bool,
        typer.Option("--sse", help="Serve over the legacy SSE transport."),
    ] = False,
    host: Annotated[str | None, typer.Option(help="Bind address. Default 127.0.0.1.")] = None,
    port: Annotated[int | None, typer.Option("--port", "-p")] = None,
    path: Annotated[str | None, typer.Option("--path", help="HTTP route. Default /mcp.")] = None,
    allow_origin: Annotated[
        list[str] | None,
        typer.Option("--allow-origin", help="Permit this Origin (repeatable, for browsers)."),
    ] = None,
    allow_host: Annotated[
        list[str] | None,
        typer.Option(
            "--allow-host",
            help=(
                "Permit this Host header, e.g. rag.example.com:8787 or rag.example.com:* "
                "(repeatable). With --allow-remote and no --allow-host, Host checking is off."
            ),
        ),
    ] = None,
    json_response: Annotated[
        bool, typer.Option("--json-response", help="Reply with JSON instead of an SSE stream.")
    ] = False,
    stateless: Annotated[bool, typer.Option("--stateless", help="No session state between requests.")] = False,
    allow_remote: Annotated[
        bool,
        typer.Option(
            "--allow-remote",
            help="Required to bind a non-loopback address. Read the warning first.",
        ),
    ] = False,
) -> None:
    """Run the MCP server over HTTP (streamable-http, the default) or legacy SSE.

    One long-running process serving several clients, or reachable from a
    container or another host. MCP clients that spawn the server over stdio run
    `garage-mcp` instead; `garage mcp-install` registers either.
    """
    from garage_rag.mcp_server.server import is_loopback, serve

    if http and sse:
        raise typer.BadParameter("choose one of --http or --sse")

    settings = get_settings()
    bind_host = host or settings.mcp_host
    bind_port = port or settings.mcp_port
    route = path or settings.mcp_http_path

    if not is_loopback(bind_host) and not allow_remote:
        # This server answers questions about the whole corpus -- potentially
        # including private communications -- and has no authentication
        # whatsoever. Binding it where others can reach it must be deliberate.
        console.print(
            f"[red]refusing to bind {bind_host}[/red]: this server has no "
            "authentication and exposes your entire corpus, including anything "
            "indexed from private communications."
        )
        console.print(
            "  Anyone able to reach that address could read it. If that is "
            "genuinely what you want, re-run with [bold]--allow-remote[/bold], "
            "and put it behind a reverse proxy that authenticates."
        )
        raise typer.Exit(code=1)

    transport = "sse" if sse else "streamable-http"
    scheme_note = " [dim](legacy transport)[/dim]" if sse else ""
    console.print(f"[green]serving[/green] {transport}{scheme_note} on http://{bind_host}:{bind_port}{route}")
    if not is_loopback(bind_host):
        console.print("[yellow]warning[/yellow]: reachable from other machines, unauthenticated")
        if not allow_host:
            console.print(
                "[yellow]warning[/yellow]: no --allow-host given, so the Host header is not "
                "checked (DNS-rebinding protection off); pass the names clients will use to turn it on"
            )
    console.print("[dim]Ctrl-C to stop[/dim]")

    try:
        serve(
            transport,
            host=bind_host,
            port=bind_port,
            path=route,
            allowed_origins=allow_origin or None,
            allowed_hosts=allow_host or None,
            json_response=json_response,
            stateless=stateless,
        )
    except KeyboardInterrupt:
        console.print("\n[dim]stopped[/dim]")


# ---------------------------------------------------------------------------
# search
# ---------------------------------------------------------------------------
@app.command()
def search(
    query: Annotated[str, typer.Argument(help="What to look for.")],
    limit: Annotated[int, typer.Option("--limit", "-n")] = 10,
    mode: Annotated[SearchMode, typer.Option(help="hybrid fuses both engines; fts needs no model.")] = "hybrid",
    model: Annotated[str | None, typer.Option("--model", "-m")] = None,
    corpus_class: Annotated[
        list[str] | None,
        typer.Option("--class", help="document | code | communication (repeatable)"),
    ] = None,
    trust: Annotated[
        list[str] | None,
        typer.Option("--trust", help="authored | reference | received (repeatable)"),
    ] = None,
    source: Annotated[list[str] | None, typer.Option("--source", "-s")] = None,
    author: Annotated[str | None, typer.Option("--author")] = None,
    direction: Annotated[
        Direction | None,
        typer.Option(help="Only message chunks the owner sent, or only those they received."),
    ] = None,
    full: Annotated[bool, typer.Option("--full", help="Print whole snippets.")] = False,
) -> None:
    """Search the corpus with hybrid vector and keyword retrieval."""
    from garage_rag.search.hybrid import search as run_search
    from garage_rag.search.hybrid import snippet

    with session_scope() as session:
        hits = run_search(
            session,
            query,
            limit=limit,
            mode=mode,
            model_slug=model,
            corpus_classes=corpus_class or None,
            trust_tiers=trust or None,
            sources=source or None,
            author=author,
            direction=direction,
        )

    if not hits:
        console.print("[yellow]no results[/yellow]")
        return

    for rank, hit in enumerate(hits, start=1):
        location = hit.uri.replace(str(Path.home()), "~")
        console.print(
            f"\n[bold cyan]{rank}.[/bold cyan] [bold]{hit.title or '(untitled)'}[/bold] "
            f"[dim]({hit.corpus_class}/{hit.trust_tier}, {hit.matched_by}, "
            f"score {hit.score:.4f})[/dim]"
        )
        console.print(f"   [dim]{location}[/dim]")
        if hit.heading_path:
            console.print(f"   [dim]section: {hit.heading_path}[/dim]")
        if hit.authors:
            console.print(f"   [dim]authors: {', '.join(hit.authors[:4])}[/dim]")
        if hit.direction:
            console.print(f"   [dim]{hit.direction}{f' by {hit.sender}' if hit.sender else ''}[/dim]")
        body = hit.text if full else snippet(hit.text)
        console.print(f"   {body}")


@app.command()
def ask(
    question: Annotated[str, typer.Argument(help="Question to answer from the corpus, or a raw prompt with --raw.")],
    raw: Annotated[
        bool, typer.Option("--raw", help="Send the text straight to the model, with no retrieval (rag_generate).")
    ] = False,
    limit: Annotated[int, typer.Option("--limit", "-n", help="Excerpts to retrieve.")] = 6,
    mode: Annotated[SearchMode, typer.Option(help="hybrid fuses both engines; fts needs no model.")] = "hybrid",
    corpus_class: Annotated[
        list[str] | None,
        typer.Option("--class", help="document | code | communication (repeatable)"),
    ] = None,
    trust: Annotated[
        list[str] | None,
        typer.Option("--trust", help="authored | reference | received (repeatable)"),
    ] = None,
    source: Annotated[list[str] | None, typer.Option("--source", "-s")] = None,
    max_tokens: Annotated[int | None, typer.Option("--max-tokens", help="Cap on generated tokens.")] = None,
    temperature: Annotated[float | None, typer.Option("--temperature", "-t")] = None,
    as_json: Annotated[bool, typer.Option("--json", help="Print the result as JSON (what the app parses).")] = False,
) -> None:
    """Ask the local model a question, answered from retrieved excerpts with numbered citations.

    Runs on facts.provider / facts.model (the app's LlamaXPCService or a local
    Ollama server); nothing leaves the machine.
    """
    from dataclasses import asdict

    from garage_rag.enrich.generation import LocalModelUnavailable
    from garage_rag.mcp_server.server import rag_ask, rag_generate

    try:
        if raw:
            generate_kwargs: dict = {}
            if max_tokens is not None:
                generate_kwargs["max_tokens"] = max_tokens
            if temperature is not None:
                generate_kwargs["temperature"] = temperature
            result = rag_generate(prompt=question, **generate_kwargs)
        else:
            ask_kwargs: dict = {
                "limit": limit,
                "mode": mode,
                "corpus_class": corpus_class or None,
                "trust": trust or None,
                "source": source or None,
            }
            if max_tokens is not None:
                ask_kwargs["max_tokens"] = max_tokens
            if temperature is not None:
                ask_kwargs["temperature"] = temperature
            result = rag_ask(question=question, **ask_kwargs)
    except LocalModelUnavailable as exc:
        if as_json:
            print(json.dumps({"error": str(exc)}))
        else:
            console.print(f"[red]model unavailable[/red]: {exc}")
        raise typer.Exit(code=1) from None

    if as_json:
        # Plain print, not the rich console: no wrapping or markup in machine output.
        print(json.dumps(asdict(result), ensure_ascii=False))
        return

    if raw:
        console.print(result.text, markup=False, highlight=False)
        console.print(f"\n[dim]{result.provider}/{result.model}[/dim]")
        return

    console.print(result.answer, markup=False, highlight=False)
    footer = f"{result.provider}/{result.model}"
    if result.prompt_tokens is not None or result.completion_tokens is not None:
        footer += f", tokens in/out {result.prompt_tokens or 0}/{result.completion_tokens or 0}"
    console.print(f"\n[dim]{footer}[/dim]")
    if not result.citations:
        console.print("[yellow]no excerpts retrieved[/yellow]")
        return
    table = Table(title="citations")
    for col in ("n", "title", "location", "score", "snippet"):
        table.add_column(col)
    for c in result.citations:
        table.add_row(f"[{c.n}]", c.title or "(untitled)", c.location, f"{c.score:.4f}", c.snippet)
    console.print(table)


# ---------------------------------------------------------------------------
# extraction / chunking inspection
# ---------------------------------------------------------------------------
@app.command("extract")
def extract_cmd(
    path: Annotated[Path, typer.Argument(help="File to extract and chunk.")],
    show: Annotated[int, typer.Option(help="How many chunks to print.")] = 3,
    full: Annotated[bool, typer.Option("--full", help="Print whole chunks.")] = False,
) -> None:
    """Extract and chunk a single file without touching the database."""
    from garage_rag.extract.base import ExtractionError, NoTextFound
    from garage_rag.extract.dispatch import extract as run_extract
    from garage_rag.extract.placeholder import PlaceholderFile
    from garage_rag.ingest.chunking import chunk_text

    target = path.expanduser()
    try:
        result = run_extract(target)
    except PlaceholderFile as exc:
        # Not a parser problem: the bytes are not on this machine.
        console.print(f"[yellow]placeholder[/yellow] ({exc.provider}): {target}")
        console.print("  no local content; make it available offline, then re-run")
        raise typer.Exit(code=2) from None
    except NoTextFound as exc:
        console.print(f"[yellow]no text[/yellow]: {exc}")
        raise typer.Exit(code=0) from None
    except ExtractionError as exc:
        console.print(f"[red]extraction failed[/red]: {exc}")
        raise typer.Exit(code=1) from None

    chunks = chunk_text(
        result.text,
        result.kind,
        extension=target.suffix.lower(),
    )

    console.print(f"[bold]{target}[/bold]")
    console.print(f"  extractor : [cyan]{result.extractor}[/cyan] v{result.extractor_version}")
    console.print(f"  kind      : {result.kind}")
    console.print(f"  title     : {result.title!r}")
    console.print(f"  chars     : {len(result.text):,}")
    console.print(f"  chunks    : {len(chunks)}")
    if chunks:
        sizes = [len(c.text) for c in chunks]
        console.print(f"  chunk len : min={min(sizes)} median={sorted(sizes)[len(sizes) // 2]} max={max(sizes)}")
        console.print(f"  chunker   : {chunks[0].chunker}")
    if result.meta:
        console.print(f"  meta      : {result.meta}")
    if result.author_hints:
        console.print(f"  author?   : {result.author_hints}")

    for chunk in chunks[:show]:
        console.print()
        header = f"[dim]--- chunk {chunk.ord} ({len(chunk.text)} chars)"
        if chunk.heading_path:
            header += f" | {chunk.heading_path}"
        console.print(header + " ---[/dim]")
        body = chunk.text if full else chunk.text[:400]
        console.print(body + ("" if full or len(chunk.text) <= 400 else " [dim]...[/dim]"))


def get_version() -> str:
    import garage_rag

    return getattr(garage_rag, "__version__", "1.5.0")


@app.command("version")
def version_cmd() -> None:
    """Print the garage version."""
    console.print(f"garage v{get_version()}")


@app.command("serve")
def serve(
    host: Annotated[str, typer.Option("--host", "-h", help="gRPC host binding.")] = "127.0.0.1",
    port: Annotated[int, typer.Option("--port", "-p", help="gRPC port.")] = 50051,
    socket: Annotated[
        str | None,
        typer.Option("--socket", help="Listen on this Unix-domain socket (absolute path) instead of host:port."),
    ] = None,
) -> None:
    """Start the long-running gRPC server the macOS app reads the corpus through."""
    where = f"unix:{socket}" if socket else f"{host}:{port}"
    console.print(f"[bold green]Starting Garage gRPC Server[/bold green] on {where}...")
    from garage_rag.service.server import serve_grpc

    serve_grpc(host=host, port=port, socket_path=socket)


def _is_database_error(exc: BaseException) -> bool:
    """A SQLAlchemy or psycopg error. psycopg is consulted only if it was loaded:
    an exception cannot come from a driver that was never imported."""
    if isinstance(exc, DBAPIError):
        return True
    psycopg = sys.modules.get("psycopg")
    return psycopg is not None and isinstance(exc, psycopg.Error)


def _pgvector_library_hint(exc: BaseException) -> str | None:
    """If ``exc`` was caused by Postgres failing to load the pgvector native
    library (SQLSTATE 58P01, "could not access file ..."), return an
    actionable message. Returns None for every other failure so callers fall
    back to a normal error report.
    """
    seen: set[int] = set()
    current: BaseException | None = exc
    while current is not None and id(current) not in seen:
        seen.add(id(current))
        # SQLSTATE 58P01 (psycopg.errors.UndefinedFile), read off the exception
        # so the CLI imports without a database driver.
        if getattr(current, "sqlstate", None) == "58P01":
            return (
                "Postgres could not load the pgvector extension's native library "
                f"({current}). The 'vector' type is registered but its shared "
                "library is missing or unreadable next to this Postgres install -- "
                "vector columns cannot be read or written until that's fixed. "
                "Check Contents/Resources/postgres/lib and .../share/extension "
                "for vector.dylib and vector.control in the app bundle."
            )
        orig = getattr(current, "orig", None)
        current = orig or current.__cause__ or current.__context__
    return None


def main_cli() -> int:
    """Main CLI entrypoint."""
    # Ensure stdin, stdout, and stderr are attached and valid for CLI execution
    if sys.stdin is None or not hasattr(sys.stdin, "read"):
        try:
            sys.stdin = open(0, encoding="utf-8", errors="replace", closefd=False)  # noqa: SIM115
            sys.__stdin__ = sys.stdin
        except Exception:
            pass
    if sys.stdout is None or not hasattr(sys.stdout, "write"):
        try:
            sys.stdout = open(  # noqa: SIM115
                1, mode="w", buffering=1, encoding="utf-8", errors="replace", closefd=False
            )
            sys.__stdout__ = sys.stdout
        except Exception:
            pass
    if sys.stderr is None or not hasattr(sys.stderr, "write"):
        try:
            sys.stderr = open(  # noqa: SIM115
                2, mode="w", buffering=1, encoding="utf-8", errors="replace", closefd=False
            )
            sys.__stderr__ = sys.stderr
        except Exception:
            pass

    try:
        app()
        return 0
    except SystemExit as se:
        return se.code if isinstance(se.code, int) else 0
    except Exception as exc:
        if not _is_database_error(exc):
            raise
        hint = _pgvector_library_hint(exc)
        log.error("database error: %s", exc, exc_info=True)
        console.print(f"[red]database error[/red]: {hint or exc}")
        return 1


if __name__ == "__main__":
    sys.exit(main_cli())
