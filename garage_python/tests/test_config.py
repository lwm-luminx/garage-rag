"""The single-file configuration.

The invariants that matter: the nested file and the flat model cannot drift, a
typo is reported rather than ignored, and no setting is reachable only through an
environment variable.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

import pytest

from garage_rag.config import (
    CONFIG_FILENAME,
    SCHEMA_URL,
    SECTIONS,
    USER_CONFIG_FILENAME,
    ConfigError,
    Settings,
    SourceSpec,
    candidate_paths,
    default_config_path,
    expand_home,
    flatten,
    json_schema,
    load_config,
    nest,
    save_config,
)


class TestSectionMapping:
    def test_every_field_is_reachable_from_the_file(self) -> None:
        """A setting absent from SECTIONS could never be configured at all."""
        mapped = {field for mapping in SECTIONS.values() for field in mapping.values()}
        mapped |= {"sources", "config_path"}
        unreachable = set(Settings.model_fields) - mapped
        assert not unreachable, f"unreachable settings: {sorted(unreachable)}"

    def test_no_field_is_mapped_twice(self) -> None:
        seen: set[str] = set()
        for mapping in SECTIONS.values():
            for field in mapping.values():
                assert field not in seen, f"{field} mapped in two sections"
                seen.add(field)

    def test_every_mapped_field_exists(self) -> None:
        for section, mapping in SECTIONS.items():
            for key, field in mapping.items():
                assert field in Settings.model_fields, f"{section}.{key} -> {field}"


class TestRoundTrip:
    def test_defaults_round_trip(self) -> None:
        original = Settings()
        restored = Settings(**flatten(nest(original)))
        assert restored.model_dump(exclude={"config_path"}) == original.model_dump(exclude={"config_path"})

    def test_non_defaults_round_trip(self) -> None:
        original = Settings(
            database_url="postgresql+psycopg:///other",
            chunk_size=512,
            self_identities=["git_email:a@b.c"],
            materialize_placeholders=True,
            materialize_timeout_seconds=42.5,
            lmstudio_api_token_file="~/.lmstudio-token",
        )
        restored = Settings(**flatten(nest(original)))
        assert restored.chunk_size == 512
        assert restored.self_identities == ["git_email:a@b.c"]
        assert restored.materialize_placeholders is True
        assert restored.materialize_timeout_seconds == 42.5
        assert restored.lmstudio_api_token_file == "~/.lmstudio-token"

    def test_diff_view_omits_defaults(self) -> None:
        settings = Settings(chunk_size=999)
        document = nest(settings, include_defaults=False)
        assert document["chunking"] == {"size": 999}
        assert "extraction" not in document


class TestLoading:
    def _write(self, path: Path, document: dict) -> Path:
        path.write_text(json.dumps(document), encoding="utf-8")
        return path

    def test_loads_nested_file(self, tmp_path: Path) -> None:
        cfg = self._write(
            tmp_path / CONFIG_FILENAME,
            {"database": {"url": "postgresql+psycopg:///x"}, "chunking": {"size": 250}},
        )
        settings = load_config(cfg)
        assert settings.database_url == "postgresql+psycopg:///x"
        assert settings.chunk_size == 250
        assert settings.config_path == cfg

    def test_unset_values_fall_back_to_defaults(self, tmp_path: Path) -> None:
        cfg = self._write(tmp_path / CONFIG_FILENAME, {"chunking": {"size": 1}})
        assert load_config(cfg).chunk_overlap == Settings().chunk_overlap

    def test_schema_key_is_ignored(self, tmp_path: Path) -> None:
        cfg = self._write(tmp_path / CONFIG_FILENAME, {"$schema": "./garage.schema.json", "mcp": {"port": 1}})
        assert load_config(cfg).mcp_port == 1

    def test_unknown_section_is_an_error(self, tmp_path: Path) -> None:
        """A silently ignored typo is a bug found hours later."""
        cfg = self._write(tmp_path / CONFIG_FILENAME, {"chunkng": {"size": 1}})
        with pytest.raises(ConfigError, match="unknown section"):
            load_config(cfg)

    def test_unknown_key_is_an_error(self, tmp_path: Path) -> None:
        cfg = self._write(tmp_path / CONFIG_FILENAME, {"chunking": {"sizee": 1}})
        with pytest.raises(ConfigError, match="unknown key"):
            load_config(cfg)

    def test_error_names_the_valid_keys(self, tmp_path: Path) -> None:
        cfg = self._write(tmp_path / CONFIG_FILENAME, {"chunking": {"nope": 1}})
        with pytest.raises(ConfigError, match="overlap"):
            load_config(cfg)

    def test_malformed_json_is_an_error(self, tmp_path: Path) -> None:
        cfg = tmp_path / CONFIG_FILENAME
        cfg.write_text("{not json", encoding="utf-8")
        with pytest.raises(ConfigError, match="not valid JSON"):
            load_config(cfg)

    def test_wrong_type_is_an_error(self, tmp_path: Path) -> None:
        cfg = self._write(tmp_path / CONFIG_FILENAME, {"chunking": {"size": "big"}})
        with pytest.raises(ConfigError):
            load_config(cfg)

    def test_section_must_be_an_object(self, tmp_path: Path) -> None:
        cfg = self._write(tmp_path / CONFIG_FILENAME, {"chunking": [1, 2]})
        with pytest.raises(ConfigError, match="must be an object"):
            load_config(cfg)

    def test_explicit_missing_path_is_an_error(self, tmp_path: Path) -> None:
        with pytest.raises(ConfigError, match="no config file found"):
            load_config(tmp_path / "absent.json")

    def test_no_file_anywhere_yields_defaults(self, tmp_path: Path, monkeypatch) -> None:
        monkeypatch.chdir(tmp_path)
        monkeypatch.setattr(Path, "home", classmethod(lambda cls: tmp_path))
        settings = load_config()
        assert settings.chunk_size == Settings().chunk_size
        assert settings.config_path is None

    def test_search_order_prefers_project_over_user(self, tmp_path: Path, monkeypatch) -> None:
        monkeypatch.chdir(tmp_path)
        assert candidate_paths()[0] == tmp_path / CONFIG_FILENAME

    def test_default_is_a_home_dotfile(self, tmp_path: Path, monkeypatch) -> None:
        """The documented default: ~/.garage.json."""
        monkeypatch.setattr(Path, "home", classmethod(lambda cls: tmp_path))
        assert default_config_path() == tmp_path / ".garage.json"
        assert USER_CONFIG_FILENAME == ".garage.json"
        assert candidate_paths()[-1] == tmp_path / ".garage.json"

    def test_user_default_is_found_when_no_project_file(self, tmp_path: Path, monkeypatch) -> None:
        home = tmp_path / "home"
        work = tmp_path / "work"
        home.mkdir()
        work.mkdir()
        monkeypatch.setattr(Path, "home", classmethod(lambda cls: home))
        monkeypatch.chdir(work)
        (home / ".garage.json").write_text(json.dumps({"mcp": {"port": 4242}}))
        settings = load_config()
        assert settings.mcp_port == 4242
        assert settings.config_path == home / ".garage.json"


class TestSaving:
    def test_save_then_load(self, tmp_path: Path) -> None:
        settings = Settings(chunk_size=321, self_name="Someone")
        path = tmp_path / CONFIG_FILENAME
        save_config(settings, path)
        loaded = load_config(path)
        assert loaded.chunk_size == 321
        assert loaded.self_name == "Someone"

    def test_saved_file_references_the_published_schema_url(self, tmp_path: Path) -> None:
        """A URL, not a sibling path: the config lives in $HOME while the schema
        is a build artifact of this repository, so a relative reference would
        dangle."""
        path = tmp_path / CONFIG_FILENAME
        save_config(Settings(), path)
        ref = json.loads(path.read_text())["$schema"]
        assert ref == SCHEMA_URL
        assert ref.startswith("https://")

    def test_no_schema_file_is_written_beside_the_config(self, tmp_path: Path) -> None:
        save_config(Settings(), tmp_path / USER_CONFIG_FILENAME)
        assert list(tmp_path.iterdir()) == [tmp_path / USER_CONFIG_FILENAME]

    def test_creates_parent_directories(self, tmp_path: Path) -> None:
        path = tmp_path / "a" / "b" / CONFIG_FILENAME
        save_config(Settings(), path)
        assert path.is_file()

    def test_no_temp_file_left_behind(self, tmp_path: Path) -> None:
        path = tmp_path / CONFIG_FILENAME
        save_config(Settings(), path)
        assert not list(tmp_path.glob("*.tmp"))


class TestSources:
    def test_class_uses_the_reserved_word_alias(self) -> None:
        """`class` is a Python keyword, so the field is corpus_class internally."""
        spec = SourceSpec(slug="a", root="~/x", **{"class": "code"})
        assert spec.corpus_class == "code"
        assert spec.model_dump(by_alias=True)["class"] == "code"

    def test_root_expansion(self) -> None:
        spec = SourceSpec(slug="a", root="~/Documents")
        assert spec.expanded_root.is_absolute()
        assert "~" not in str(spec.expanded_root)

    def test_root_expansion_in_a_sandbox_uses_the_account_home(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """A sandboxed process's $HOME is its container; ~ must still name the real home folder."""
        import pwd

        monkeypatch.setenv("HOME", "/Users/me/Library/Containers/me.rickmark.garage-rag.xpc/Data")
        monkeypatch.setenv("APP_SANDBOX_CONTAINER_ID", "me.rickmark.garage-rag.xpc")
        home = Path(pwd.getpwuid(os.getuid()).pw_dir)
        assert SourceSpec(slug="a", root="~/Documents").expanded_root == home / "Documents"
        assert expand_home("~") == home
        assert expand_home("/abs/~x") == Path("/abs/~x")

    def test_root_expansion_outside_a_sandbox_follows_home(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.delenv("APP_SANDBOX_CONTAINER_ID", raising=False)
        monkeypatch.setenv("HOME", "/tmp/elsewhere")
        assert expand_home("~/Documents") == Path("/tmp/elsewhere/Documents")

    def test_defaults(self) -> None:
        spec = SourceSpec(slug="a", root="/x")
        assert spec.kind == "filesystem"
        assert spec.corpus_class == "document"
        assert spec.trust == "authored"
        assert spec.include_code is False
        assert spec.enabled is True

    def test_unknown_source_key_is_rejected(self) -> None:
        with pytest.raises(Exception, match="extra_forbidden|Extra inputs"):
            SourceSpec(slug="a", root="/x", **{"corpus_class": "document"})

    def test_sources_load_from_file(self, tmp_path: Path) -> None:
        cfg = tmp_path / CONFIG_FILENAME
        cfg.write_text(
            json.dumps(
                {
                    "sources": [
                        {"slug": "notes", "root": "~/Documents", "class": "document"},
                        {"slug": "code", "root": "~/dev", "class": "code", "include_code": True},
                    ]
                }
            )
        )
        settings = load_config(cfg)
        assert [s.slug for s in settings.sources] == ["notes", "code"]
        by_slug = {s.slug: s for s in settings.sources}
        assert by_slug["code"].include_code is True
        assert "missing" not in by_slug

    def test_retired_keys_are_skipped_with_a_warning(self, tmp_path: Path, caplog) -> None:
        """Settings that were removed must not break a config written before."""
        cfg = tmp_path / CONFIG_FILENAME
        cfg.write_text(
            json.dumps(
                {
                    "embedding": {"max_inflight": 4, "batch_size": 8},
                    "chunking": {"comms_window_minutes": 5, "comms_window_messages": 9},
                    "extraction": {"workers": 3},
                    "cloud": {"max_images": 12},
                }
            )
        )
        with caplog.at_level("WARNING", logger="garage_rag.config"):
            settings = load_config(cfg)
        assert settings.embed_batch_size == 8
        for key in ("max_inflight", "comms_window_minutes", "comms_window_messages", "workers", "max_images"):
            assert key in caplog.text, key
        # Retired keys are not resurrected as attributes, and are not in the schema.
        for name in ("embed_max_inflight", "comms_window_minutes", "extract_workers", "cloud_ocr_max_images"):
            assert name not in Settings.model_fields
        assert "max_inflight" not in json_schema()["properties"]["embedding"]["properties"]

    def test_cloud_ocr_settings_are_retired(self, tmp_path: Path, caplog) -> None:
        """The Claude OCR fallback is gone; a config that still configures it loads with warnings."""
        cfg = tmp_path / CONFIG_FILENAME
        cfg.write_text(
            json.dumps(
                {
                    "cloud": {"enable_ocr": True, "model": "some-model", "api_key_file": "~/.key", "max_images": 5},
                    "extraction": {"ocr_min_confidence": 55.0, "ocr_min_chars": 20},
                    "sources": [
                        {"slug": "notes", "root": "~/Documents", "allow_cloud_enrichment": True},
                        {"slug": "sms", "root": "~/sms", "class": "communication", "allow_cloud_enrichment": False},
                    ],
                }
            )
        )
        with caplog.at_level("WARNING", logger="garage_rag.config"):
            settings = load_config(cfg)
        assert settings.ocr_min_chars == 20
        assert [s.slug for s in settings.sources] == ["notes", "sms"]
        for key in ("cloud.enable_ocr", "cloud.model", "cloud.api_key_file", "extraction.ocr_min_confidence"):
            assert key in caplog.text, key
        assert "sources[].allow_cloud_enrichment" in caplog.text
        for name in ("enable_cloud_ocr", "cloud_ocr_model", "api_key_file", "ocr_min_confidence"):
            assert name not in Settings.model_fields
        assert "allow_cloud_enrichment" not in SourceSpec.model_fields
        schema = json_schema()
        assert "cloud" not in schema["properties"]
        # A retired section is not written back.
        assert "cloud" not in nest(settings)
        assert all("allow_cloud_enrichment" not in source for source in nest(settings)["sources"])

    def test_unknown_key_in_a_retired_section_is_still_an_error(self, tmp_path: Path) -> None:
        cfg = tmp_path / CONFIG_FILENAME
        cfg.write_text(json.dumps({"cloud": {"enable_ocr": True, "region": "us"}}))
        with pytest.raises(ConfigError, match="unknown key 'region'"):
            load_config(cfg)

    def test_retired_key_in_the_wrong_section_is_still_an_error(self, tmp_path: Path) -> None:
        cfg = tmp_path / CONFIG_FILENAME
        cfg.write_text(json.dumps({"database": {"workers": 3}}))
        with pytest.raises(ConfigError, match="unknown key 'workers'"):
            load_config(cfg)

    def test_sources_must_be_a_list(self, tmp_path: Path) -> None:
        cfg = tmp_path / CONFIG_FILENAME
        cfg.write_text(json.dumps({"sources": {"slug": "x"}}))
        with pytest.raises(ConfigError, match="must be a list"):
            load_config(cfg)


class TestLMStudioApiToken:
    def test_reads_token_from_environment(self, monkeypatch) -> None:
        monkeypatch.setenv("GARAGE_LMSTUDIO_API_TOKEN", "lm-token\n")
        assert Settings().read_lmstudio_api_token() == "lm-token"

    def test_environment_overrides_token_file(self, monkeypatch, tmp_path: Path) -> None:
        token_file = tmp_path / "lmstudio.token"
        token_file.write_text("from-file")
        monkeypatch.setenv("GARAGE_LMSTUDIO_API_TOKEN", "from-environment")
        assert Settings(lmstudio_api_token_file=str(token_file)).read_lmstudio_api_token() == "from-environment"

    def test_reads_token_from_file(self, tmp_path: Path) -> None:
        token_file = tmp_path / "lmstudio.token"
        token_file.write_text("lm-token\n")
        assert Settings(lmstudio_api_token_file=str(token_file)).read_lmstudio_api_token() == "lm-token"

    def test_rejects_empty_environment_token(self, monkeypatch) -> None:
        monkeypatch.setenv("GARAGE_LMSTUDIO_API_TOKEN", " ")
        with pytest.raises(ConfigError, match="GARAGE_LMSTUDIO_API_TOKEN must not be empty"):
            Settings().read_lmstudio_api_token()

    def test_rejects_missing_token_file(self, tmp_path: Path) -> None:
        with pytest.raises(ConfigError, match="cannot read LM Studio API token file"):
            Settings(lmstudio_api_token_file=str(tmp_path / "absent")).read_lmstudio_api_token()


class TestIdentityParsing:
    def test_pairs(self) -> None:
        settings = Settings(self_identities=["git_email:a@b.c", "handle:@me", "malformed"])
        assert settings.self_identity_pairs() == [
            ("git_email", "a@b.c"),
            ("handle", "@me"),
        ]

    def test_whitespace_tolerated(self) -> None:
        assert Settings(self_identities=[" email : a@b.c "]).self_identity_pairs() == [("email", "a@b.c")]


class TestSchema:
    def test_covers_every_section(self) -> None:
        properties = json_schema()["properties"]
        for section in SECTIONS:
            assert section in properties

    def test_forbids_unknown_keys(self) -> None:
        schema = json_schema()
        assert schema["additionalProperties"] is False
        for section in SECTIONS:
            assert schema["properties"][section]["additionalProperties"] is False

    def test_descriptions_present_where_documented(self) -> None:
        """The schema is where documentation lives, since JSON has no comments."""
        props = json_schema()["properties"]
        assert props["identity"]["properties"]["identities"]["description"]
        assert props["placeholders"]["properties"]["materialize"]["description"]

    def test_list_field_typed_as_array(self) -> None:
        """Regression: `annotation is list[str]` never matched, so this was untyped."""
        entry = json_schema()["properties"]["identity"]["properties"]["identities"]
        assert entry["type"] == "array"
        assert entry["items"] == {"type": "string"}

    def test_sources_schema_requires_slug_and_root(self) -> None:
        sources = json_schema()["properties"]["sources"]
        assert sources["items"]["required"] == ["slug", "root"]
        assert "class" in sources["items"]["properties"]


class TestDatabaseEnvironment:
    def test_database_url_environment_overrides_file(self, monkeypatch, tmp_path: Path) -> None:
        monkeypatch.setenv("GARAGE_CHUNK_SIZE", "7")
        monkeypatch.setenv("GARAGE_DATABASE_URL", "postgresql+psycopg:///app-managed")
        cfg = tmp_path / CONFIG_FILENAME
        cfg.write_text(json.dumps({"chunking": {"size": 123}}))
        settings = load_config(cfg)
        assert settings.chunk_size == 123
        assert settings.database_url == "postgresql+psycopg:///app-managed"

    def test_database_url_environment_normalizes_to_postgresql_psycopg(self, monkeypatch, tmp_path: Path) -> None:
        monkeypatch.setenv("GARAGE_DATABASE_URL", "postgresql://user:password@localhost:5432/garage-rag")
        settings = load_config()
        assert settings.database_url == "postgresql+psycopg://user:password@localhost:5432/garage-rag"

        monkeypatch.setenv("GARAGE_DATABASE_URL", "postgres://user:password@localhost:5432/garage-rag")
        settings = load_config()
        assert settings.database_url == "postgresql+psycopg://user:password@localhost:5432/garage-rag"

    def test_settings_normalizes_database_url(self) -> None:
        from garage_rag.config import ensure_psycopg_database_url

        assert ensure_psycopg_database_url("postgresql://user:pass@host/db") == "postgresql+psycopg://user:pass@host/db"
        assert ensure_psycopg_database_url("postgres://user:pass@host/db") == "postgresql+psycopg://user:pass@host/db"
        assert (
            ensure_psycopg_database_url("postgresql+psycopg://user:pass@host/db")
            == "postgresql+psycopg://user:pass@host/db"
        )

        settings = Settings(database_url="postgresql://user:pass@host/db")
        assert settings.database_url == "postgresql+psycopg://user:pass@host/db"

    def test_empty_database_url_environment_is_an_error(self, monkeypatch) -> None:
        monkeypatch.setenv("GARAGE_DATABASE_URL", " ")
        with pytest.raises(ConfigError, match="must not be empty"):
            load_config()


class TestSchemaCompleteness:
    def test_every_field_is_documented(self) -> None:
        """The schema is the only documentation, since JSON has no comments.

        An undocumented field is a setting nobody can discover the meaning of.
        """
        schema = json_schema()
        undocumented = [
            f"{section}.{key}"
            for section, body in schema["properties"].items()
            if body.get("type") == "object"
            for key, spec in body.get("properties", {}).items()
            if not spec.get("description")
        ]
        assert not undocumented, f"undocumented settings: {undocumented}"

    def test_every_source_field_is_documented(self) -> None:
        props = json_schema()["properties"]["sources"]["items"]["properties"]
        undocumented = [k for k, v in props.items() if not v.get("description")]
        assert not undocumented, f"undocumented source fields: {undocumented}"


class TestSchemaReference:
    def test_url_points_at_the_committed_schema(self) -> None:
        """The URL's path inside the repo must be exactly where the file is generated."""
        from garage_rag.config import repo_root, repo_schema_path

        # The site is built from docs/, so docs/.data/x is served as {SITE_URL}/.data/x.
        prefix = "https://garagerag.app/"
        assert SCHEMA_URL.startswith(prefix)
        assert SCHEMA_URL.removeprefix(prefix) == repo_schema_path().relative_to(repo_root() / "docs").as_posix()

    def test_nest_uses_the_url_by_default(self) -> None:
        assert nest(Settings())["$schema"] == SCHEMA_URL

    def test_committed_schema_matches_the_code(self) -> None:
        """The published URL must serve what this code actually accepts.

        If this fails, a setting was added or renamed without regenerating:
        run `garage config schema --publish` and commit the result.
        """
        from garage_rag.config import repo_schema_path

        path = repo_schema_path()
        assert path.is_file(), f"{path} is missing; run 'garage config schema --publish'"
        assert json.loads(path.read_text()) == json_schema()


class TestFactsSection:
    def test_defaults_point_at_the_app_engine(self) -> None:
        settings = Settings()
        assert settings.fact_model == "gemma2-2b"
        assert settings.fact_provider == "llama_xpc"

    def test_file_keys(self, tmp_path: Path) -> None:
        cfg = tmp_path / CONFIG_FILENAME
        cfg.write_text(json.dumps({"facts": {"model": "gemma2:2b", "provider": "ollama"}}))
        settings = load_config(cfg)
        assert settings.fact_model == "gemma2:2b"
        assert settings.fact_provider == "ollama"
        assert nest(settings)["facts"] == {"model": "gemma2:2b", "provider": "ollama"}

    def test_provider_is_restricted_to_local_backends(self, tmp_path: Path) -> None:
        cfg = tmp_path / CONFIG_FILENAME
        cfg.write_text(json.dumps({"facts": {"provider": "openai"}}))
        with pytest.raises(ConfigError, match="provider"):
            load_config(cfg)

    def test_schema_lists_the_provider_choices(self) -> None:
        entry = json_schema()["properties"]["facts"]["properties"]["provider"]
        assert entry["type"] == "string"
        assert entry["enum"] == ["llama_xpc", "ollama", "lmstudio"]
        assert entry["default"] == "llama_xpc"


PEOPLE_PROMPT = {
    "name": "people",
    "description": "List every person named.",
    "corpus_classes": ["document"],
    "examples": [
        {
            "text": "Jane met Bob.",
            "extractions": [
                {"class": "person", "text": "Jane"},
                {"class": "person", "text": "Bob", "attributes": {"role": "guest"}},
            ],
        }
    ],
}


class TestFactPrompts:
    def _load(self, tmp_path: Path, prompts: list) -> Settings:
        cfg = tmp_path / CONFIG_FILENAME
        cfg.write_text(json.dumps({"facts": {"prompts": prompts}}))
        return load_config(cfg)

    def test_with_nothing_configured_the_built_in_default_runs(self) -> None:
        from garage_rag.config.fact_prompts import DEFAULT_DESCRIPTION, effective_prompts

        (default,) = effective_prompts(Settings().fact_prompts)
        assert (default.name, default.enabled, default.builtin, default.customized) == ("default", True, True, False)
        assert default.description == DEFAULT_DESCRIPTION
        assert default.examples[0].extractions[0].extraction_class == "fact"

    def test_a_new_prompt_is_added_beside_the_default(self, tmp_path: Path) -> None:
        from garage_rag.config.fact_prompts import effective_prompts

        settings = self._load(tmp_path, [PEOPLE_PROMPT])
        prompts = effective_prompts(settings.fact_prompts)
        assert [(p.name, p.builtin) for p in prompts] == [("default", True), ("people", False)]
        people = prompts[1]
        assert people.corpus_classes == ("document",)
        assert people.examples[0].extractions[1].attributes == {"role": "guest"}
        assert people.applies_to("document", "notes") and not people.applies_to("communication", "notes")

    def test_an_entry_named_default_overrides_it_field_by_field(self, tmp_path: Path) -> None:
        from garage_rag.config.fact_prompts import effective_prompts

        builtin = effective_prompts([])[0]
        disabled = effective_prompts(self._load(tmp_path, [{"name": "default", "enabled": False}]).fact_prompts)[0]
        assert not disabled.enabled and disabled.customized
        # Only what the model sees is hashed, so turning it off does not make its facts stale.
        assert disabled.description == builtin.description and disabled.sha256 == builtin.sha256

        reworded = effective_prompts(self._load(tmp_path, [{"name": "default", "description": "Other."}]).fact_prompts)
        assert reworded[0].description == "Other." and reworded[0].examples == builtin.examples
        assert reworded[0].sha256 != builtin.sha256

    @pytest.mark.parametrize(
        ("prompts", "match"),
        [
            ([{"name": "x", "description": "d"}], "needs examples"),
            ([{"name": "x", "examples": PEOPLE_PROMPT["examples"]}], "needs description"),
            ([PEOPLE_PROMPT, PEOPLE_PROMPT], "used twice"),
            ([{**PEOPLE_PROMPT, "examples": []}], "must not be empty"),
            ([{**PEOPLE_PROMPT, "name": "has space"}], "pattern"),
            ([{**PEOPLE_PROMPT, "corpus_classes": ["mail"]}], "corpus_classes"),
            ([{**PEOPLE_PROMPT, "model": "gpt-4o"}], "model"),
            ([{**PEOPLE_PROMPT, "examples": [{"text": "t", "extractions": [{"text": "t", "kind": "k"}]}]}], "kind"),
        ],
    )
    def test_invalid_prompts_are_config_errors(self, tmp_path: Path, prompts: list, match: str) -> None:
        with pytest.raises(ConfigError, match=match):
            self._load(tmp_path, prompts)

    def test_select_prompts(self) -> None:
        from garage_rag.config.fact_prompts import FactPrompt, effective_prompts, select_prompts

        prompts = effective_prompts([FactPrompt(name="default", enabled=False), FactPrompt(**PEOPLE_PROMPT)])
        assert [p.name for p in select_prompts(prompts)] == ["people"]
        assert [p.name for p in select_prompts(prompts, ["default", "default"])] == ["default"]
        with pytest.raises(LookupError, match="nope"):
            select_prompts(prompts, ["nope"])

    def test_round_trips_through_the_file_and_empty_is_left_out(self, tmp_path: Path) -> None:
        settings = self._load(tmp_path, [PEOPLE_PROMPT])
        written = nest(settings)["facts"]["prompts"]
        assert written[0]["examples"][0]["extractions"][0] == {"class": "person", "text": "Jane", "attributes": {}}
        assert (
            "description"
            not in nest(self._load(tmp_path, [{"name": "default", "enabled": False}]))["facts"]["prompts"][0]
        )
        assert "prompts" not in nest(Settings())["facts"]

    def test_config_set_takes_a_json_array(self, tmp_path: Path) -> None:
        from garage_rag.config import update_config

        target = tmp_path / CONFIG_FILENAME
        settings, stored = update_config(target, "facts.prompts", json.dumps([PEOPLE_PROMPT]))
        assert [p.name for p in settings.fact_prompts] == ["people"]
        assert stored[0]["name"] == "people"
        json.dumps(stored)  # plain JSON, as GetSetting/SetSetting return it
        assert json.loads(target.read_text())["facts"]["prompts"][0]["description"] == "List every person named."
        with pytest.raises(ConfigError, match="JSON"):
            update_config(target, "facts.prompts", "people")

    def test_schema_describes_the_prompt_shape(self) -> None:
        schema = json_schema()
        entry = schema["properties"]["facts"]["properties"]["prompts"]
        assert entry["type"] == "array" and entry["default"] == []
        item = entry["items"]
        assert item["additionalProperties"] is False and item["required"] == ["name"]
        assert all(spec.get("description") for spec in item["properties"].values())
        for name in ("FactExample", "FactExtractionExample"):
            definition = schema["$defs"][name]
            assert definition["additionalProperties"] is False
            assert all(spec.get("description") for spec in definition["properties"].values()), name
        assert "class" in schema["$defs"]["FactExtractionExample"]["properties"]


class TestSetGetHelpers:
    def test_resolve_setting(self) -> None:
        from garage_rag.config import resolve_setting, setting_names

        assert resolve_setting("facts.model") == ("facts", "model", "fact_model")
        assert resolve_setting("embedding.default_model") == ("embedding", "default_model", "default_embedding_model")
        assert "facts.provider" in setting_names()

    @pytest.mark.parametrize("name", ["facts", "nope.model", "facts.nope", ""])
    def test_resolve_setting_rejects_unknown(self, name: str) -> None:
        from garage_rag.config import resolve_setting

        with pytest.raises(ConfigError, match="unknown|expected SECTION.KEY"):
            resolve_setting(name)

    @pytest.mark.parametrize(
        ("field", "raw", "expected"),
        [
            ("materialize_placeholders", "true", True),
            ("materialize_placeholders", "No", False),
            ("materialize_placeholders", "1", True),
            ("materialize_placeholders", "off", False),
            ("chunk_size", "512", 512),
            ("materialize_timeout_seconds", "42.5", 42.5),
            ("self_identities", "git_email:a@b.c, handle:@me", ["git_email:a@b.c", "handle:@me"]),
            ("self_identities", "", []),
            ("lmstudio_api_token_file", "none", None),
            ("lmstudio_api_token_file", "~/.key", "~/.key"),
            ("fact_model", "gemma2-2b", "gemma2-2b"),
        ],
    )
    def test_coerce_setting(self, field: str, raw: str, expected) -> None:
        from garage_rag.config import coerce_setting

        assert coerce_setting(field, raw) == expected

    @pytest.mark.parametrize(("field", "raw"), [("materialize_placeholders", "maybe"), ("chunk_size", "big")])
    def test_coerce_setting_rejects_garbage(self, field: str, raw: str) -> None:
        from garage_rag.config import coerce_setting

        with pytest.raises(ConfigError, match="expected"):
            coerce_setting(field, raw)

    def test_update_config_creates_the_file_from_defaults(self, tmp_path: Path) -> None:
        from garage_rag.config import update_config

        target = tmp_path / USER_CONFIG_FILENAME
        settings, stored = update_config(target, "facts.provider", "ollama")
        assert stored == "ollama"
        assert settings.fact_provider == "ollama"
        document = json.loads(target.read_text())
        assert document["$schema"] == SCHEMA_URL
        assert document["facts"] == {"model": "gemma2-2b", "provider": "ollama"}
        # Every other section is written at its default, as `config init` does.
        assert document["chunking"]["size"] == Settings().chunk_size

    def test_update_config_keeps_existing_values_and_ignores_the_environment(self, tmp_path: Path, monkeypatch) -> None:
        from garage_rag.config import update_config

        monkeypatch.setenv("GARAGE_DATABASE_URL", "postgresql+psycopg:///app-managed")
        target = tmp_path / CONFIG_FILENAME
        target.write_text(json.dumps({"chunking": {"size": 321}, "sources": [{"slug": "n", "root": "~/n"}]}))
        update_config(target, "facts.model", "phi-4-mini")
        document = json.loads(target.read_text())
        assert document["chunking"]["size"] == 321
        assert document["facts"]["model"] == "phi-4-mini"
        assert [s["slug"] for s in document["sources"]] == ["n"]
        # The env override is applied at load time, never persisted by `set`.
        assert document["database"]["url"] == Settings().database_url

    def test_update_config_validates_before_writing(self, tmp_path: Path) -> None:
        from garage_rag.config import update_config

        target = tmp_path / CONFIG_FILENAME
        with pytest.raises(ConfigError, match="facts.provider"):
            update_config(target, "facts.provider", "openai")
        assert not target.exists()
