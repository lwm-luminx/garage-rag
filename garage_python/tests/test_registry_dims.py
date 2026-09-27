"""The dimension -> storage mapping.

These are the rules that keep an unindexable model from being registered as
indexed. pgvector's HNSW ceilings are 2000 dims for `vector` and 4000 for
`halfvec`; getting this wrong surfaces as a CREATE INDEX failure thousands of
documents into an ingest, so it is tested directly and without a database.
"""

from __future__ import annotations

import math
from types import SimpleNamespace
from unittest.mock import MagicMock, patch

import pytest
from pgvector import HalfVector
from pgvector.sqlalchemy import HALFVEC, VECTOR

from garage_rag.config import Settings
from garage_rag.db.catalog import known_models
from garage_rag.db.emb_tables import get_model
from garage_rag.db.registry import (
    HNSW_MAX_HALFVEC_DIMS,
    HNSW_MAX_VECTOR_DIMS,
    column_type_sql,
    index_ddl,
    plan_storage,
    table_name_for,
    truncate_vector,
)


class TestPlanStorage:
    @pytest.mark.parametrize("dims", [64, 384, 768, 1024, 1536, 2000])
    def test_narrow_models_use_indexed_vector(self, dims: int) -> None:
        plan = plan_storage(dims)
        assert plan.storage_kind == "vector"
        assert plan.index_kind == "hnsw"
        assert plan.stored_dims == dims
        assert not plan.is_truncated

    @pytest.mark.parametrize("dims", [2001, 2560, 3072, 4000])
    def test_mid_width_models_use_halfvec(self, dims: int) -> None:
        """Above vector's 2000 ceiling, halfvec's 4000 ceiling still covers it."""
        plan = plan_storage(dims)
        assert plan.storage_kind == "halfvec"
        assert plan.index_kind == "hnsw"
        assert plan.stored_dims == dims
        assert not plan.is_truncated

    def test_mrl_model_above_ceiling_is_truncated_not_quantized(self) -> None:
        """Qwen3-8B at 4096 exceeds every HNSW ceiling; MRL makes truncation safe."""
        plan = plan_storage(4096, supports_mrl=True)
        assert plan.storage_kind == "halfvec"
        assert plan.index_kind == "hnsw"
        assert plan.stored_dims == HNSW_MAX_HALFVEC_DIMS
        assert plan.truncated_from == 4096

    def test_non_mrl_model_above_ceiling_falls_back_to_quantization(self) -> None:
        """Truncating a non-MRL model destroys quality, so quantize instead."""
        plan = plan_storage(4096, supports_mrl=False)
        assert plan.storage_kind == "vector"
        assert plan.index_kind == "hnsw_bq"
        assert plan.stored_dims == 4096
        assert not plan.is_truncated

    @pytest.mark.parametrize("dims", [0, -1])
    def test_rejects_nonpositive_dims(self, dims: int) -> None:
        with pytest.raises(ValueError):
            plan_storage(dims)

    def test_indexed_plans_never_exceed_pgvector_ceilings(self) -> None:
        """The invariant the whole module exists to maintain."""
        for dims in (1, 768, 2000, 2001, 4000, 4096, 8192, 16000):
            for mrl in (True, False):
                plan = plan_storage(dims, supports_mrl=mrl)
                if plan.index_kind != "hnsw":
                    continue
                ceiling = HNSW_MAX_VECTOR_DIMS if plan.storage_kind == "vector" else HNSW_MAX_HALFVEC_DIMS
                assert plan.stored_dims <= ceiling, (
                    f"{dims=} mrl={mrl} produced an unindexable {plan.storage_kind}({plan.stored_dims})"
                )


class TestDDLGeneration:
    def test_column_type(self) -> None:
        assert column_type_sql(plan_storage(1024)) == "vector(1024)"
        assert column_type_sql(plan_storage(2560)) == "halfvec(2560)"

    def test_hnsw_index_uses_matching_ops_class(self) -> None:
        ddl_a = index_ddl("emb_a", plan_storage(1024))
        assert ddl_a is not None and "vector_cosine_ops" in ddl_a
        ddl_b = index_ddl("emb_b", plan_storage(2560))
        assert ddl_b is not None and "halfvec_cosine_ops" in ddl_b

    def test_quantized_index_uses_hamming_ops(self) -> None:
        ddl = index_ddl("emb_c", plan_storage(4096, supports_mrl=False))
        assert ddl is not None
        assert "binary_quantize" in ddl
        assert "bit_hamming_ops" in ddl


class TestTableNaming:
    @pytest.mark.parametrize(
        ("slug", "expected"),
        [
            ("bge-m3", "emb_bge_m3"),
            ("nomic-embed-text", "emb_nomic_embed_text"),
            ("qwen3-embedding-0.6b", "emb_qwen3_embedding_0_6b"),
            ("Mixed.Case-Name", "emb_mixed_case_name"),
        ],
    )
    def test_slug_normalization(self, slug: str, expected: str) -> None:
        assert table_name_for(slug) == expected

    def test_result_matches_schema_check_constraint(self) -> None:
        """data/sql/004_registry.sql enforces ^emb_[a-z0-9_]+$."""
        import re

        pattern = re.compile(r"^emb_[a-z0-9_]+$")
        for slug in [*known_models(), "weird!!name", "UPPER", "dots.and-dashes"]:
            assert pattern.match(table_name_for(slug)), slug

    def test_respects_postgres_identifier_limit(self) -> None:
        assert len(table_name_for("x" * 200)) <= 63

    @pytest.mark.parametrize("slug", ["", "---", "!!!"])
    def test_rejects_slugs_with_no_usable_characters(self, slug: str) -> None:
        with pytest.raises(ValueError):
            table_name_for(slug)


class TestTruncation:
    def test_untruncated_plan_passes_values_through(self) -> None:
        values = [0.1, 0.2, 0.3]
        assert truncate_vector(values, plan_storage(3)) == values

    def test_truncation_renormalizes(self) -> None:
        """A prefix of a unit vector is not unit length, and pgvector's cosine
        distance does not normalize for you."""
        plan = plan_storage(4096, supports_mrl=True)
        raw = [1.0] * 4096
        out = truncate_vector(raw, plan)
        assert len(out) == HNSW_MAX_HALFVEC_DIMS
        assert math.isclose(math.sqrt(sum(v * v for v in out)), 1.0, rel_tol=1e-9)

    def test_rejects_short_vectors(self) -> None:
        with pytest.raises(ValueError, match="expected at least"):
            truncate_vector([1.0, 2.0], plan_storage(4096, supports_mrl=True))

    def test_all_zero_vector_does_not_divide_by_zero(self) -> None:
        plan = plan_storage(4096, supports_mrl=True)
        out = truncate_vector([0.0] * 4096, plan)
        assert out == [0.0] * HNSW_MAX_HALFVEC_DIMS


class TestKnownModels:
    def test_every_known_model_is_registrable(self) -> None:
        for slug, spec in known_models().items():
            assert spec.slug == slug
            plan = plan_storage(spec.dims, supports_mrl=spec.supports_mrl)
            assert plan.stored_dims > 0
            assert table_name_for(slug).startswith("emb_")

    def test_qwen3_family_declares_mrl(self) -> None:
        """Truncation is only sound for MRL-trained models, so the flag matters."""
        for slug, spec in known_models().items():
            if slug.startswith("qwen3-embedding"):
                assert spec.supports_mrl, f"{slug} must declare MRL support"

    def test_pulled_models_have_expected_widths(self) -> None:
        assert known_models()["bge-m3"].dims == 1024
        assert known_models()["nomic-embed-text"].dims == 768
        assert known_models()["mxbai-embed-xsmall"].dims == 384

    def test_known_models_default_provider_is_the_built_in_engine(self) -> None:
        # Text models run in LlamaXPCService, image models in GarageImageEmbedXPCService.
        for slug, spec in known_models().items():
            expected = "image_xpc" if spec.modality == "image" else "llama_xpc"
            assert spec.provider == expected, f"{slug} must default to the {expected} provider"

    def test_known_models_have_model_id(self) -> None:
        for _slug, spec in known_models().items():
            assert spec.model_id is not None
            assert "/" in spec.model_id


# ---------------------------------------------------------------------------
# The storage plan at query time: the bind parameter must match the column
# ---------------------------------------------------------------------------
def _model_row(
    *,
    dims: int,
    stored_dims: int,
    storage_kind: str,
    slug: str = "m",
    index_kind: str = "hnsw",
    distance: str = "cosine",
) -> SimpleNamespace:
    return SimpleNamespace(
        slug=slug,
        dims=dims,
        stored_dims=stored_dims,
        storage_kind=storage_kind,
        index_kind=index_kind,
        distance=distance,
        provider="ollama",
        model_ref=slug,
        table_name=f"emb_{slug}",
        is_default=True,
    )


class TestSearchBindType:
    def _run(self, row: SimpleNamespace | None, *, mode: str) -> tuple[MagicMock, MagicMock]:
        from garage_rag.search import hybrid

        session = MagicMock()
        session.execute.return_value.mappings.return_value.all.return_value = []
        embedder = MagicMock()
        embedder.embed.return_value = [[0.5] * (row.dims if row else 1)]
        get_model = MagicMock(return_value=row) if row is not None else MagicMock(side_effect=LookupError("none"))
        with (
            patch.object(hybrid, "apply_search_tuning"),
            patch.object(hybrid, "get_model", get_model),
            patch.object(hybrid, "get_embedder", return_value=embedder),
        ):
            hybrid.search(session, "secure boot", mode=mode)
        return session, get_model

    def test_halfvec_model_binds_a_halfvec_parameter(self) -> None:
        """A HalfVector bound as VECTOR is rejected by pgvector, so every
        search on a 2001-4000 dim (or MRL-truncated) model would fail."""
        session, _ = self._run(_model_row(dims=2560, stored_dims=2560, storage_kind="halfvec"), mode="vector")
        statement, params = session.execute.call_args.args
        assert isinstance(statement._bindparams["qv"].type, HALFVEC)
        assert isinstance(params["qv"], HalfVector)

    def test_truncated_mrl_model_binds_a_halfvec_of_the_stored_width(self) -> None:
        session, _ = self._run(_model_row(dims=4096, stored_dims=4000, storage_kind="halfvec"), mode="hybrid")
        statement, params = session.execute.call_args.args
        assert isinstance(statement._bindparams["qv"].type, HALFVEC)
        assert len(params["qv"].to_list()) == 4000

    def test_vector_model_binds_a_vector_parameter(self) -> None:
        session, _ = self._run(_model_row(dims=1024, stored_dims=1024, storage_kind="vector"), mode="hybrid")
        statement, params = session.execute.call_args.args
        assert isinstance(statement._bindparams["qv"].type, VECTOR)
        assert not isinstance(params["qv"], HalfVector)

    def test_binary_quantized_model_reranks_a_hamming_prefetch(self) -> None:
        """hnsw_bq: the index is on binary_quantize(embedding)::bit(d), so the query
        must order by that exact expression, then re-rank on exact cosine."""
        from garage_rag.search.hybrid import BQ_OVERFETCH, CANDIDATE_DEPTH

        row = _model_row(dims=4096, stored_dims=4096, storage_kind="vector", index_kind="hnsw_bq")
        session, _ = self._run(row, mode="hybrid")
        statement, params = session.execute.call_args.args
        sql = statement.text
        assert "ORDER BY binary_quantize(e.embedding)::bit(4096)" in sql
        # Cast: binary_quantize() is overloaded for vector and halfvec, and the
        # bound query vector arrives untyped (test_postgres runs this for real).
        assert "<~> binary_quantize(CAST(:qv AS vector(4096)))::bit(4096)" in sql
        assert "LIMIT :bq_depth" in sql
        assert params["bq_depth"] == CANDIDATE_DEPTH * BQ_OVERFETCH
        # Stage two orders the prefetched rows on exact cosine.
        assert "ORDER BY b.embedding <=> :qv" in sql
        # Filters apply during the index scan, not after the prefetch.
        prefetch = sql[sql.index("vec_bq AS") : sql.index("vec AS")]
        assert "WHERE" in prefetch

    def test_hnsw_model_orders_on_cosine_directly(self) -> None:
        session, _ = self._run(_model_row(dims=1024, stored_dims=1024, storage_kind="vector"), mode="vector")
        statement, params = session.execute.call_args.args
        assert "binary_quantize" not in statement.text
        assert "bq_depth" not in params

    def test_fts_mode_needs_no_model(self) -> None:
        """Keyword search must work on a corpus with no embedding model registered."""
        session, get_model = self._run(None, mode="fts")
        get_model.assert_not_called()
        statement, params = session.execute.call_args.args
        assert "qv" not in params
        assert "fts AS" in statement.text and "vec AS" not in statement.text
        # The keyword CTE keeps its best-ranked rows when it is truncated.
        assert "ORDER BY rnk" in statement.text


class TestDefaultModelFallback:
    """``embedding.default_model`` is honoured when no row is flagged as default."""

    def _session(self, rows: dict[str, SimpleNamespace], default: str | None) -> MagicMock:
        def filter_by(**kw):
            found = MagicMock()
            if "slug" in kw:
                found.one_or_none.return_value = rows.get(kw["slug"])
            else:  # is_default=True
                found.one_or_none.return_value = rows.get(default) if default else None
            return found

        session = MagicMock()
        session.query.return_value.filter_by.side_effect = filter_by
        return session

    def test_flagged_default_wins(self) -> None:
        rows = {"a": _model_row(dims=8, stored_dims=8, storage_kind="vector", slug="a")}
        session = self._session(rows, default="a")
        with patch("garage_rag.db.emb_tables.get_settings", return_value=Settings(default_embedding_model="zzz")):
            assert get_model(session) is rows["a"]

    def test_configured_slug_is_used_when_nothing_is_flagged(self) -> None:
        rows = {"bge-m3": _model_row(dims=1024, stored_dims=1024, storage_kind="vector", slug="bge-m3")}
        session = self._session(rows, default=None)
        with patch("garage_rag.db.emb_tables.get_settings", return_value=Settings(default_embedding_model="bge-m3")):
            assert get_model(session) is rows["bge-m3"]

    def test_configured_slug_not_registered_is_named_in_the_error(self) -> None:
        session = self._session({}, default=None)
        with (
            patch("garage_rag.db.emb_tables.get_settings", return_value=Settings(default_embedding_model="bge-m3")),
            pytest.raises(LookupError, match="'bge-m3' is not registered"),
        ):
            get_model(session)

    def test_explicit_slug_never_falls_back(self) -> None:
        rows = {"bge-m3": _model_row(dims=1024, stored_dims=1024, storage_kind="vector", slug="bge-m3")}
        session = self._session(rows, default=None)
        with pytest.raises(LookupError, match="no model 'other'"):
            get_model(session, "other")
