"""The clustering logic of ``garage cluster-facts`` that needs no database.

The SQL (neighbours, the overlay, list_facts' cluster columns) is covered in
``test_postgres.py`` (``TestFactClusters``).
"""

from __future__ import annotations

from unittest.mock import MagicMock

import pytest

from garage_rag.config import Settings, reset_settings, set_settings
from garage_rag.enrich.clusters import (
    Distiller,
    average_linkage,
    claim_signature,
    connected_groups,
    distill_prompt,
    guarded_clusters,
    members_sha256,
    pair,
    parse_distill_reply,
    representative,
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
