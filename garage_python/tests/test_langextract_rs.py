"""``langextract_rs`` (the Rust port) against the vendored LangExtract it replaces.

``garage_rag.enrich.langextract`` is the specification. Fact distillation's own prompts, examples and
model (:class:`~garage_rag.enrich.local_provider.LocalLanguageModel` over a stand-in client) go
through both, over the UI tests' fixture corpus and random text, with answers that are a function of
the prompt; both must send the same prompts and return the same extractions, spans, statuses and
attributes. Skips when ``langextract_rs`` is not installed (``maturin develop`` in the crate's
``python/`` folder installs it into the venv).
"""

from __future__ import annotations

import hashlib
import json
import random
from unittest.mock import MagicMock

import pytest

from garage_rag.config import repo_root
from garage_rag.enrich import langextract as vendored
from garage_rag.enrich.facts import default_prompt, langextract_examples
from garage_rag.enrich.local_provider import LocalLanguageModel
from garage_rag.inference import ChatResult

try:
    import langextract_rs as rust
except ImportError:
    rust = None

# A mark rather than a module-level importorskip: a module skipped whole collects nothing, and pytest's
# "no tests ran" (exit 5) fails the Bazel target, which has no langextract_rs.
pytestmark = pytest.mark.skipif(rust is None, reason="langextract_rs is not installed")

CORPUS = repo_root() / "macapp" / "Tests" / "Fixtures" / "corpus"


def _answer(prompt: str) -> str:
    """Picks spans of the question (some verbatim, some altered, some invented), seeded by the prompt."""
    rng = random.Random(hashlib.sha256(prompt.encode()).digest())
    question = prompt.rsplit("Q: ", 1)[1].rsplit("\nA: ", 1)[0]
    words = question.split()
    items = []
    for _ in range(rng.randrange(0, 6)):
        roll = rng.random()
        if words and roll < 0.5:
            i = rng.randrange(len(words))
            text = " ".join(words[i : i + rng.randrange(1, 8)])
        elif words and roll < 0.75:
            text = " ".join(rng.sample(words, min(len(words), rng.randrange(2, 5))))
        else:
            text = "a fact the document never states"
        item = {"fact": text}
        if rng.random() < 0.5:
            item["fact_attributes"] = {"year": "1998"} if rng.random() < 0.5 else {}
        items.append(item)
    body = json.dumps({"extractions": items}, indent=2)
    return rng.choice([f"```json\n{body}\n```", body, f"<think>ok</think>{body}", body[: len(body) // 2]])


def _model() -> tuple[LocalLanguageModel, list[str]]:
    prompts: list[str] = []
    client = MagicMock()

    def chat(messages, *args, **kwargs):
        prompts.append(messages[-1]["content"])
        return ChatResult(text=_answer(messages[-1]["content"]))

    client.chat.side_effect = chat
    return LocalLanguageModel("parity", client), prompts


def _flatten(extractions) -> list[tuple]:
    return [
        (
            e.extraction_class,
            e.extraction_text,
            None if e.char_interval is None else (e.char_interval.start_pos, e.char_interval.end_pos),
            None if e.alignment_status is None else e.alignment_status.value,
            e.extraction_index,
            e.group_index,
            e.attributes,
        )
        for e in extractions
    ]


def _both(text: str, **kwargs) -> None:
    prompt = default_prompt()
    examples = langextract_examples(prompt)
    results = []
    for module in (vendored, rust):
        model, prompts = _model()
        result = module.extract(
            text_or_documents=text,
            prompt_description=prompt.description,
            examples=examples,
            model=model,
            **kwargs,
        )
        results.append((prompts, _flatten(result.extractions)))
    (vendored_prompts, vendored_out), (rust_prompts, rust_out) = results
    assert rust_prompts == vendored_prompts
    assert rust_out == vendored_out


@pytest.mark.parametrize("path", sorted(p.name for p in CORPUS.iterdir() if p.is_file()) if CORPUS.is_dir() else [])
def test_fixture_corpus(path: str) -> None:
    _both((CORPUS / path).read_text(errors="replace"), max_char_buffer=300)


@pytest.mark.parametrize("seed", range(40))
def test_random_text(seed: int) -> None:
    rng = random.Random(seed)
    words = [
        "Acme",
        "Corp",
        "was",
        "founded",
        "in",
        "1998",
        "by",
        "Jane",
        "Doe.",
        "The",
        "company's",
        "HQ",
        "is",
        "in",
        "Austin,",
        "Texas!\nIt",
        "grew",
    ]
    text = " ".join(rng.choice(words) for _ in range(rng.randrange(1, 200)))
    _both(text, max_char_buffer=rng.choice([50, 200, 1000]), batch_length=rng.choice([1, 10]))


def test_examples_render_identically() -> None:
    """The default prompt's examples carry attributes; both write them into the prompt the same way."""
    _both("Jane Doe founded Acme Corp in 1998.")
