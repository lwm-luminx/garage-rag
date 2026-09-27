"""Image embedding models: the ``image`` modality, its chunks, and the ``image_xpc`` provider.

An image model (an ``image_embedding`` catalog entry, served by the app's
GarageImageEmbedXPCService) embeds the one ``image`` chunk each picture gets,
from the file itself, while text models skip those chunks. Python reaches the
service through the two C functions the Swift host installs in
:mod:`garage_rag.xpc.image_host`; here they are Python callables with the same
signatures.
"""

from __future__ import annotations

import ctypes
import json
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

from garage_rag.config import Settings, repo_root, reset_settings, set_settings
from garage_rag.db.catalog import MANIFEST_ENV, known_models
from garage_rag.db.emb_tables import resolve_spec
from garage_rag.db.registry import check_modality
from garage_rag.embed.base import EmbeddingError, ImageEmbedder
from garage_rag.embed.factory import PROVIDERS, get_embedder, provider_is_local
from garage_rag.embed.image_xpc import ImageXPCEmbedder
from garage_rag.embed.ollama import IMAGE_CHUNKER, PENDING_SELECT, backfill_model, model_modality, pending_chunks_sql
from garage_rag.extract.base import ContentKind
from garage_rag.ingest.chunking import chunk_text, image_chunk
from garage_rag.proto.garage_pb2 import GetEmbeddingBatchesRequest
from garage_rag.service.server import GarageRpcServicer
from garage_rag.xpc import image_host

MODELS_JSON = repo_root() / "docs" / ".data" / "models.json"
HEX = set("0123456789abcdef")


@pytest.fixture(autouse=True)
def _fresh_settings():
    set_settings(Settings())
    yield
    reset_settings()


@pytest.fixture
def fake_bridge():
    """Installs describe/embed callables with the C functions' signatures; yields the calls seen."""
    calls: list[dict] = []

    def describe(model_ref: bytes, buffer, capacity: int) -> int:
        calls.append({"describe": model_ref.decode()})
        if model_ref == b"missing":
            ctypes.memmove(buffer, b"no such model\0", 14)
            return 1
        payload = json.dumps({"dims": 3, "image_size": 256, "text_length": 64}).encode() + b"\0"
        ctypes.memmove(buffer, payload, len(payload))
        return 0

    def embed(request: bytes, blobs, sizes, count: int, out, out_capacity: int, message, capacity: int) -> int:
        body = json.loads(request)
        images = [ctypes.string_at(blobs[i], sizes[i]) for i in range(count)]
        calls.append({"embed": body, "images": images})
        n = len(body.get("texts", [])) or body.get("images", 0)
        for i in range(n):
            for j in range(3):
                out[i * 3 + j] = float(i * 10 + j)
        return 0

    image_host.set_image_embedder(describe, embed)
    yield calls
    image_host.set_image_embedder(None, None)


class TestImageHost:
    def test_no_bridge_says_where_image_models_work(self) -> None:
        image_host.set_image_embedder(None, None)
        assert not image_host.has_image_embedder()
        with pytest.raises(image_host.ImageEmbedUnavailable, match="inside the Garage app"):
            image_host.embed_texts("siglip2-base-256", ["a cat"])

    def test_describe_parses_the_service_reply(self, fake_bridge) -> None:
        assert image_host.has_image_embedder()
        info = image_host.describe("siglip2-base-256")
        assert (info.dims, info.image_size, info.text_length) == (3, 256, 64)

    def test_describe_failure_carries_the_reason(self, fake_bridge) -> None:
        with pytest.raises(image_host.ImageEmbedUnavailable, match="no such model"):
            image_host.describe("missing")

    def test_texts_go_as_json_and_come_back_as_vectors(self, fake_bridge) -> None:
        vectors = image_host.embed_texts("siglip2-base-256", ["a cat", "a dog"])
        assert vectors == [[0.0, 1.0, 2.0], [10.0, 11.0, 12.0]]
        request = fake_bridge[-1]["embed"]
        assert request == {"model": "siglip2-base-256", "texts": ["a cat", "a dog"]}
        assert fake_bridge[-1]["images"] == []

    def test_images_go_as_raw_blobs(self, fake_bridge) -> None:
        vectors = image_host.embed_images("siglip2-base-256", [b"\x89PNG one", b"\xff\xd8 two"])
        assert len(vectors) == 2
        assert fake_bridge[-1]["embed"] == {"model": "siglip2-base-256", "images": 2}
        assert fake_bridge[-1]["images"] == [b"\x89PNG one", b"\xff\xd8 two"]

    def test_empty_batches_never_cross_the_bridge(self, fake_bridge) -> None:
        assert image_host.embed_texts("siglip2-base-256", []) == []
        assert image_host.embed_images("siglip2-base-256", []) == []
        assert fake_bridge == []

    def test_install_rejects_null_addresses(self) -> None:
        with pytest.raises(ValueError):
            image_host.install_image_embedder(0, 0)


class TestImageXPCProvider:
    def test_is_a_known_local_provider(self) -> None:
        assert "image_xpc" in PROVIDERS
        assert provider_is_local("image_xpc")
        embedder = get_embedder("image_xpc", "siglip2-base-256")
        assert isinstance(embedder, ImageXPCEmbedder)
        assert isinstance(embedder, ImageEmbedder)

    def test_embeds_files_by_path(self, fake_bridge, tmp_path: Path) -> None:
        picture = tmp_path / "cat.png"
        picture.write_bytes(b"\x89PNG fake")
        vectors = ImageXPCEmbedder("siglip2-base-256").embed_images([str(picture)])
        assert vectors == [[0.0, 1.0, 2.0]]
        assert fake_bridge[-1]["images"] == [b"\x89PNG fake"]

    def test_missing_file_is_an_embedding_error(self, fake_bridge, tmp_path: Path) -> None:
        with pytest.raises(EmbeddingError):
            ImageXPCEmbedder("siglip2-base-256").embed_images([str(tmp_path / "gone.png")])

    def test_without_the_bridge_text_queries_fail_clearly(self) -> None:
        image_host.set_image_embedder(None, None)
        with pytest.raises(EmbeddingError, match="inside the Garage app"):
            ImageXPCEmbedder("siglip2-base-256").embed(["a cat"])


class TestModality:
    def test_only_text_and_image(self) -> None:
        assert check_modality("text") == "text"
        assert check_modality("image") == "image"
        with pytest.raises(ValueError):
            check_modality("audio")

    def test_rows_from_before_the_column_read_as_text(self) -> None:
        model = MagicMock(spec=["slug"])
        assert model_modality(model) == "text"
        model = MagicMock()
        model.modality = "image"
        assert model_modality(model) == "image"


class TestPendingChunks:
    def test_text_models_skip_image_chunks(self) -> None:
        sql = pending_chunks_sql("emb_m", select=PENDING_SELECT["text"], include_communications=True)
        assert f"c.chunker <> '{IMAGE_CHUNKER}'" in sql
        assert "d.uri" not in sql

    def test_image_models_get_only_image_chunks_with_their_files(self) -> None:
        sql = pending_chunks_sql("emb_i", select=PENDING_SELECT["image"], include_communications=True, modality="image")
        assert f"c.chunker = '{IMAGE_CHUNKER}'" in sql
        assert "JOIN documents d ON d.id = c.document_id" in sql
        assert "d.uri" in sql
        assert "communication" not in sql

    def test_image_models_off_box_withhold_communications(self) -> None:
        sql = pending_chunks_sql("emb_i", select="count(*)", include_communications=False, modality="image")
        assert "d.corpus_class <> 'communication'" in sql


def _image_model(provider: str = "image_xpc") -> MagicMock:
    model = MagicMock()
    model.slug = "siglip2-base-256"
    model.provider = provider
    model.model_ref = "siglip2-base-256"
    model.table_name = "emb_siglip2_base_256"
    model.dims = 3
    model.stored_dims = 3
    model.storage_kind = "vector"
    model.index_kind = "hnsw"
    model.modality = "image"
    return model


class TestBackfill:
    def test_image_model_embeds_the_files(self, fake_bridge, tmp_path: Path) -> None:
        picture = tmp_path / "cat.png"
        picture.write_bytes(b"\x89PNG fake")
        batches = MagicMock(return_value=iter([[(7, str(picture))]]))
        session = MagicMock()
        with (
            patch("garage_rag.embed.ollama.count_pending", return_value=1),
            patch("garage_rag.embed.ollama._pending_chunk_batches", batches),
        ):
            state = backfill_model(session, _image_model())
        assert state.embedded == 1
        assert state.failed == 0
        assert batches.call_args.kwargs["modality"] == "image"
        assert fake_bridge[-1]["images"] == [b"\x89PNG fake"]

    def test_image_model_on_a_text_provider_is_refused(self) -> None:
        with pytest.raises(EmbeddingError, match="embeds text only"):
            backfill_model(MagicMock(), _image_model(provider="llama_xpc"))


class TestEmbedWorkerBatches:
    def test_image_model_batches_carry_paths_and_the_modality(self) -> None:
        session = MagicMock()
        session.execute.return_value.all.return_value = [(7, "/photos/cat.png")]
        with (
            patch("garage_rag.db.engine.session_scope") as scope,
            patch("garage_rag.db.emb_tables.get_model", return_value=_image_model()),
            patch("garage_rag.embed.ollama.count_pending", return_value=1),
        ):
            scope.return_value.__enter__.return_value = session
            response = GarageRpcServicer().GetEmbeddingBatches(
                GetEmbeddingBatchesRequest(model_slug="siglip2-base-256"), MagicMock()
            )
        sql = str(session.execute.call_args.args[0])
        assert "d.uri" in sql and f"c.chunker = '{IMAGE_CHUNKER}'" in sql
        assert response.modality == "image"
        assert [(c.chunk_id, c.text) for c in response.chunks] == [(7, "/photos/cat.png")]


class TestImageChunks:
    def test_a_picture_is_one_image_chunk(self) -> None:
        chunks = chunk_text("Holiday 2024", ContentKind.IMAGE)
        assert len(chunks) == 1
        assert chunks[0].chunker == IMAGE_CHUNKER
        assert chunks[0].text == "Holiday 2024"

    def test_image_chunk_takes_its_ordinal(self) -> None:
        chunk = image_chunk("caption", ord=3)
        assert (chunk.ord, chunk.chunker, chunk.char_end) == (3, IMAGE_CHUNKER, len("caption"))


class TestCatalog:
    def test_image_entries_resolve_to_the_image_provider(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.delenv(MANIFEST_ENV, raising=False)
        spec = known_models()["siglip2-base-256"]
        assert spec.modality == "image"
        assert spec.provider == "image_xpc"
        assert spec.dims == 768
        resolved = resolve_spec("siglip2-base-256")
        assert resolved.modality == "image"
        assert resolved.distance == "cosine"

    def test_text_entries_stay_text(self, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.delenv(MANIFEST_ENV, raising=False)
        assert known_models()["bge-m3"].modality == "text"

    def test_every_image_entry_downloads_its_files_with_checksums(self) -> None:
        document = json.loads(MODELS_JSON.read_text())
        for entry in document["image_embedding"]:
            assert entry.get("provider") == "image_xpc", entry["slug"]
            assert entry.get("modality") == "image", entry["slug"]
            assert entry.get("distance") == "cosine", entry["slug"]
            assert entry.get("download_model_id"), entry["slug"]
            for key in ("image_model", "text_model", "tokenizer", "image_size", "text_length"):
                assert entry.get(key), f"{entry['slug']} needs {key}"
            files = entry.get("download_files") or []
            paths = {f["path"] for f in files}
            assert entry["tokenizer"] in paths, entry["slug"]
            for package in (entry["image_model"], entry["text_model"]):
                assert f"{package}/Manifest.json" in paths, entry["slug"]
                assert f"{package}/Data/com.apple.CoreML/model.mlmodel" in paths, entry["slug"]
                assert f"{package}/Data/com.apple.CoreML/weights/weight.bin" in paths, entry["slug"]
            for file in files:
                assert not file["path"].startswith("/") and ".." not in file["path"].split("/"), file["path"]
                sha = file.get("sha256")
                # Manifest.json is a small JSON file whose formatting the app does not pin.
                if file["path"].endswith("Manifest.json"):
                    continue
                assert sha and len(sha) == 64 and set(sha) <= HEX, f"{entry['slug']}: {file['path']}"
