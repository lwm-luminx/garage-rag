"""One file's read as the Rust ingest loop takes it from its host (``garage_ingest_run_source``).

``rust/garage-ingest`` walks a source, makes placeholders local, hashes each file and stores what it
decides through GarageService; the text still comes from the readers here until each has a Rust
port. The service hosting the Rust loop calls :func:`read_for_host` for each file and hands back the
JSON it returns, which says what :func:`garage_rag.ingest.pipeline.ingest_one` would have made of
the same read:

* ``{"document": {"text", "kind", "extractor", "extractor_version", "title", "lang", "meta",
  "author_hints"}}`` for a document;
* ``{"no_text": reason}`` for a file that holds no text (:class:`NoTextFound`);
* ``{"placeholder": true}`` for a cloud placeholder, including a read the kernel declined to download;
* ``{"failed": reason}`` for a reader's failure (:class:`ExtractionError`, :class:`OSError`), which
  is remembered with the file;
* ``{"raised": reason}`` for anything else, which the run notes and records as seen.

For a Messages source the loop reads ``chat.db`` itself and asks the host only for the names
iMessage contacts shared, which :func:`shared_names_for_host` reads from the ``NickNameCache``
beside it.
"""

from __future__ import annotations

import json
from collections.abc import Callable
from pathlib import Path

from garage_rag.extract.base import ExtractionError, ExtractResult, NoTextFound
from garage_rag.extract.dispatch import extract
from garage_rag.extract.nicknames import read_shared_names
from garage_rag.extract.placeholder import PlaceholderFile
from garage_rag.ingest.materialize import refused_dataless_read


def read_for_host(path: Path | str, *, reader: Callable[[Path], ExtractResult] | None = None) -> dict:
    """What reading ``path`` gave, as the Rust loop's host replies (see the module docstring)."""
    path = Path(path)
    try:
        result = (reader or extract)(path)
    except NoTextFound as exc:
        return {"no_text": str(exc)}
    except PlaceholderFile:
        return {"placeholder": True}
    except (ExtractionError, OSError) as exc:
        if refused_dataless_read(exc):
            return {"placeholder": True}
        return {"failed": str(exc)}
    except Exception as exc:  # noqa: BLE001 - the loop notes it, as _ingest_source's handler does
        return {"raised": str(exc)}
    try:
        # Through JSON as the facade sends it. A value JSON cannot hold fails here rather than at the
        # facade, so it is noted before the quality gate where Python's loop notes it after.
        meta = json.loads(json.dumps(result.meta)) if result.meta else {}
    except (TypeError, ValueError) as exc:
        return {"raised": str(exc)}
    return {
        "document": {
            "text": result.text,
            "kind": result.kind.value,
            "extractor": result.extractor,
            "extractor_version": result.extractor_version,
            "title": result.title,
            "lang": result.lang,
            "meta": meta,
            "author_hints": list(result.author_hints),
        }
    }


def read_for_host_json(path: str) -> str:
    """:func:`read_for_host` as a JSON string, for a host that passes strings across."""
    return json.dumps(read_for_host(path))


def shared_names_for_host(directory: Path | str) -> dict:
    """``{"names": [[handle, name], ...]}``: the names shared with the owner, beside a Messages database."""
    return {"names": [[handle, name] for handle, name in read_shared_names(Path(directory))]}


def shared_names_for_host_json(directory: str) -> str:
    """:func:`shared_names_for_host` as a JSON string."""
    return json.dumps(shared_names_for_host(directory))


__all__ = ["read_for_host", "read_for_host_json", "shared_names_for_host", "shared_names_for_host_json"]
