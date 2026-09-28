"""models.json is the embedding-model catalog, and it chooses each model's distance.

The metric a model was trained for has to agree in three places: the HNSW
operator class its table is indexed with, the operator search orders by, and
the model itself. models.json declares it once; registration and search follow.
"""

from __future__ import annotations

import json
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pytest

from garage_rag.config import repo_root
from garage_rag.db.catalog import MANIFEST_ENV, known_models, manifest_path
from garage_rag.db.emb_tables import resolve_spec
from garage_rag.db.registry import DISTANCES, check_distance, distance_operator, index_ddl, plan_storage

MODELS_JSON = repo_root() / "data" / "models" / "models.json"


@pytest.fixture
def manifest(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    """Point the catalog at a models.json written by the test."""

    def write(*entries: dict) -> Path:
        path = tmp_path / f"models-{len(list(tmp_path.iterdir()))}.json"
        path.write_text(json.dumps({"text_embedding": list(entries), "inference_models": []}))
        monkeypatch.setenv(MANIFEST_ENV, str(path))
        return path

    return write


class TestTheCommittedCatalog:
    def test_repo_catalog_is_the_one_in_use(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.delenv(MANIFEST_ENV, raising=False)
        assert manifest_path() == MODELS_JSON

    def test_every_embedding_entry_declares_a_known_distance(self) -> None:
        document = json.loads(MODELS_JSON.read_text())
        for entry in document["text_embedding"]:
            if entry.get("native_dims"):
                assert entry.get("distance") in DISTANCES, f"{entry['slug']} must declare its distance"

    def test_generative_entries_are_not_embedding_models(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.delenv(MANIFEST_ENV, raising=False)
        models = known_models()
        assert "bge-m3" in models
        assert "mistral-7b-instruct-v0.3" not in models  # listed without native_dims

    def test_slugs_are_unique_across_the_catalog(self) -> None:
        document = json.loads(MODELS_JSON.read_text())
        sections = ("text_embedding", "inference_models", "image_embedding")
        slugs = [entry["slug"] for section in sections for entry in document[section]]
        assert len(slugs) == len(set(slugs))

    def test_every_inference_model_downloads_with_a_checksum(self) -> None:
        # The app downloads huggingface.co/<download_model_id>/resolve/main/<download_file> and
        # checks it against sha256, so an inference entry needs all three.
        document = json.loads(MODELS_JSON.read_text())
        for entry in document["inference_models"]:
            assert entry.get("download_model_id") and entry.get("download_file"), entry["slug"]
            assert entry["download_file"].endswith(".gguf"), entry["slug"]
            sha = entry.get("sha256", "")
            assert len(sha) == 64 and all(c in "0123456789abcdef" for c in sha), entry["slug"]
            assert not entry.get("native_dims"), f"{entry['slug']} is generative, not an embedding model"

    def test_inference_models_say_what_they_are_for(self) -> None:
        # One list for chat and distillation: tags say which each model is good for.
        document = json.loads(MODELS_JSON.read_text())
        assert "fact_distil" not in document
        for entry in document["inference_models"]:
            tags = entry.get("tags") or []
            assert tags and set(tags) <= {"inference", "distillation"}, entry["slug"]
        assert all(not entry.get("tags") for entry in document["text_embedding"])

    def test_origin_zone_agrees_with_the_country(self) -> None:
        # The zone the selection prompt groups by is stored, not derived, so hold it to the country.
        eu = {
            "AT",
            "BE",
            "BG",
            "HR",
            "CY",
            "CZ",
            "DK",
            "EE",
            "FI",
            "FR",
            "DE",
            "GR",
            "HU",
            "IE",
            "IT",
            "LV",
            "LT",
            "LU",
            "MT",
            "NL",
            "PL",
            "PT",
            "RO",
            "SK",
            "SI",
            "ES",
            "SE",
        }
        by_country = {"US": "US", "CN": "CN", "GB": "UK", "CH": "CH"}
        document = json.loads(MODELS_JSON.read_text())
        for entry in document["text_embedding"] + document["inference_models"]:
            country = entry.get("country_of_origin", "")
            expected = "EU" if country in eu else by_country.get(country, "OTHER")
            assert entry.get("origin_zone") == expected, entry["slug"]

    def test_every_entry_names_its_origin(self) -> None:
        # An ISO 3166-1 alpha-2 code, not a region: the app groups codes into US / EU / CN / other.
        document = json.loads(MODELS_JSON.read_text())
        for entry in document["text_embedding"] + document["inference_models"]:
            assert "origin" not in entry, entry["slug"]
            assert entry.get("maker"), entry["slug"]
            country = entry.get("country_of_origin", "")
            assert len(country) == 2 and country.isascii() and country.isupper(), entry["slug"]
            assert isinstance(entry.get("tool_calling", False), bool), entry["slug"]

    def test_qwen3_keeps_its_ollama_tag(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.delenv(MANIFEST_ENV, raising=False)
        assert resolve_spec("qwen3-embedding-0.6b").model_ref == "qwen3-embedding-0.6b"
        assert resolve_spec("qwen3-embedding-0.6b", provider="ollama").model_ref == "qwen3-embedding:0.6b"


class TestResolveSpec:
    def test_distance_comes_from_models_json(self, manifest) -> None:
        manifest({"slug": "e5", "model_ref": "e5", "native_dims": 768, "distance": "inner_product"})
        spec = resolve_spec("e5")
        assert spec.distance == "inner_product"
        assert spec.dims == 768

    def test_explicit_distance_overrides_the_catalog(self, manifest) -> None:
        manifest({"slug": "e5", "model_ref": "e5", "native_dims": 768, "distance": "inner_product"})
        assert resolve_spec("e5", distance="l2").distance == "l2"

    def test_uncatalogued_model_defaults_to_cosine(self, manifest) -> None:
        manifest()
        assert resolve_spec("custom", dims=512).distance == "cosine"
        assert resolve_spec("custom", dims=512, distance="l2").distance == "l2"

    def test_uncatalogued_model_needs_dims(self, manifest) -> None:
        manifest()
        with pytest.raises(ValueError, match="not in models.json"):
            resolve_spec("custom")

    def test_unknown_distance_is_rejected(self, manifest) -> None:
        manifest()
        with pytest.raises(ValueError, match="unknown distance"):
            resolve_spec("custom", dims=512, distance="manhattan")
        with pytest.raises(ValueError, match="unknown distance"):
            check_distance("dot")

    def test_catalog_with_a_bad_distance_is_refused(self, manifest) -> None:
        manifest({"slug": "odd", "native_dims": 8, "distance": "hamming"})
        with pytest.raises(ValueError, match="unknown distance"):
            known_models()


class TestIndexAndSearchAgree:
    @pytest.mark.parametrize(
        ("distance", "vector_ops", "halfvec_ops", "operator"),
        [
            ("cosine", "vector_cosine_ops", "halfvec_cosine_ops", "<=>"),
            ("l2", "vector_l2_ops", "halfvec_l2_ops", "<->"),
            ("inner_product", "vector_ip_ops", "halfvec_ip_ops", "<#>"),
        ],
    )
    def test_operator_class_and_operator_match(
        self, distance: str, vector_ops: str, halfvec_ops: str, operator: str
    ) -> None:
        assert f"(embedding {vector_ops})" in index_ddl("emb_m", plan_storage(1024), distance)
        assert f"(embedding {halfvec_ops})" in index_ddl("emb_m", plan_storage(2560), distance)
        assert distance_operator(distance) == operator

    def test_binary_quantized_index_is_hamming_whatever_the_metric(self) -> None:
        ddl = index_ddl("emb_m", plan_storage(4096), "inner_product")
        assert "bit_hamming_ops" in ddl

    @pytest.mark.parametrize(("distance", "operator"), [("cosine", "<=>"), ("l2", "<->"), ("inner_product", "<#>")])
    def test_search_orders_by_the_models_operator(self, distance: str, operator: str) -> None:
        from garage_rag.search import hybrid

        model = SimpleNamespace(
            slug="m",
            dims=768,
            stored_dims=768,
            storage_kind="vector",
            index_kind="hnsw",
            distance=distance,
            provider="llama_xpc",
            model_ref="m",
            table_name="emb_m",
        )
        session = MagicMock()
        session.execute.return_value.mappings.return_value.all.return_value = []
        embedder = MagicMock()
        embedder.embed.return_value = [[0.1] * 768]
        with (
            patch.object(hybrid, "apply_search_tuning"),
            patch.object(hybrid, "get_model", return_value=model),
            patch.object(hybrid, "get_embedder", return_value=embedder),
        ):
            hybrid.search(session, "query", mode="vector")
        sql = session.execute.call_args.args[0].text
        assert f"ORDER BY e.embedding {operator} :qv" in sql
        for other in {"<=>", "<->", "<#>"} - {operator}:
            assert other not in sql


def test_migration_adds_the_distance_column() -> None:
    ddl = (repo_root() / "data" / "sql" / "009_model_distance.sql").read_text()
    assert "ADD COLUMN IF NOT EXISTS distance text NOT NULL DEFAULT 'cosine'" in ddl
    assert "'cosine', 'l2', 'inner_product'" in ddl
