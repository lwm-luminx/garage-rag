"""The clustering logic of ``garage cluster-facts`` that needs no database.

The SQL (both levels, the incremental placement, list_facts' cluster columns)
is covered in ``test_postgres.py`` (``TestDistilledFacts``).
"""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest

from garage_rag.config import Settings, reset_settings, set_settings
from garage_rag.enrich.clusters import (
    ClusterParams,
    ClusterProgress,
    Distiller,
    added,
    attach_ok,
    average_linkage,
    claim_signature,
    connected_groups,
    cosine,
    distill_prompt,
    document_restatements,
    grow_group,
    guarded_clusters,
    mean_vector,
    members_sha256,
    needs_model,
    normalize_fact,
    pair,
    parse_distill_reply,
    parse_vector,
    representative,
    tight_radius,
    variability,
    vector_literal,
)


@pytest.fixture(autouse=True)
def _settings():
    yield
    reset_settings()


class TestClaimSignature:
    def test_restatements_agree(self) -> None:
        assert claim_signature("The heat pump was installed in March 2024.") == claim_signature(
            "In March 2024, a heat pump was installed."
        )

    @pytest.mark.parametrize(
        ("a", "b"),
        [
            ("The company has 42 employees.", "The company has 45 employees."),
            ("The meeting is on Tuesday.", "The meeting is on Wednesday."),
            ("The meeting is on Tuesday.", "The meeting is not on Tuesday."),
            ("Ada can come.", "Ada can't come."),
            ("It was paid before the deadline.", "It was paid after the deadline."),
        ],
    )
    def test_quantities_times_and_negation_must_match(self, a: str, b: str) -> None:
        assert claim_signature(a) != claim_signature(b)

    def test_thousands_separators_do_not_matter(self) -> None:
        assert claim_signature("It cost $1,200.") == claim_signature("It cost 1200 dollars.")

    def test_may_the_verb_is_not_may_the_month(self) -> None:
        assert claim_signature("Ada may visit.") == claim_signature("Ada might visit.")


class TestGrouping:
    def test_connected_groups_leave_out_singletons(self) -> None:
        assert connected_groups([1, 2, 3, 4, 5], [(1, 2), (2, 3), (4, 9)]) == [[1, 2, 3]]

    def test_average_linkage_merges_close_members(self) -> None:
        sims = {pair(1, 2): 0.95, pair(2, 3): 0.93, pair(1, 3): 0.92}
        assert average_linkage([1, 2, 3], sims, 0.9) == [[1, 2, 3]]

    def test_average_linkage_does_not_chain_through_a_middle_member(self) -> None:
        # 1~2 and 2~3, but 1 and 3 are unrelated: single linkage would group all three.
        sims = {pair(1, 2): 0.95, pair(2, 3): 0.94, pair(1, 3): 0.5}
        assert average_linkage([1, 2, 3], sims, 0.9) == [[1, 2]]

    def test_a_missing_pair_keeps_clusters_apart(self) -> None:
        assert average_linkage([1, 2], {}, 0.9) == []

    def test_the_guard_splits_before_linking(self) -> None:
        texts = {1: "Rent is 900.", 2: "The rent is 900.", 3: "Rent is 950."}
        sims = {pair(1, 2): 0.97, pair(1, 3): 0.97, pair(2, 3): 0.96}
        assert guarded_clusters([1, 2, 3], texts, sims, 0.9) == [[1, 2]]

    def test_the_representative_is_the_longest_then_the_oldest(self) -> None:
        texts = {5: "Ada wrote it.", 3: "Ada wrote the notes.", 4: "Ada wrote the notes!"}
        assert representative([3, 4, 5], texts) == 3

    def test_the_member_hash_ignores_order(self) -> None:
        assert members_sha256([3, 1, 2]) == members_sha256([1, 2, 3]) != members_sha256([1, 2])


class TestDistillReply:
    @pytest.mark.parametrize(
        ("reply", "expected"),
        [
            ("YES\nAda wrote the notes.", (True, "Ada wrote the notes.")),
            ("**Yes**\n\nStatement: Ada wrote the notes.", (True, "Ada wrote the notes.")),
            ("YES: Ada wrote the notes.", (True, "Ada wrote the notes.")),
            ('YES\n"Ada wrote the notes."', (True, "Ada wrote the notes.")),
            ("YES", (True, None)),
            ("NO\nThey differ in the year.", (False, None)),
            ("Maybe.", (False, None)),
            ("", (False, None)),
        ],
    )
    def test_parses_the_answer(self, reply: str, expected: tuple[bool, str | None]) -> None:
        assert parse_distill_reply(reply) == expected

    def test_the_prompt_lists_every_statement(self) -> None:
        prompt = distill_prompt(["A.", "B."])
        assert "1. A.\n2. B." in prompt and "YES or NO" in prompt

    def test_distill_asks_the_chat_model_deterministically(self) -> None:
        model = MagicMock()
        model.chat.return_value = "YES\nAda wrote the notes."
        assert Distiller(model).distill(["Ada wrote the notes.", "The notes are Ada's."]) == (
            True,
            "Ada wrote the notes.",
        )
        messages = model.chat.call_args.args[0]
        assert [m["role"] for m in messages] == ["system", "user"]
        assert model.chat.call_args.kwargs["temperature"] == 0.0


class TestDistillerEgress:
    def _distiller(self, host: str) -> Distiller:
        model = MagicMock()
        model.host = host
        return Distiller(model)

    def test_communications_go_only_to_a_loopback_model(self) -> None:
        set_settings(Settings(ollama_host="http://gpu-box.lan:11434"))
        remote = self._distiller("http://gpu-box.lan:11434")
        assert remote.may_send(["document", "code"])
        assert not remote.may_send(["document", "communication"])
        assert self._distiller("http://127.0.0.1:8790").may_send(["communication"])


class TestDocumentRestatements:
    TEXTS = {
        1: "The roof was replaced in 2019 by Acme Roofing.",
        2: "The roof was replaced in 2019.",
        3: "The roof was replaced in 2019 by Acme Roofing",
        4: "The roof was not replaced in 2019.",
        5: "The garage door opener is a Genie.",
    }

    def test_normalize_fact_ignores_case_space_and_trailing_punctuation(self) -> None:
        assert normalize_fact("  The Roof  was\nreplaced. ") == normalize_fact("the roof was replaced")

    def test_same_text_restates_without_a_vector(self) -> None:
        restates = document_restatements([1, 3, 5], self.TEXTS, {}, 0.9)
        # Equal lengths: the older (lower id) represents.
        assert restates == {3: (1, 1.0)}

    def test_close_vectors_restate_the_longest(self) -> None:
        sims = {pair(1, 2): 0.93, pair(2, 5): 0.2, pair(1, 5): 0.2}
        assert document_restatements([1, 2, 5], self.TEXTS, sims, 0.9) == {2: (1, 0.93)}

    def test_a_same_text_twin_without_a_vector_joins_its_twins_group(self) -> None:
        # 3 has no vector; it stands where 1 does, so {1, 3} and 2 still average above the threshold.
        sims = {pair(1, 2): 0.93}
        assert document_restatements([1, 2, 3], self.TEXTS, sims, 0.9) == {2: (1, 0.93), 3: (1, 1.0)}

    def test_the_guard_keeps_a_negation_apart(self) -> None:
        sims = {pair(2, 4): 0.97}
        assert document_restatements([2, 4], self.TEXTS, sims, 0.9) == {}


def _unit(*xs: float) -> list[float]:
    norm = sum(x * x for x in xs) ** 0.5
    return [x / norm for x in xs]


class TestVectors:
    def test_literal_round_trip(self) -> None:
        assert parse_vector(vector_literal([0.5, -1.25, 3.0])) == [0.5, -1.25, 3.0]
        assert parse_vector("[]") == []

    def test_mean_cosine_and_added(self) -> None:
        assert mean_vector([[1.0, 0.0], [0.0, 1.0]]) == [0.5, 0.5]
        assert cosine([1.0, 0.0], [0.0, 1.0]) == 0.0
        assert cosine([1.0, 1.0], [2.0, 2.0]) == pytest.approx(1.0)
        assert added([0.5, 0.5], 2, [1.0, 1.0]) == pytest.approx([2 / 3, 2 / 3])

    def test_variability(self) -> None:
        seed = _unit(1, 0)
        vectors = [_unit(1, 0), _unit(1, 0.2)]
        centroid = mean_vector(vectors)
        var = variability(vectors, centroid, seed)
        assert 0 < var.spread <= var.radius
        assert var.drift == pytest.approx(1 - cosine(centroid, seed))
        assert variability([seed], seed, seed).spread == pytest.approx(0.0, abs=1e-12)


class TestAttach:
    def test_a_close_vector_joins(self) -> None:
        seed = _unit(1, 0)
        accepted = attach_ok(_unit(1, 0.1), seed, seed, 3, threshold=0.9, max_drift=0.05)
        assert accepted is not None
        similarity, centroid = accepted
        assert similarity > 0.99
        assert 1 - cosine(centroid, seed) < 0.05

    def test_a_far_vector_does_not(self) -> None:
        seed = _unit(1, 0)
        assert attach_ok(_unit(1, 1), seed, seed, 3, threshold=0.9, max_drift=0.5) is None

    def test_drift_from_the_seed_is_capped(self) -> None:
        # Close enough to the centroid, but the centroid has already moved off
        # the seed: one more step the same way goes too far.
        seed = _unit(1, 0)
        centroid = _unit(1, 0.35)
        assert attach_ok(_unit(1, 0.7), centroid, seed, 1, threshold=0.8, max_drift=0.1) is None
        assert attach_ok(_unit(1, 0.7), centroid, seed, 1, threshold=0.8, max_drift=0.5) is not None

    def test_it_must_be_close_to_the_seed_too(self) -> None:
        # 0.96 similar to a drifted centroid, but only 0.82 to the seed.
        seed = _unit(1, 0)
        assert attach_ok(_unit(1, 0.7), _unit(1, 0.35), seed, 1, threshold=0.9, max_drift=0.5) is None

    def test_a_batch_is_judged_against_its_anchor(self) -> None:
        seed = _unit(1, 0)
        moved = _unit(1, 0.3)
        assert attach_ok(_unit(1, 0.35), moved, seed, 1, threshold=0.99, max_drift=0.5, anchor=seed) is None
        assert attach_ok(_unit(1, 0.05), moved, seed, 1, threshold=0.99, max_drift=0.5, anchor=seed) is not None


class TestGrowGroup:
    """Facts on a unit circle: ids 1..4 sit close together, 9 further on (a different claim nearby)."""

    ANGLES = {1: 0.0, 2: 0.05, 3: 0.1, 4: 0.15, 9: 0.7}

    def vectors(self) -> dict[int, list[float]]:
        import math

        return {i: [math.cos(a), math.sin(a)] for i, a in self.ANGLES.items()}

    def knn(self, vectors: dict[int, list[float]]):
        def nearest(centroid: list[float], members: int) -> list[int]:
            return sorted(vectors, key=lambda i: -cosine(vectors[i], centroid))

        return nearest

    def test_grows_to_the_gap_and_stops(self) -> None:
        vectors = self.vectors()
        grown = grow_group([1, 2], vectors, lambda _: "same", self.knn(vectors), set(), threshold=0.95, max_drift=0.01)
        assert sorted(grown.members) == [1, 2, 3, 4]
        assert grown.seed == mean_vector([vectors[1], vectors[2]])

    def test_taken_and_other_signatures_are_passed_over(self) -> None:
        vectors = self.vectors()
        grown = grow_group(
            [1],
            vectors,
            lambda i: "odd" if i == 3 else "same",
            self.knn(vectors),
            {2},
            threshold=0.95,
            max_drift=0.01,
        )
        assert sorted(grown.members) == [1, 4]

    def test_a_large_group_asks_past_its_own_members(self) -> None:
        import math

        vectors = {i: [math.cos(i * 1e-3), math.sin(i * 1e-3)] for i in range(1, 121)}
        asked: list[int] = []

        def nearest(centroid: list[float], members: int) -> list[int]:
            asked.append(members)
            return sorted(vectors, key=lambda i: -cosine(vectors[i], centroid))[: members + 50]

        grown = grow_group([1], vectors, lambda _: "same", nearest, set(), threshold=0.99, max_drift=0.01, rounds=4)
        assert len(grown.members) == 120
        assert asked[0] == 1 and asked[1] > 50

    def test_a_tight_drift_cap_keeps_the_group_small(self) -> None:
        vectors = self.vectors()
        grown = grow_group([1], vectors, lambda _: "same", self.knn(vectors), set(), threshold=0.95, max_drift=5e-4)
        assert sorted(grown.members) == [1, 2]


class TestTiers:
    def test_the_tight_radius_follows_group_size(self) -> None:
        assert tight_radius(2, 0.97) == pytest.approx(1 - (0.985**0.5))
        assert tight_radius(2, 0.97) < tight_radius(10, 0.97) < 1 - 0.97**0.5

    def test_needs_model(self) -> None:
        # A pair at the 0.9 threshold sits 0.025 from its centroid: loose, so the model is asked.
        pair_at = lambda s: 1 - ((1 + s) / 2) ** 0.5  # noqa: E731
        assert needs_model(pair_at(0.90), 2, 0.97)
        assert not needs_model(pair_at(0.98), 2, 0.97)
        assert needs_model(0.02, 10, 0.97)
        assert needs_model(0.0, 2, 1.0)


class TestRefusals:
    def test_a_binary_quantized_model_does_not_cluster(self) -> None:
        from garage_rag.enrich.clusters import cluster_facts

        model = MagicMock(index_kind="hnsw_bq", slug="huge")
        params = ClusterParams(threshold=0.9, neighbors=10, seed_threshold=0.95, max_drift=0.05, tight_similarity=0.97)
        with pytest.raises(ValueError, match="binary-quantized"):
            cluster_facts(MagicMock(), model, params)


class TestParams:
    def test_the_regroup_key_follows_what_shapes_groups(self) -> None:
        base = ClusterParams(threshold=0.9, neighbors=10, seed_threshold=0.95, max_drift=0.05, tight_similarity=0.97)
        assert (
            base.corpus_key()
            == ClusterParams(
                threshold=0.9,
                neighbors=30,
                seed_threshold=0.95,
                max_drift=0.05,
                tight_similarity=0.99,
                attach_candidates=9,
            ).corpus_key()
        )
        assert (
            base.corpus_key()
            != ClusterParams(
                threshold=0.9, neighbors=10, seed_threshold=0.95, max_drift=0.1, tight_similarity=0.97
            ).corpus_key()
        )
        assert base.document_key("bge-m3") == "bge-m3;t=0.9"
        restating = ClusterParams(
            threshold=0.9,
            neighbors=10,
            seed_threshold=0.95,
            max_drift=0.05,
            tight_similarity=0.97,
            restate_threshold=0.92,
        )
        assert restating.document_key("bge-m3") == "bge-m3;t=0.92"
        assert restating.corpus_key() == base.corpus_key()

    def test_progress_messages(self) -> None:
        assert ClusterProgress(phase="grow", candidates=3).message == "growing groups: 3"
        assert ClusterProgress(phase="done").message == ""
