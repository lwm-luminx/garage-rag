"""Extension routing in ``garage_rag.extract.dispatch``."""

from __future__ import annotations

from pathlib import Path

import pytest

from garage_rag.extract import dispatch
from garage_rag.extract.base import UnsupportedFile
from garage_rag.extract.dispatch import extractor_for, extractor_revision


def _every_routable_path() -> list[Path]:
    """One path per entry of every table ``extractor_for`` routes by."""
    paths = [Path(f"file{suffix}") for suffix in dispatch.INDEXABLE_EXTENSIONS]
    paths.extend(Path(name) for name in dispatch.NAMED_CODE_FILES)
    return paths


@pytest.mark.parametrize("path", _every_routable_path(), ids=str)
def test_every_extractor_has_a_revision(path: Path):
    """``extractor_revision`` must know every extractor ``extractor_for`` can return.

    The two are separate tables; a new extractor added to one but not the other
    made ``.eml`` files crash the ingest outcome bookkeeping instead of being
    remembered.
    """
    extractor = extractor_for(path)
    assert extractor in dispatch._EXTRACTOR_MODULES, f"{extractor.__name__} has no _EXTRACTOR_MODULES entry"
    revision = extractor_revision(path)
    name, _, version = revision.partition(":")
    assert name == dispatch._EXTRACTOR_MODULES[extractor][0]
    assert version


@pytest.mark.parametrize("name", ["saved.eml", "1.emlx", "1.partial.emlx"])
def test_email_files_report_the_mail_extractor_revision(name: str):
    from garage_rag.extract import mail

    assert extractor_revision(Path(name)) == f"email:{mail.VERSION}"


def test_unsupported_files_have_an_empty_revision():
    for name in ("legacy.doc", "outlook.msg", "unknown.xyz"):
        with pytest.raises(UnsupportedFile):
            extractor_for(Path(name))
        assert extractor_revision(Path(name)) == ""
