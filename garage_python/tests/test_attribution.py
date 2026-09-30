"""Attribution: trust classification, identity matching, and path rules."""

from __future__ import annotations

from pathlib import Path
from unittest.mock import MagicMock

import pytest

from garage_rag.attribute.git import remote_owner
from garage_rag.attribute.pathrules import classify_path, is_vendored
from garage_rag.attribute.resolver import SelfIdentity, get_or_create_author
from garage_rag.db.models import Author, AuthorIdentity, CorpusClass, TrustTier
from garage_rag.extract.base import ContentKind, clean_author_hints, looks_like_tool_name
from garage_rag.extract.office import _core_properties
from garage_rag.extract.pdf import _pdf_metadata
from garage_rag.extract.text import extract_markdown, read_text_file
from garage_rag.ingest.classify import classify, is_code_path


class TestSelfIdentity:
    def setup_method(self) -> None:
        self.me = SelfIdentity(
            "Rick Mark",
            [("git_email", "rickmark@outlook.com"), ("git_name", "Rick Mark")],
        )

    def test_matches_email_case_insensitively(self) -> None:
        assert self.me.matches(email="RickMark@Outlook.com")

    def test_matches_name(self) -> None:
        assert self.me.matches(name="rick mark")

    def test_rejects_other_people(self) -> None:
        assert not self.me.matches(name="Nikias Bassen", email="nikias@gmail.com")

    def test_email_beats_name_mismatch(self) -> None:
        """A commit under a different display name but the owner's email is theirs."""
        assert self.me.matches(name="rmark", email="rickmark@outlook.com")


class TestPathRules:
    ROOT = Path("/Users/x/Dropbox")

    @pytest.mark.parametrize(
        "relative",
        [
            "Reference/Documentation/thing.pdf",
            "Reference/Companion Survival Resource Library/Army Field Manuals/fm.pdf",
            "Documents/Paper/Reference/paper.pdf",
        ],
    )
    def test_reference_trees(self, relative: str) -> None:
        trust, label = classify_path(self.ROOT / relative, self.ROOT)
        assert trust is TrustTier.REFERENCE, label

    @pytest.mark.parametrize(
        "relative",
        ["Personal/notes.md", "Projects/thing/plan.md", "Documents/Research/study.md"],
    )
    def test_authored_trees(self, relative: str) -> None:
        trust, label = classify_path(self.ROOT / relative, self.ROOT)
        assert trust is TrustTier.AUTHORED, label

    def test_vendored_is_reference_anywhere(self) -> None:
        """Third-party code is third-party wherever it sits."""
        path = self.ROOT / "Projects/app/node_modules/lib/README.md"
        trust, label = classify_path(path, self.ROOT)
        assert trust is TrustTier.REFERENCE
        assert label == "path:vendored"

    @pytest.mark.parametrize("marker", ["node_modules", "vendor", "Pods", "third_party", "site-packages"])
    def test_vendor_markers(self, marker: str) -> None:
        assert is_vendored(Path(f"/a/b/{marker}/c/d.md"))

    def test_unmatched_path_uses_supplied_default(self) -> None:
        trust, label = classify_path(self.ROOT / "Misc/thing.md", self.ROOT, default=TrustTier.RECEIVED)
        assert trust is TrustTier.RECEIVED
        assert label == "path:default"


class TestRemoteOwner:
    @pytest.mark.parametrize(
        ("remote", "expected"),
        [
            ("git@github.com:hack-different/libimobiledevice.git", "hack-different"),
            ("https://github.com/rickmark/garage.git", "rickmark"),
            ("https://github.com/anza-xyz/agave", "anza-xyz"),
            ("ssh://git@gitlab.com/group/repo.git", "group"),
            # A port after the host used to be misread as scp-style syntax,
            # yielding "git@github.com:22" as the owner.
            ("ssh://git@github.com:22/owner/repo.git", "owner"),
            ("ssh://git@git.example.com:2222/team/project", "team"),
            ("https://user:token@github.com/owner/repo.git", "owner"),
            ("github.com/owner/repo", "owner"),
            (None, None),
            ("", None),
        ],
    )
    def test_owner_extraction(self, remote: str | None, expected: str | None) -> None:
        assert remote_owner(remote) == expected


class TestTextDecoding:
    """``read_text_file`` decode order: BOM-aware, never blind UTF-16."""

    def test_utf8_bom_is_stripped_so_frontmatter_is_detected(self, tmp_path: Path) -> None:
        path = tmp_path / "note.md"
        path.write_bytes(b"\xef\xbb\xbf---\ntitle: Hello\nauthor: Ann\n---\n\n# Body\n")

        text, encoding = read_text_file(path)
        assert encoding == "utf-8-sig"
        assert text.startswith("---")

        result = extract_markdown(path)
        assert result.title == "Hello"
        assert result.author_hints == ["Ann"]
        assert result.meta["encoding"] == "utf-8-sig"

    def test_plain_utf8_reports_utf8(self, tmp_path: Path) -> None:
        path = tmp_path / "a.txt"
        path.write_bytes("caf\u00e9\n".encode())
        assert read_text_file(path) == ("caf\u00e9\n", "utf-8")

    def test_utf16_only_with_bom(self, tmp_path: Path) -> None:
        path = tmp_path / "a.txt"
        path.write_bytes("caf\u00e9 au lait\n".encode("utf-16"))
        assert read_text_file(path) == ("caf\u00e9 au lait\n", "utf-16")

    def test_latin1_bytes_are_not_mistaken_for_utf16(self, tmp_path: Path) -> None:
        # Even length, no BOM: Python's utf-16 codec would happily decode this
        # into CJK garbage if it were tried before the single-byte encodings.
        path = tmp_path / "a.txt"
        raw = b"caf\xe9 au lait!\n"
        assert len(raw) % 2 == 0
        path.write_bytes(raw)
        text, encoding = read_text_file(path)
        assert text == "caf\u00e9 au lait!\n"
        assert encoding == "cp1252"

    def test_bytes_cp1252_rejects_fall_back_to_latin1(self, tmp_path: Path) -> None:
        path = tmp_path / "a.txt"
        path.write_bytes(b"x\x81y")
        assert read_text_file(path) == ("x\x81y", "latin-1")


class TestMetadataProvenance:
    """Tool names stay in ``meta`` for provenance; only author hints are filtered."""

    def test_pdf_keeps_producer_and_title_but_filters_author_hints(self) -> None:
        info = MagicMock()
        info.author = "Microsoft Word; Jane Doe"
        info.title = "Typesetting with LaTeX"
        info.creator = "Microsoft Word for Mac"
        info.producer = "Acrobat Distiller"
        info.get.return_value = None
        reader = MagicMock()
        reader.metadata = info

        meta, hints, title = _pdf_metadata(reader)

        assert meta["pdf_author"] == "Microsoft Word; Jane Doe"
        assert meta["pdf_title"] == "Typesetting with LaTeX"
        assert meta["pdf_creator"] == "Microsoft Word for Mac"
        assert meta["pdf_producer"] == "Acrobat Distiller"
        assert title == "Typesetting with LaTeX"
        assert clean_author_hints(hints) == ["Jane Doe"]

    def test_office_core_properties_accept_openpyxl_spelling(self) -> None:
        class XlsxProps:
            creator = "Jane Doe"
            lastModifiedBy = "Bob Roe"  # noqa: N815 - openpyxl's attribute name
            title = "Budget"

        meta, hints, title = _core_properties(XlsxProps())

        assert meta == {
            "office_author": "Jane Doe",
            "office_last_modified_by": "Bob Roe",
            "office_title": "Budget",
        }
        assert hints == ["Jane Doe", "Bob Roe"]
        assert title == "Budget"

    def test_office_core_properties_docx_spelling_unchanged(self) -> None:
        class DocxProps:
            author = "Jane Doe"
            last_modified_by = "Jane Doe"
            title = ""

        meta, hints, title = _core_properties(DocxProps())

        assert meta == {"office_author": "Jane Doe"}
        assert hints == ["Jane Doe"]
        assert title is None


class TestCorpusClassification:
    def test_code_extension_is_code(self) -> None:
        assert classify(Path("/r/app/main.py"), ContentKind.CODE) is CorpusClass.CODE

    def test_readme_in_repo_stays_document(self) -> None:
        """A README is prose about code, not code."""
        assert classify(Path("/r/app/README.md"), ContentKind.MARKDOWN) is CorpusClass.DOCUMENT

    def test_license_without_extension_is_document(self) -> None:
        assert not is_code_path(Path("/r/LICENSE"))

    def test_conversation_is_communication(self) -> None:
        assert classify(Path("/x/thread.txt"), ContentKind.CONVERSATION) is CorpusClass.COMMUNICATION

    def test_code_path_excludes_docs(self) -> None:
        assert is_code_path(Path("/r/x.swift"))
        assert not is_code_path(Path("/r/x.md"))

    @pytest.mark.parametrize("name", ["security.rb", "license.py", "changelog.js", "authors.go", "readme.ts"])
    def test_doc_stem_does_not_override_code_extension(self, name: str) -> None:
        """Regression: a source file named `security.rb` is code, not prose.

        The documentation-stem list exists for SECURITY.md and LICENSE, but
        applying it before the extension check misfiled real source files as
        documents, which then bypassed the code filter entirely.
        """
        path = Path("/r/app") / name
        assert classify(path, ContentKind.CODE) is CorpusClass.CODE
        assert is_code_path(path)

    @pytest.mark.parametrize("name", ["SECURITY.md", "README.md", "LICENSE", "CHANGELOG"])
    def test_documentation_names_still_documents(self, name: str) -> None:
        path = Path("/r/app") / name
        assert classify(path, ContentKind.MARKDOWN) is CorpusClass.DOCUMENT
        assert not is_code_path(path)


class TestToolNameFiltering:
    @pytest.mark.parametrize(
        "value",
        ["openpyxl", "Steve Canny", "Microsoft Word", "Adobe InDesign 21.2", "unknown", "admin"],
    )
    def test_rejects_software_and_placeholders(self, value: str) -> None:
        assert looks_like_tool_name(value)

    @pytest.mark.parametrize("value", ["Rick Mark", "Nikias Bassen", "Ada Lovelace"])
    def test_accepts_real_names(self, value: str) -> None:
        assert not looks_like_tool_name(value)

    def test_clean_hints_dedupes_and_filters(self) -> None:
        out = clean_author_hints(["Ada Lovelace", "openpyxl", "ada lovelace", "  ", "Grace Hopper"])
        assert out == ["Ada Lovelace", "Grace Hopper"]


class TestGetOrCreateAuthor:
    def test_with_dict_identities(self) -> None:
        mock_session = MagicMock()
        mock_session.query.return_value.filter_by.return_value.one_or_none.return_value = None

        author = get_or_create_author(
            mock_session,
            "Rick Mark",
            identities={"git_email": "rickmark@outlook.com", "git_name": "Rick Mark"},
            is_self=True,
        )

        assert author.display_name == "Rick Mark"
        assert author.is_self is True
        assert mock_session.add.call_count >= 1
        added_objs = [call.args[0] for call in mock_session.add.call_args_list]
        added_identities = [obj for obj in added_objs if isinstance(obj, AuthorIdentity)]
        assert len(added_identities) == 2
        kinds_values = {(ident.kind, ident.value) for ident in added_identities}
        assert ("git_email", "rickmark@outlook.com") in kinds_values
        assert ("git_name", "Rick Mark") in kinds_values

    def test_with_list_tuples_identities(self) -> None:
        mock_session = MagicMock()
        mock_session.query.return_value.filter_by.return_value.one_or_none.return_value = None

        author = get_or_create_author(
            mock_session,
            "Nikias Bassen",
            identities=[("email", "nikias@gmail.com")],
            is_self=False,
        )

        assert author.display_name == "Nikias Bassen"
        assert author.is_self is False
        added_objs = [call.args[0] for call in mock_session.add.call_args_list]
        added_identities = [obj for obj in added_objs if isinstance(obj, AuthorIdentity)]
        assert len(added_identities) == 1
        assert added_identities[0].kind == "email"
        assert added_identities[0].value == "nikias@gmail.com"

    def test_with_none_identities(self) -> None:
        mock_session = MagicMock()
        mock_session.query.return_value.filter_by.return_value.one_or_none.return_value = None

        author = get_or_create_author(
            mock_session,
            "Unknown Author",
            identities=None,
        )

        assert author.display_name == "Unknown Author"

    def test_matches_existing_identity(self) -> None:
        mock_session = MagicMock()
        existing_author = MagicMock(spec=Author)
        existing_author.id = 42
        mock_identity = MagicMock(spec=AuthorIdentity)
        mock_identity.author = existing_author

        mock_session.query.return_value.filter_by.return_value.one_or_none.return_value = mock_identity

        author = get_or_create_author(
            mock_session,
            "Rick",
            identities={"git_email": "rickmark@outlook.com"},
        )

        assert author == existing_author
