"""Fact-extraction prompts: the ``facts.prompts`` setting and the built-in default.

A prompt is what LangExtract is given besides the document: a description (the
instructions) and few-shot examples, each an example text with the extractions
expected from it. ``garage enrich-facts`` runs every enabled prompt that applies
to a document, and each stored fact records the prompt that produced it
(``facts.prompt_name``) and a hash of that prompt's text (``prompt_sha256``).

**Merge by name.** The built-in prompts (:data:`BUILTIN_PROMPTS`, today just
``default``) are always present unless overridden: an entry in ``facts.prompts``
with a built-in's name replaces it field by field, and any other entry is added
after the built-ins. So adding a second prompt keeps the default running, and
``{"name": "default", "enabled": false}`` turns the default off. An override may
leave ``description`` or ``examples`` out to keep the built-in's; a prompt that
is not a built-in must give both.

**Graph schema.** A prompt's optional ``graph`` block says how its classes
appear in the AGE graph (``garage_rag.db.graph``), so a new kind of vertex or
edge is configuration, not code. A vertex entry projects the distilled facts of
one class (the class's potential facts, deduplicated by ``cluster-facts``) as
vertices of a label of their own instead of ``Fact``; an edge entry turns each
potential fact of one class into an edge between the distilled facts its
source and target attributes name. :func:`graph_schema` merges every prompt's
block and rejects labels that clash.

Nothing here talks to a model. The prompts go only to the local server
``facts.provider`` names, through the same guarded client as before.
"""

from __future__ import annotations

import hashlib
import json
import re
import textwrap
from dataclasses import dataclass
from typing import Literal

from pydantic import BaseModel, Field, field_validator

CorpusClassName = Literal["document", "code", "communication"]

# A prompt's name is a CLI argument, a JSON key and a database value: keep it plain.
PROMPT_NAME_PATTERN = r"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"
# Graph labels become AGE label tables; attribute names are read with ->> in SQL.
VERTEX_LABEL_PATTERN = r"^[A-Z][A-Za-z0-9]{0,62}$"
EDGE_LABEL_PATTERN = r"^[A-Z][A-Z0-9_]{0,62}$"
ATTRIBUTE_PATTERN = r"^[A-Za-z_][A-Za-z0-9_]{0,62}$"
CLASS_PATTERN = r"^[A-Za-z0-9][A-Za-z0-9 _.-]{0,62}$"
# The projection's own labels (garage_rag.db.graph), which configuration may not take.
BUILTIN_VERTEX_LABELS = frozenset({"Document", "Chunk", "Author", "PotentialFact", "Fact"})
BUILTIN_EDGE_LABELS = frozenset({"HAS_CHUNK", "WROTE", "RECEIVED", "STATES", "RESTATES", "SUPPORTS"})


class FactExtractionExample(BaseModel):
    """One extraction the model should produce from an example's text."""

    model_config = {"extra": "forbid", "populate_by_name": True}

    extraction_class: str = Field(
        default="fact",
        alias="class",
        description="Label for what kind of thing this is; stored as facts.fact_class.",
    )
    text: str = Field(description="The extraction, quoted exactly from the example's text.")
    attributes: dict[str, str | list[str]] = Field(
        default_factory=dict,
        description="Optional attributes the model should attach; stored as facts.attributes.",
    )


class FactExample(BaseModel):
    """A few-shot example: a text and what should be extracted from it."""

    model_config = {"extra": "forbid"}

    text: str = Field(description="Example input text.")
    extractions: list[FactExtractionExample] = Field(
        default_factory=list,
        description="The extractions expected from the text, in the order they appear.",
    )


class GraphVertex(BaseModel):
    """A class whose distilled facts are vertices of their own label."""

    model_config = {"extra": "forbid", "populate_by_name": True}

    extraction_class: str = Field(
        alias="class", pattern=CLASS_PATTERN, description="The extraction class (facts.fact_class) projected."
    )
    label: str = Field(
        pattern=VERTEX_LABEL_PATTERN,
        description="The vertex label, e.g. Person. Not one of the built-in labels.",
    )
    title: str | None = Field(
        default=None,
        pattern=ATTRIBUTE_PATTERN,
        description=(
            "The attribute whose value names the vertex (its representative fact's); "
            "unset: the distilled fact's statement."
        ),
    )


class GraphEdge(BaseModel):
    """A class whose potential facts are edges between two other classes' distilled facts."""

    model_config = {"extra": "forbid", "populate_by_name": True}

    extraction_class: str = Field(
        alias="class", pattern=CLASS_PATTERN, description="The extraction class (facts.fact_class) projected."
    )
    source: str = Field(pattern=ATTRIBUTE_PATTERN, description="The attribute naming the edge's source.")
    source_class: str = Field(pattern=CLASS_PATTERN, description="The class the source is a distilled fact of.")
    target: str = Field(pattern=ATTRIBUTE_PATTERN, description="The attribute naming the edge's target.")
    target_class: str = Field(pattern=CLASS_PATTERN, description="The class the target is a distilled fact of.")
    label: str = Field(
        default="RELATED_TO",
        pattern=EDGE_LABEL_PATTERN,
        description="The edge label, or the fallback when label_attribute names none of labels.",
    )
    label_attribute: str | None = Field(
        default=None,
        pattern=ATTRIBUTE_PATTERN,
        description="An attribute (e.g. predicate) whose value, upper-cased with spaces as _, picks the label.",
    )
    labels: list[str] = Field(
        default_factory=list,
        description="The labels label_attribute may pick, e.g. WORKS_AT; any other value takes label.",
    )

    @field_validator("labels")
    @classmethod
    def _labels_are_labels(cls, value: list[str]) -> list[str]:
        for label in value:
            if not re.fullmatch(EDGE_LABEL_PATTERN, label):
                raise ValueError(f"{label!r} is not an edge label (upper case, digits and _)")
        return value


class FactGraph(BaseModel):
    """How a prompt's classes appear in the graph."""

    model_config = {"extra": "forbid"}

    vertices: list[GraphVertex] = Field(default_factory=list, description="Classes projected as vertices.")
    edges: list[GraphEdge] = Field(default_factory=list, description="Classes projected as edges.")


class FactPrompt(BaseModel):
    """A named fact-extraction prompt, as written in ``facts.prompts``."""

    model_config = {"extra": "forbid"}

    name: str = Field(
        pattern=PROMPT_NAME_PATTERN,
        description=(
            "Unique name, recorded on every fact the prompt produces. The name of a built-in prompt "
            "('default') overrides it instead of adding a new one."
        ),
    )
    description: str | None = Field(
        default=None,
        description=(
            "The instructions given to the model. Required for a new prompt; an override of a "
            "built-in may leave it out to keep the built-in's."
        ),
    )
    examples: list[FactExample] | None = Field(
        default=None,
        description=(
            "Few-shot examples (LangExtract's shape: text plus expected extractions). Required, and "
            "not empty, for a new prompt; an override of a built-in may leave it out to keep the "
            "built-in's."
        ),
    )
    corpus_classes: list[CorpusClassName] = Field(
        default_factory=list,
        description="Corpus classes the prompt runs on (document, code, communication); empty means all.",
    )
    sources: list[str] = Field(
        default_factory=list,
        description="Source slugs the prompt runs on; empty means every source.",
    )
    enabled: bool = Field(default=True, description="Set false to stop running this prompt.")
    graph: FactGraph | None = Field(
        default=None,
        description=(
            "How this prompt's classes appear in the graph: vertices of their own label, or edges "
            "between other classes. Left out: its facts are PotentialFact and Fact vertices only."
        ),
    )

    @field_validator("examples")
    @classmethod
    def _examples_not_empty(cls, value: list[FactExample] | None) -> list[FactExample] | None:
        if value is not None and not value:
            raise ValueError("examples must not be empty; LangExtract needs at least one")
        return value


DEFAULT_PROMPT_NAME = "default"

DEFAULT_DESCRIPTION = textwrap.dedent("""\
    Extract every standalone fact stated in this document.

    A fact is a single, self-contained claim or piece of information that
    would still be true and meaningful if read on its own, out of context.
    Use the exact wording from the document for each fact -- do not
    paraphrase, summarize, or combine multiple facts into one. Do not invent
    or infer anything that is not explicitly stated. List facts in the order
    they appear.""")

DEFAULT_EXAMPLES = [
    FactExample(
        text=(
            "Acme Corp was founded in 1998 by Jane Doe. The company is "
            "headquartered in Austin, Texas, and has 42 employees."
        ),
        extractions=[
            FactExtractionExample(text="Acme Corp was founded in 1998 by Jane Doe."),
            FactExtractionExample(text="The company is headquartered in Austin, Texas."),
            FactExtractionExample(text="The company has 42 employees."),
        ],
    )
]

# The prompts that exist without any configuration. Deliberately generic: the
# extractor has no notion of what kind of document it is given, so it asks for
# "facts" in the abstract.
BUILTIN_PROMPTS: tuple[FactPrompt, ...] = (
    FactPrompt(name=DEFAULT_PROMPT_NAME, description=DEFAULT_DESCRIPTION, examples=DEFAULT_EXAMPLES),
)
BUILTIN_PROMPT_NAMES = frozenset(prompt.name for prompt in BUILTIN_PROMPTS)


@dataclass(frozen=True)
class EffectivePrompt:
    """A prompt as it runs: an override merged onto its built-in, everything filled in."""

    name: str
    description: str
    examples: tuple[FactExample, ...]
    corpus_classes: tuple[str, ...]
    sources: tuple[str, ...]
    enabled: bool
    builtin: bool
    # A built-in with an entry in facts.prompts.
    customized: bool
    graph: FactGraph | None = None

    @property
    def sha256(self) -> bytes:
        """Hash of what the model is shown (description and examples), stored beside each fact.

        Scope and ``enabled`` are left out: they decide which documents a prompt
        runs on, not what it extracts, so changing them does not make facts stale.
        """
        payload = json.dumps(
            {
                "description": self.description,
                "examples": [example.model_dump(by_alias=True) for example in self.examples],
            },
            sort_keys=True,
            ensure_ascii=False,
            separators=(",", ":"),
        )
        return hashlib.sha256(payload.encode("utf-8")).digest()

    def applies_to(self, corpus_class: str | None, source_slug: str | None) -> bool:
        """Whether this prompt runs on a document of ``corpus_class`` from ``source_slug``."""
        if self.corpus_classes and corpus_class not in self.corpus_classes:
            return False
        return not (self.sources and source_slug not in self.sources)

    def to_config(self) -> dict:
        """The full ``facts.prompts`` entry for this prompt, as JSON."""
        return {
            "name": self.name,
            "description": self.description,
            "examples": [example.model_dump(by_alias=True) for example in self.examples],
            "corpus_classes": list(self.corpus_classes),
            "sources": list(self.sources),
            "enabled": self.enabled,
            **({"graph": self.graph.model_dump(by_alias=True, exclude_none=True)} if self.graph else {}),
        }


def validate_prompt_list(prompts: list[FactPrompt]) -> list[FactPrompt]:
    """Names are unique, and a prompt that is not a built-in says everything itself."""
    seen: set[str] = set()
    for prompt in prompts:
        if prompt.name in seen:
            raise ValueError(f"facts.prompts: the name {prompt.name!r} is used twice")
        seen.add(prompt.name)
        if prompt.name in BUILTIN_PROMPT_NAMES:
            continue
        missing = [key for key in ("description", "examples") if getattr(prompt, key) is None]
        if missing:
            raise ValueError(
                f"facts.prompts: {prompt.name!r} is not a built-in prompt, so it needs {' and '.join(missing)}"
            )
        if not (prompt.description or "").strip():
            raise ValueError(f"facts.prompts: {prompt.name!r} has an empty description")
    graph_schema(effective_prompts(prompts))
    return prompts


def _resolve(prompt: FactPrompt, base: FactPrompt | None) -> EffectivePrompt:
    description = prompt.description if prompt.description is not None else (base.description if base else None)
    examples = prompt.examples if prompt.examples is not None else (base.examples if base else None)
    if description is None or examples is None:  # validate_prompt_list rules this out
        raise ValueError(f"facts.prompts: {prompt.name!r} needs a description and examples")
    return EffectivePrompt(
        name=prompt.name,
        description=description,
        examples=tuple(examples),
        corpus_classes=tuple(prompt.corpus_classes),
        sources=tuple(prompt.sources),
        enabled=prompt.enabled,
        builtin=base is not None,
        customized=base is not None and prompt is not base,
        graph=prompt.graph if prompt.graph is not None else (base.graph if base else None),
    )


def effective_prompts(configured: list[FactPrompt]) -> list[EffectivePrompt]:
    """Built-ins first (each overridden by a configured entry of its name), then the others in file order."""
    by_name = {prompt.name: prompt for prompt in configured}
    resolved = [_resolve(by_name.get(builtin.name, builtin), builtin) for builtin in BUILTIN_PROMPTS]
    resolved += [_resolve(prompt, None) for prompt in configured if prompt.name not in BUILTIN_PROMPT_NAMES]
    return resolved


def select_prompts(prompts: list[EffectivePrompt], names: list[str] | None = None) -> list[EffectivePrompt]:
    """The prompts a run uses: every enabled one, or exactly ``names`` (enabled or not).

    Naming a disabled prompt runs it: asking for it by name is the point. An
    unknown name raises ``LookupError``.
    """
    if not names:
        return [prompt for prompt in prompts if prompt.enabled]
    by_name = {prompt.name: prompt for prompt in prompts}
    unknown = [name for name in names if name not in by_name]
    if unknown:
        raise LookupError(f"unknown fact prompt(s) {', '.join(unknown)}; known: {', '.join(by_name)}")
    return [by_name[name] for name in dict.fromkeys(names)]


@dataclass(frozen=True)
class GraphSchema:
    """Every prompt's graph block merged: the configured vertex labels by class, and the edges."""

    vertices: dict[str, GraphVertex]
    edges: tuple[GraphEdge, ...]

    def label_for(self, fact_class: str) -> str:
        """The vertex label a class's distilled facts take: its configured one, else ``Fact``."""
        vertex = self.vertices.get(fact_class)
        return vertex.label if vertex is not None else "Fact"


def graph_schema(prompts: list[EffectivePrompt]) -> GraphSchema:
    """Merge the prompts' graph blocks, enabled or not (their facts may already exist).

    Raises ``ValueError`` when a class is given two labels, a label is used for two
    classes, or a configured label is one of the projection's own.
    """
    vertices: dict[str, GraphVertex] = {}
    classes_of: dict[str, str] = {}
    edges: list[GraphEdge] = []
    for prompt in prompts:
        if prompt.graph is None:
            continue
        for vertex in prompt.graph.vertices:
            if vertex.label.lower() in {label.lower() for label in BUILTIN_VERTEX_LABELS}:
                raise ValueError(f"facts.prompts: {prompt.name!r} uses the built-in vertex label {vertex.label!r}")
            known = vertices.get(vertex.extraction_class)
            if known is not None and known.label != vertex.label:
                raise ValueError(
                    f"facts.prompts: class {vertex.extraction_class!r} is both {known.label!r} and {vertex.label!r}"
                )
            other = classes_of.get(vertex.label.lower())
            if other is not None and other != vertex.extraction_class:
                raise ValueError(
                    f"facts.prompts: vertex label {vertex.label!r} is used for {other!r} and "
                    f"{vertex.extraction_class!r}"
                )
            vertices[vertex.extraction_class] = vertex
            # Case-folded: each label gets a table of relational ids named after it in lower case.
            classes_of[vertex.label.lower()] = vertex.extraction_class
        for edge in prompt.graph.edges:
            for label in (edge.label, *edge.labels):
                if label in BUILTIN_EDGE_LABELS:
                    raise ValueError(f"facts.prompts: {prompt.name!r} uses the built-in edge label {label!r}")
            edges.append(edge)
    return GraphSchema(vertices=vertices, edges=tuple(edges))
