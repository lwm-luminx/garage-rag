"""Fact extraction: distills a document into a list of atomic facts.

Uses LangExtract (https://github.com/google/langextract) against a local model
-- the app's LlamaXPCService, a local Ollama or a local LM Studio, whichever
``facts.provider`` names -- so, like the rest of local inference in this
project, document content never leaves the machine.

Only the part of LangExtract that runs prompts through a caller-built model is
used, vendored as :mod:`garage_rag.enrich.langextract`. Upstream's
``lx.extract(model_id=...)`` chose a backend by regex on the model name, sending
``gemini*`` to Google's API and ``gpt-*``/``o1*`` to OpenAI; that routing and
those backends are not vendored, so there is no code path to a cloud model. The
model here is always :class:`~garage_rag.enrich.local_provider.LocalLanguageModel`
(built by :func:`facts_language_model`), which posts each prompt to the
server's ``/v1/chat/completions`` through :class:`garage_rag.inference.InferenceClient`,
and a model id that names a cloud model is refused outright
(:func:`refuse_cloud_model_id`) rather than passed to a local server that could
never serve it.

Ollama used to go through LangExtract's own Ollama provider on
``/api/generate``. On the M3 probe, the same model on Ollama's ``/v1`` through
this provider produced the same grounded facts, and it keeps every backend on
one client, so Ollama uses it too, with the JSON mode and temperature (0.1)
that provider sent. (What ``/v1`` cannot carry: ``num_ctx`` -- Ollama's default
context, larger than the old 2048, applies -- ``think: false`` and
``keep_alive``, which defaults to the same five minutes.) GPT-OSS models get no
JSON mode, which conflicts with their response format, and a JSON-only system
instruction instead, as before.

The Ollama and LM Studio hosts are configurable (``ollama_host``,
``lmstudio_host``) and may be other machines. Every client is built through the
egress guard (:mod:`garage_rag.net.egress`), and :func:`extract_and_store_facts`
runs the document's class through
:func:`~garage_rag.net.egress.check_destination` before it touches the stored
facts, so a communication is never posted to a host that is not loopback.

The prompts come from ``facts.prompts`` (:mod:`garage_rag.config.fact_prompts`):
the built-in ``default`` prompt is deliberately generic -- it has no notion of
what kind of document it is given (notes, mail, code comments, a paper, ...),
so it asks for "facts" in the abstract -- and users may override it or add
their own. Each prompt's facts are stored, and replaced, separately
(``facts.prompt_name``), and ``fact_runs`` remembers what each prompt last ran
with, so a changed prompt, document or model is detectable (:func:`is_stale`).

A mail's header lines, its own and those of mail quoted or forwarded in it, are
never sent: its sender, recipients and subject are ground truth, written as
metadata facts (:mod:`garage_rag.enrich.metadata`), so a prompt reads the body
alone (:mod:`garage_rag.enrich.mail_body`) and its facts are grounded back on
the document's own text.

Each stored fact is also, optionally, given a ``chunks`` row of its own
(``chunks.fact_id``). That is the entire embedding story: a chunk is a chunk
regardless of where its text came from, so ``embed.ollama.backfill_model``
picks up a fact's chunk the same anti-join pass it already uses for content
chunks, and every registered embedding model ends up with a vector for it --
with no fact-specific embedding path to write or maintain. The vector is stored
in the model's ``potential_fact_emb_`` table, keyed on the fact
(``embed.ollama.store_vectors``).
"""

from __future__ import annotations

import hashlib
import logging
import re

from sqlalchemy import func
from sqlalchemy.orm import Session

from garage_rag.config import get_settings
from garage_rag.config.fact_prompts import EffectivePrompt, effective_prompts
from garage_rag.db.models import Chunk, CorpusClass, Document, Fact, FactRun
from garage_rag.enrich import langextract as lx
from garage_rag.enrich.local_provider import LocalLanguageModel
from garage_rag.enrich.mail_body import fact_source
from garage_rag.inference import Backend, BackendKind, InferenceClient
from garage_rag.net import egress
from garage_rag.xpc.llama_xpc import LlamaXPCClient

log = logging.getLogger(__name__)

# Function-level fallbacks for direct callers of :func:`extract_facts`. The
# CLI and the ``EnrichFacts`` RPC do not use these: they take the model and
# provider from ``facts.model`` / ``facts.provider`` in the config file (see
# :func:`configured_backend`), whose defaults are the app's ``gemma2-2b``
# alias on ``llama_xpc``. ``gemma2:2b`` is the same model under its Ollama
# name, pulled with `ollama pull gemma2:2b`.
DEFAULT_MODEL_ID = "gemma2:2b"

# Fact-distillation backends, all local inference servers reached through
# LocalLanguageModel: "llama_xpc" is the llama.cpp HTTP API the app's
# LlamaXPCService serves on loopback (``llama_host``); "ollama" and
# "lmstudio" are local servers on ``ollama_host`` / ``lmstudio_host``.
FACT_DISTIL_PROVIDERS = ("ollama", "llama_xpc", "lmstudio")
DEFAULT_PROVIDER = "ollama"


def configured_backend(model_id: str | None = None, provider: str | None = None) -> tuple[str, str]:
    """``(model_id, provider)`` for a fact-distillation run.

    Explicit arguments win; anything not given comes from ``facts.model`` and
    ``facts.provider`` in the configuration.
    """
    settings = get_settings()
    return model_id or settings.fact_model, provider or settings.fact_provider


# Model ids upstream LangExtract routed to a cloud API (its Gemini and OpenAI
# provider patterns), plus Anthropic's. ``gpt-oss`` is an open-weights model
# served by Ollama and does not match.
CLOUD_MODEL_PATTERNS = (
    r"^gemini",
    r"^gpt-3\.5",
    r"^gpt-4",
    r"^gpt4\.",
    r"^gpt-5",
    r"^gpt5\.",
    r"^o[1-9]",
    r"^claude",
)


def refuse_cloud_model_id(model_id: str) -> None:
    """Raise ``ValueError`` if ``model_id`` names a cloud-hosted model.

    Fact distillation only runs on local models, so such an id is a
    configuration mistake; failing with a clear message beats a model-not-found
    error from the local server.
    """
    if any(re.match(pattern, model_id, re.IGNORECASE) for pattern in CLOUD_MODEL_PATTERNS):
        raise ValueError(
            f"{model_id!r} names a cloud-hosted model; fact distillation runs only on local models "
            f"(facts.provider {', '.join(FACT_DISTIL_PROVIDERS)})"
        )


def default_prompt() -> EffectivePrompt:
    """The built-in ``default`` prompt, unmodified by any configuration."""
    return effective_prompts([])[0]


def configured_prompts() -> list[EffectivePrompt]:
    """Every prompt ``facts.prompts`` yields, built-ins included, enabled or not."""
    return effective_prompts(get_settings().fact_prompts)


def langextract_examples(prompt: EffectivePrompt) -> list[lx.data.ExampleData]:
    """``prompt``'s few-shot examples in LangExtract's own types."""
    return [
        lx.data.ExampleData(
            text=example.text,
            extractions=[
                lx.data.Extraction(
                    extraction_class=extraction.extraction_class,
                    extraction_text=extraction.text,
                    attributes=dict(extraction.attributes) or None,
                )
                for extraction in example.extractions
            ],
        )
        for example in prompt.examples
    ]


# What LangExtract's own Ollama provider sent (``format: "json"`` and its
# default temperature), kept so moving Ollama onto ``/v1`` changes only the
# route. Ollama's ``/v1`` accepts ``json_object``; LM Studio refuses it, and
# LlamaXPCService never had it, so those two stay prompt-only as before.
OLLAMA_RESPONSE_FORMAT = {"type": "json_object"}
OLLAMA_TEMPERATURE = 0.1
# GPT-OSS's response format conflicts with JSON mode; it gets this instead.
GPT_OSS_SYSTEM_PROMPT = (
    "Output a single JSON object matching the requested extraction format. "
    "Do not include code fences, prose, or reasoning."
)


def _is_gpt_oss_model(model_id: str) -> bool:
    normalized = model_id.lower()
    return normalized == "gpt-oss" or (normalized.startswith("gpt-oss:") and len(normalized) > len("gpt-oss:"))


def fact_backend(provider: str, model_url: str | None = None) -> Backend:
    """The server a fact-distillation run posts to; ``model_url`` overrides the configured host."""
    if provider not in FACT_DISTIL_PROVIDERS:
        raise ValueError(f"unknown fact-distil provider {provider!r}; expected one of {FACT_DISTIL_PROVIDERS}")
    return Backend.from_settings(provider, base_url=model_url)


def facts_language_model(
    provider: str,
    model_id: str,
    model_url: str | None = None,
    *,
    corpus_class: CorpusClass | None = None,
) -> LocalLanguageModel:
    """The LangExtract model for ``provider``, always a :class:`LocalLanguageModel`.

    This is the only thing ``lx.extract`` is ever given as its model. Its client
    is built through the egress guard, which raises
    :class:`~garage_rag.net.egress.EgressBlocked` for a server that is not
    approved, or for a communication (``corpus_class``) going to one that is not
    loopback.
    """
    backend = fact_backend(provider, model_url)
    if backend.kind is BackendKind.LLAMA_XPC:
        return LocalLanguageModel(model_id, LlamaXPCClient(backend.base_url))
    if backend.kind is BackendKind.OLLAMA:
        if _is_gpt_oss_model(model_id):
            return LocalLanguageModel(
                model_id,
                InferenceClient(backend, corpus_class=corpus_class),
                temperature=OLLAMA_TEMPERATURE,
                system_prompt=GPT_OSS_SYSTEM_PROMPT,
            )
        return LocalLanguageModel(
            model_id,
            InferenceClient(backend, corpus_class=corpus_class),
            temperature=OLLAMA_TEMPERATURE,
            response_format=OLLAMA_RESPONSE_FORMAT,
        )
    return LocalLanguageModel(model_id, InferenceClient(backend, corpus_class=corpus_class))


def extract_facts(
    text: str,
    *,
    model_id: str = DEFAULT_MODEL_ID,
    model_url: str | None = None,
    provider: str = DEFAULT_PROVIDER,
    corpus_class: CorpusClass | None = None,
    prompt: EffectivePrompt | None = None,
) -> list[lx.data.Extraction]:
    """Run LangExtract over ``text`` with ``prompt``, returning only grounded extractions.

    ``prompt`` defaults to the built-in ``default`` prompt.

    An ungrounded extraction (``char_interval is None``) is the model quoting
    its own few-shot example rather than the input document; it is filtered
    out here rather than stored, since such a fact cannot be traced back to
    the source text.

    ``provider`` selects the local server ("ollama", "llama_xpc" or
    "lmstudio"); the model object comes from :func:`facts_language_model`. A
    cloud model id is refused (:func:`refuse_cloud_model_id`). ``corpus_class``
    is the class of ``text`` when known; the egress guard refuses to send a
    communication to a server that is not loopback.
    """
    if provider not in FACT_DISTIL_PROVIDERS:
        raise ValueError(f"unknown fact-distil provider {provider!r}; expected one of {FACT_DISTIL_PROVIDERS}")
    refuse_cloud_model_id(model_id)

    prompt = prompt or default_prompt()
    result = lx.extract(
        text_or_documents=text,
        prompt_description=prompt.description,
        examples=langextract_examples(prompt),
        model=facts_language_model(provider, model_id, model_url, corpus_class=corpus_class),
    )
    return [e for e in result.extractions if e.char_interval is not None]


def facts_from_extractions(
    document_id: int,
    extractions: list[lx.data.Extraction],
    *,
    model_id: str = DEFAULT_MODEL_ID,
    prompt: EffectivePrompt | None = None,
) -> list[Fact]:
    """Map LangExtract extractions onto ``facts`` rows, in appearance order, tagged with ``prompt``."""
    prompt = prompt or default_prompt()
    facts: list[Fact] = []
    for ord_, extraction in enumerate(extractions):
        interval = extraction.char_interval
        facts.append(
            Fact(
                document_id=document_id,
                ord=ord_,
                fact=extraction.extraction_text,
                fact_class=extraction.extraction_class,
                attributes=extraction.attributes or {},
                char_start=interval.start_pos if interval else None,
                char_end=interval.end_pos if interval else None,
                extractor="langextract",
                extractor_model=model_id,
                prompt_name=prompt.name,
                prompt_sha256=prompt.sha256,
            )
        )
    return facts


def chunk_for_fact(fact: Fact, *, ord: int, model_id: str = DEFAULT_MODEL_ID) -> Chunk:
    """Build the ``chunks`` row that gets a fact embedded.

    A fact's chunk carries nothing but its own text -- no heading path, no
    span into ``documents.content`` (that belongs to the fact itself, via
    ``char_start``/``char_end``). ``fact.id`` must already be set, i.e. the
    fact has been flushed.
    """
    return Chunk(
        document_id=fact.document_id,
        ord=ord,
        text=fact.fact,
        chunk_sha256=hashlib.sha256(fact.fact.encode("utf-8")).digest(),
        chunker=f"facts:langextract:{model_id}",
        fact_id=fact.id,
    )


def is_stale(run: FactRun | None, document: Document, prompt: EffectivePrompt, model_id: str) -> bool:
    """Whether ``prompt``'s facts for ``document`` need extracting (again).

    True when the prompt never ran on the document, or when what it ran with --
    the prompt's description and examples, the text it read
    (:func:`~garage_rag.enrich.mail_body.fact_source`), the model -- has
    changed since.
    """
    return (
        run is None
        or bytes(run.prompt_sha256) != prompt.sha256
        or bytes(run.content_sha256) != fact_source(document).sha256
        or run.extractor_model != model_id
    )


def extract_and_store_facts(
    session: Session,
    document: Document,
    *,
    prompt: EffectivePrompt | None = None,
    model_id: str = DEFAULT_MODEL_ID,
    model_url: str | None = None,
    provider: str = DEFAULT_PROVIDER,
    queue_for_embedding: bool = True,
) -> list[Fact]:
    """Extract ``prompt``'s facts for ``document``, replacing that prompt's earlier ones.

    ``prompt`` defaults to the built-in ``default`` prompt. Re-extraction is
    idempotent per prompt: the document's existing facts *from this prompt*
    are deleted before the new ones are inserted, the same replace-on-rebuild
    pattern ``ingest`` uses when a document's chunks are rebuilt, and other
    prompts' facts are left alone. Deleting a fact cascades
    (``chunks.fact_id`` is ``ON DELETE CASCADE``) into its chunk and, from
    there, into every per-model embedding table, so a re-extraction never
    leaves a stale fact vector behind -- including when the document has since
    become empty, which clears the prompt's facts rather than keeping the old
    ones. The run itself is recorded in ``fact_runs`` (see :func:`is_stale`).

    When ``queue_for_embedding`` is true (the default), each new fact also
    gets a ``chunks`` row appended after the document's existing chunks, ready
    for ``embed.ollama.backfill_model`` to pick up.

    The document's class goes through the egress guard before anything is
    deleted: a server that is not approved, or a communication for a server
    that is not loopback, raises :class:`~garage_rag.net.egress.EgressBlocked`.
    """
    prompt = prompt or default_prompt()
    backend = fact_backend(provider, model_url)
    egress.check_destination(
        backend.base_url,
        purpose=f"facts:{provider}",
        corpus_class=document.corpus_class,
        loopback_only=backend.kind is BackendKind.LLAMA_XPC,
    )

    session.query(Fact).filter(Fact.document_id == document.id, Fact.prompt_name == prompt.name).delete()
    facts: list[Fact] = []
    # A mail's header lines are metadata facts already; the model reads its body.
    source = fact_source(document)
    if source.text.strip():
        log.info("extracting facts for document %s with prompt %s via %s", document.id, prompt.name, provider)
        extractions = extract_facts(
            source.text,
            model_id=model_id,
            model_url=model_url,
            provider=provider,
            corpus_class=document.corpus_class,
            prompt=prompt,
        )
        facts = facts_from_extractions(document.id, extractions, model_id=model_id, prompt=prompt)
        for fact in facts:
            fact.char_start, fact.char_end = source.span_to_document(fact.char_start, fact.char_end)
        session.add_all(facts)

    session.merge(
        FactRun(
            document_id=document.id,
            prompt_name=prompt.name,
            prompt_sha256=prompt.sha256,
            content_sha256=source.sha256,
            extractor_model=model_id,
            facts=len(facts),
            extracted_at=func.now(),
        )
    )

    if queue_for_embedding and facts:
        # Facts need ids before a chunk can reference one via fact_id.
        session.flush()
        base_ord = (
            session.query(func.coalesce(func.max(Chunk.ord), -1)).filter(Chunk.document_id == document.id).scalar() + 1
        )
        session.add_all(chunk_for_fact(fact, ord=base_ord + i, model_id=model_id) for i, fact in enumerate(facts))

    return facts
