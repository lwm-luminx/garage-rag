"""Distilling potential facts into distinct claims (``garage cluster-facts``).

The rows of ``facts`` are *potential* facts: what one prompt extracted from one
document, each a verbatim, grounded quote. Every one already has a vector: its
chunk (``chunks.fact_id``) is embedded by the ordinary backfill under every
registered model. This pass reads those vectors under one model (the default,
unless named) and dedups in two levels
(``data/sql/015_distilled_facts.sql``, ``016_fact_dedup.sql``):

**Level 1, per document.** A document's facts of one class are compared pair by
pair (tens to hundreds of them: exact, no index). Facts with the same normalized
text, or whose cosine similarity clears the threshold, are grouped by average
linkage behind the guard below, and every member but the representative (the
longest) points at it (``facts.restates_fact_id``). A restatement is kept
verbatim and backs whatever its representative backs. A document is looked at
again only when one of its facts gains a vector.

**Level 2, per corpus.** The representatives (the *nodes*) are grouped into
distilled facts:

* A full run (``full=True``, or when the model or a parameter changed) finds
  each node's nearest neighbours, then takes nodes densest first as seeds. A
  seed's *core* is itself and its neighbours at ``seed_threshold`` or closer;
  their mean is the group's ``seed``. The group grows by nearest neighbours of
  its centroid, nearest first: a candidate joins while its similarity to the
  centroid clears ``threshold`` and the centroid it makes stays within
  ``max_drift`` of the seed, and growth stops at the first that does not
  (:func:`grow_group`). Growth repeats from the new centroid until it settles.
* An incremental run (the default) refreshes the groups that lost nodes, then
  attaches each new node to the nearest distilled fact whose centroid passes
  the same two tests, or makes it a distilled fact of its own that later nodes
  can join (:func:`attach_ok`).

Two things keep a group honest where embeddings are not:

* **The guard.** Embeddings put "42 employees" beside "45 employees" and "the
  meeting is on Tuesday" beside "the meeting is not on Tuesday". Facts that
  differ in numbers, dates or negation are never grouped (:func:`claim_signature`).
* **The local model.** Each group records how varied it is: ``spread`` (mean
  cosine distance of its nodes to the centroid), ``radius`` (the largest) and
  ``drift`` (centroid from seed). A group tighter than ``tight_similarity`` is
  accepted as it is; any other is shown to the local chat model
  (:class:`~garage_rag.enrich.generation.LocalChatModel`), which answers
  whether the facts state one claim and, if so, states it once
  (``statement_generated``). A group with a communication among its members
  is only sent to a loopback model; like a group no model was asked about, it
  is stated by its representative's text.

Potential facts are never changed: they are only linked. A distilled fact's
vector in the clustering model's ``fact_emb_`` table is its centroid (with its
``seed``); ``garage backfill`` gives it one under every other model, the mean
of its nodes' vectors there.
"""

from __future__ import annotations

import hashlib
import logging
import math
import re
from collections.abc import Callable, Iterable, Sequence
from dataclasses import dataclass, field

from sqlalchemy import text
from sqlalchemy.orm import Session

from garage_rag.db.emb_tables import assert_safe_table, ensure_fact_table, fact_table_name, stored_plan
from garage_rag.db.engine import apply_search_tuning
from garage_rag.db.models import CorpusClass, EmbeddingModel
from garage_rag.db.registry import column_type_sql, distance_operator
from garage_rag.net import egress

log = logging.getLogger(__name__)

# Nodes per neighbour query.
NEIGHBOR_BATCH = 256
# Documents per level-1 query.
DOCUMENT_BATCH = 200
# Defaults of the ``facts.cluster_*`` limits (see ClusterParams and the config):
# the largest connected group compared pair by pair, facts shown to the model
# for one group, candidates fetched around a growing centroid and growth
# rounds, and distilled facts a new node is tried against.
MAX_PAIRWISE = 300
MAX_DISTILL_FACTS = 20
GROWTH_NEIGHBORS = 50
GROWTH_ROUNDS = 4
ATTACH_CANDIDATES = 5

# ---------------------------------------------------------------------------
# The guard: what an embedding cannot tell apart


_NUMBER = re.compile(r"\d+(?:[.,:/-]\d+)*")
_WORD = re.compile(r"[a-z]+(?:'[a-z]+)?")
_TEMPORAL = frozenset(
    [
        "january",
        "february",
        "march",
        "april",
        "june",
        "july",
        "august",
        "september",
        "october",
        "november",
        "december",
        "jan",
        "feb",
        "mar",
        "apr",
        "jun",
        "jul",
        "aug",
        "sep",
        "sept",
        "oct",
        "nov",
        "dec",
        "monday",
        "tuesday",
        "wednesday",
        "thursday",
        "friday",
        "saturday",
        "sunday",
        "mon",
        "tue",
        "tues",
        "wed",
        "thu",
        "thur",
        "thurs",
        "fri",
        "yesterday",
        "today",
        "tomorrow",
        "tonight",
        "morning",
        "afternoon",
        "evening",
        "night",
        "before",
        "after",
        "earlier",
        "later",
    ]
)
_NEGATION = frozenset({"not", "no", "never", "none", "neither", "nor", "without", "cannot", "nobody", "nothing"})


@dataclass(frozen=True)
class ClaimSignature:
    """What a fact says about quantities, time and negation."""

    numbers: frozenset[str]
    temporal: frozenset[str]
    negated: bool


def claim_signature(fact: str) -> ClaimSignature:
    """The parts of ``fact`` that must agree before it can be grouped with another.

    Numbers are compared as written, minus thousands separators ("1,000" and
    "1000" agree); month, weekday and relative-time words must be the same
    set; and either both facts are negated or neither is.
    """
    lowered = fact.lower()
    numbers = frozenset(n.replace(",", "") for n in _NUMBER.findall(lowered))
    words = _WORD.findall(lowered)
    temporal = frozenset(w for w in words if w in _TEMPORAL)
    negated = any(w in _NEGATION or w.endswith("n't") for w in words)
    return ClaimSignature(numbers=numbers, temporal=temporal, negated=negated)


# ---------------------------------------------------------------------------
# Grouping


def pair(a: int, b: int) -> tuple[int, int]:
    return (a, b) if a < b else (b, a)


def connected_groups(ids: Iterable[int], edges: Iterable[tuple[int, int]]) -> list[list[int]]:
    """The connected components of ``edges`` over ``ids``, each sorted, with more than one member."""
    parent: dict[int, int] = {i: i for i in ids}

    def find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for a, b in edges:
        if a in parent and b in parent:
            ra, rb = find(a), find(b)
            if ra != rb:
                parent[max(ra, rb)] = min(ra, rb)
    groups: dict[int, list[int]] = {}
    for i in parent:
        groups.setdefault(find(i), []).append(i)
    return sorted((sorted(g) for g in groups.values() if len(g) > 1), key=lambda g: g[0])


def average_linkage(ids: Sequence[int], similarity: dict[tuple[int, int], float], threshold: float) -> list[list[int]]:
    """Agglomerative clustering of ``ids``: repeatedly merge the two clusters whose average
    pairwise similarity is highest, while it is at least ``threshold``.

    ``similarity`` is keyed by :func:`pair`; a missing pair counts as 0, so an
    unknown pair can only keep clusters apart. Returns the clusters with more
    than one member, each sorted.
    """
    clusters: list[list[int]] = [[i] for i in sorted(ids)]

    def average(a: list[int], b: list[int]) -> float:
        total = sum(similarity.get(pair(x, y), 0.0) for x in a for y in b)
        return total / (len(a) * len(b))

    while len(clusters) > 1:
        best = (-1.0, -1, -1)
        for i in range(len(clusters)):
            for j in range(i + 1, len(clusters)):
                score = average(clusters[i], clusters[j])
                if score > best[0]:
                    best = (score, i, j)
        score, i, j = best
        if score < threshold:
            break
        clusters[i] = sorted(clusters[i] + clusters[j])
        del clusters[j]
    return sorted((c for c in clusters if len(c) > 1), key=lambda c: c[0])


def guarded_clusters(
    group: Sequence[int],
    texts: dict[int, str],
    similarity: dict[tuple[int, int], float],
    threshold: float,
) -> list[list[int]]:
    """Split ``group`` by :func:`claim_signature`, then cluster each part by average linkage."""
    parts: dict[ClaimSignature, list[int]] = {}
    for fact_id in group:
        parts.setdefault(claim_signature(texts[fact_id]), []).append(fact_id)
    clusters: list[list[int]] = []
    for part in parts.values():
        if len(part) > 1:
            clusters.extend(average_linkage(part, similarity, threshold))
    return sorted(clusters, key=lambda c: c[0])


def representative(members: Sequence[int], texts: dict[int, str]) -> int:
    """The member whose text stands for the cluster: the longest, the oldest on ties."""
    return min(members, key=lambda fact_id: (-len(texts[fact_id]), fact_id))


def members_sha256(members: Iterable[int]) -> bytes:
    return hashlib.sha256(",".join(str(i) for i in sorted(members)).encode()).digest()


def centrality(members: Sequence[int], similarity: dict[tuple[int, int], float]) -> dict[int, float]:
    """Each member's average similarity to the other members."""
    return {m: sum(similarity.get(pair(m, o), 0.0) for o in members if o != m) / (len(members) - 1) for m in members}


# ---------------------------------------------------------------------------
# Level 1: restatements within one document

_SPACE = re.compile(r"\s+")


def normalize_fact(fact: str) -> str:
    """``fact`` casefolded, with runs of white space collapsed and trailing punctuation dropped."""
    return _SPACE.sub(" ", fact.casefold()).strip().rstrip(".!?;:,").strip()


def document_restatements(
    ids: Sequence[int],
    texts: dict[int, str],
    similarity: dict[tuple[int, int], float],
    threshold: float,
) -> dict[int, tuple[int, float]]:
    """``{restatement: (representative, similarity)}`` among one document's facts of one class.

    Facts with the same :func:`normalized <normalize_fact>` text count as a pair
    at similarity 1. ``similarity`` should hold every pair of a connected group
    (missing pairs count as 0, which only keeps facts apart).
    """
    sims = dict(similarity)
    by_text: dict[str, list[int]] = {}
    for fact_id in ids:
        by_text.setdefault(normalize_fact(texts[fact_id]), []).append(fact_id)
    for same in by_text.values():
        for i, a in enumerate(same):
            for b in same[i + 1 :]:
                sims[pair(a, b)] = 1.0
    edges = [p for p, s in sims.items() if s >= threshold]
    restates: dict[int, tuple[int, float]] = {}
    for group in connected_groups(ids, edges):
        for members in guarded_clusters(group, texts, sims, threshold):
            rep = representative(members, texts)
            for m in members:
                if m != rep:
                    restates[m] = (rep, sims.get(pair(m, rep), 0.0))
    return restates


# ---------------------------------------------------------------------------
# Level 2: growing a group around a seed

Vector = list[float]


def parse_vector(literal: str) -> Vector:
    """A pgvector text value (``[1,2,3]``) as floats."""
    return [float(x) for x in literal.strip("[]").split(",")] if literal.strip("[]") else []


def vector_literal(vector: Sequence[float]) -> str:
    return "[" + ",".join(f"{x:.7g}" for x in vector) + "]"


def mean_vector(vectors: Sequence[Sequence[float]]) -> Vector:
    n = len(vectors)
    return [sum(column) / n for column in zip(*vectors, strict=True)]


def cosine(a: Sequence[float], b: Sequence[float]) -> float:
    dot = sum(x * y for x, y in zip(a, b, strict=True))
    norm = math.sqrt(sum(x * x for x in a)) * math.sqrt(sum(y * y for y in b))
    return dot / norm if norm else 0.0


def added(centroid: Sequence[float], count: int, vector: Sequence[float]) -> Vector:
    """The centroid of ``count`` vectors averaging ``centroid``, with ``vector`` added."""
    return [(c * count + v) / (count + 1) for c, v in zip(centroid, vector, strict=True)]


@dataclass(frozen=True)
class Variability:
    """How far a group's nodes stray from its centroid, and its centroid from its seed (cosine distances)."""

    spread: float
    radius: float
    drift: float


def variability(vectors: Sequence[Sequence[float]], centroid: Sequence[float], seed: Sequence[float]) -> Variability:
    distances = [1.0 - cosine(v, centroid) for v in vectors]
    return Variability(
        spread=max(0.0, sum(distances) / len(distances)),
        radius=max(0.0, max(distances)),
        drift=max(0.0, 1.0 - cosine(centroid, seed)),
    )


def attach_ok(
    vector: Sequence[float],
    centroid: Sequence[float],
    seed: Sequence[float],
    count: int,
    *,
    threshold: float,
    max_drift: float,
) -> tuple[float, Vector] | None:
    """``(similarity, new centroid)`` if ``vector`` may join a group of ``count`` at ``centroid``, else None.

    It may when it is at least ``threshold`` similar to the centroid and the
    centroid it makes stays within ``max_drift`` of the group's ``seed``.
    """
    similarity = cosine(vector, centroid)
    if similarity < threshold:
        return None
    moved = added(centroid, count, vector)
    if 1.0 - cosine(moved, seed) > max_drift:
        return None
    return similarity, moved


@dataclass
class Grown:
    members: list[int]
    seed: Vector
    centroid: Vector


def grow_group(
    core: Sequence[int],
    vectors: dict[int, Vector],
    signature: Callable[[int], ClaimSignature],
    knn: Callable[[Vector], Sequence[int]],
    taken: set[int],
    *,
    threshold: float,
    max_drift: float,
    rounds: int = GROWTH_ROUNDS,
) -> Grown:
    """Grow a group from ``core`` (its seed first) until its centroid settles.

    ``knn(centroid)`` returns candidate nodes nearest first, with their vectors
    in ``vectors``. Candidates in ``taken`` (other groups) or with another
    claim signature are passed over; the walk stops at the first candidate
    :func:`attach_ok` refuses, since every later one is further away. Members
    that the settled centroid has left below ``threshold`` are let go (never the
    seed fact itself).
    """
    members = list(core)
    seed = mean_vector([vectors[m] for m in members])
    centroid = seed
    wanted = signature(members[0])
    for _ in range(rounds):
        changed = False
        for candidate in knn(centroid):
            if candidate in taken or candidate in members or signature(candidate) != wanted:
                continue
            accepted = attach_ok(
                vectors[candidate], centroid, seed, len(members), threshold=threshold, max_drift=max_drift
            )
            if accepted is None:
                break
            members.append(candidate)
            centroid = accepted[1]
            changed = True
        kept = [m for i, m in enumerate(members) if i == 0 or cosine(vectors[m], centroid) >= threshold]
        if len(kept) != len(members):
            members = kept
            centroid = mean_vector([vectors[m] for m in members])
            changed = True
        if not changed:
            break
    return Grown(members=members, seed=seed, centroid=centroid)


def needs_model(spread: float, tight_similarity: float) -> bool:
    """Whether a group is loose enough that the local model should confirm it."""
    return spread > 1.0 - tight_similarity


# ---------------------------------------------------------------------------
# Distillation


DISTILL_SYSTEM_PROMPT = (
    "You compare short statements that were extracted from one person's documents. "
    "You answer only from the statements themselves."
)


def distill_prompt(statements: Sequence[str]) -> str:
    listed = "\n".join(f"{i}. {s}" for i, s in enumerate(statements, start=1))
    return (
        f"Statements:\n{listed}\n\n"
        "Do all of these statements state the same claim, with no difference in who, what, when, "
        "where or how much? Answer YES or NO on the first line. If YES, write on the second line "
        "one sentence that states the claim, using only information present in the statements."
    )


def parse_distill_reply(reply: str) -> tuple[bool, str | None]:
    """``(same, statement)`` from the model's reply. Anything but a leading YES is a no."""
    lines = [line.strip().strip("*#>_ ").strip() for line in reply.strip().splitlines()]
    lines = [line for line in lines if line]
    if not lines or not lines[0].upper().startswith("YES"):
        return False, None
    # "YES: <sentence>" on one line is accepted too.
    rest = lines[0][3:].lstrip("*_ :.-,").strip()
    statement = rest or (lines[1] if len(lines) > 1 else "")
    if statement.lower().startswith("statement:"):
        statement = statement[len("statement:") :]
    statement = statement.strip().strip('"').strip()
    return True, statement or None


class Distiller:
    """Confirms a cluster and states its claim with the local chat model."""

    def __init__(self, model=None) -> None:
        from garage_rag.enrich.generation import LocalChatModel

        self.model = model or LocalChatModel()

    @property
    def model_id(self) -> str:
        return f"{self.model.provider}/{self.model.model_ref}"

    def may_send(self, corpus_classes: Iterable[str]) -> bool:
        """Whether facts of these classes may go to the model's host."""
        if CorpusClass.COMMUNICATION.value not in set(corpus_classes):
            return True
        try:
            egress.check_destination(self.model.host, purpose="cluster-facts", corpus_class=CorpusClass.COMMUNICATION)
        except egress.EgressBlocked:
            return False
        return True

    def distill(self, statements: Sequence[str]) -> tuple[bool, str | None]:
        reply = self.model.chat(
            [
                {"role": "system", "content": DISTILL_SYSTEM_PROMPT},
                {"role": "user", "content": distill_prompt(statements)},
            ],
            max_tokens=200,
            temperature=0.0,
        )
        return parse_distill_reply(reply)


# ---------------------------------------------------------------------------
# The pass


@dataclass(frozen=True)
class ClusterParams:
    """The knobs of one run; see the module docstring and ``facts.cluster_*`` in the config."""

    threshold: float
    neighbors: int
    seed_threshold: float
    max_drift: float
    tight_similarity: float
    growth_neighbors: int = GROWTH_NEIGHBORS
    growth_rounds: int = GROWTH_ROUNDS
    attach_candidates: int = ATTACH_CANDIDATES
    distill_facts: int = MAX_DISTILL_FACTS
    max_pairwise: int = MAX_PAIRWISE

    def document_key(self, slug: str) -> str:
        return f"{slug};t={self.threshold:g}"

    def corpus_key(self) -> str:
        # What shapes the groups; a change regroups the corpus. The rest only
        # decides what the model is asked or how many candidates a new fact tries.
        return (
            f"t={self.threshold:g};s={self.seed_threshold:g};d={self.max_drift:g}"
            f";g={self.growth_neighbors};r={self.growth_rounds}"
        )


@dataclass
class ClusterProgress:
    """Where a run is. ``phase`` is ``documents``, ``neighbors``, ``grow``, ``attach``, ``distill`` or ``done``."""

    phase: str = "documents"
    # A full run regroups the corpus; an incremental one places what is new.
    full: bool = False
    facts: int = 0
    # Potential facts with no vector under the model yet (run the backfill); each stays alone.
    unembedded: int = 0
    # Level 1: documents compared, and potential facts restating another in their document.
    documents: int = 0
    restatements: int = 0
    # Level 2: representatives placed, and those whose neighbours were fetched or tried.
    nodes: int = 0
    scanned: int = 0
    # Groups grown (full run); new nodes that joined a distilled fact (incremental).
    candidates: int = 0
    attached: int = 0
    # Groups tight enough to keep without asking the model.
    accepted: int = 0
    distilled: int = 0
    to_distill: int = 0
    # Distilled facts backing more than one potential fact, and how many they back.
    clusters: int = 0
    clustered_facts: int = 0
    # Every distilled fact, groups and single facts alike.
    distilled_facts: int = 0
    kept: int = 0
    dissolved: int = 0
    failed: int = 0
    withheld: int = 0
    errors: list[str] = field(default_factory=list)

    @property
    def message(self) -> str:
        """One line on where the run is, for a progress display; empty for ``done``."""
        return {
            "documents": f"comparing each document's facts: {self.documents:,} documents",
            "neighbors": f"finding neighbours: {self.scanned:,}/{self.nodes:,} facts",
            "grow": f"growing groups: {self.candidates:,}",
            "attach": f"placing new facts: {self.scanned:,}/{self.nodes:,}",
            "distill": f"asking the model about group {self.distilled:,}",
        }.get(self.phase, "")


def _iterative_scan(session: Session) -> None:
    """Let a filtered HNSW scan keep going until it finds enough fact rows (pgvector 0.8+)."""
    try:
        with session.begin_nested():
            session.execute(text("SET LOCAL hnsw.iterative_scan = relaxed_order"))
    except Exception:  # noqa: BLE001 - older pgvector has no such setting; recall is then ef_search's
        log.debug("hnsw.iterative_scan is not available")


def _has_vector(table: str, alias: str = "f") -> str:
    return f"EXISTS (SELECT 1 FROM chunks hv JOIN {table} he ON he.chunk_id = hv.id WHERE hv.fact_id = {alias}.id)"


@dataclass
class _Statement:
    text: str
    generated: bool
    distill_model: str | None


class _Pass:
    def __init__(
        self,
        session: Session,
        model: EmbeddingModel,
        params: ClusterParams,
        distiller: Distiller | None,
        progress: Callable[[ClusterProgress], None] | None,
    ) -> None:
        self.session = session
        self.model = model
        self.params = params
        self.distiller = distiller
        self.progress = progress
        self.state = ClusterProgress()
        self.table = assert_safe_table(model.table_name)
        self.fact_table = ensure_fact_table(session, model)
        self.coltype = column_type_sql(stored_plan(model))
        # Order by the model's own distance, so its index serves the scan; judge
        # similarity by cosine regardless, so one threshold means one thing. The
        # binary-quantized models index a quantization, not the column: their scan
        # is exact and unindexed.
        self.op = distance_operator(model.distance) if model.index_kind != "hnsw_bq" else "<=>"
        self.texts: dict[int, str] = {}
        self.fact_class: dict[int, str] = {}
        self.corpus_class: dict[int, str] = {}
        self.document: dict[int, int] = {}
        self.vectors: dict[int, Vector] = {}
        self._signatures: dict[int, ClaimSignature] = {}

    # -- plumbing -------------------------------------------------------------

    def report(self, phase: str) -> None:
        self.state.phase = phase
        if self.progress is not None:
            self.progress(self.state)

    def signature(self, fact_id: int) -> ClaimSignature:
        if fact_id not in self._signatures:
            self._signatures[fact_id] = claim_signature(self.texts[fact_id])
        return self._signatures[fact_id]

    def load_vectors(self, ids: Iterable[int]) -> None:
        missing = [i for i in ids if i not in self.vectors]
        for start in range(0, len(missing), 1000):
            for fid, literal in self.session.execute(
                text(
                    f"SELECT c.fact_id, e.embedding::text FROM chunks c JOIN {self.table} e ON e.chunk_id = c.id"
                    " WHERE c.fact_id = ANY(CAST(:ids AS bigint[]))"
                ),
                {"ids": missing[start : start + 1000]},
            ).all():
                self.vectors[int(fid)] = parse_vector(literal)

    def cast(self, param: str) -> str:
        return f"CAST(:{param} AS {self.coltype})"

    def load_facts(self) -> None:
        for fid, doc, fact, fact_class, corpus_class in self.session.execute(
            text(
                "SELECT f.id, f.document_id, f.fact, f.fact_class, d.corpus_class::text"
                " FROM facts f JOIN documents d ON d.id = f.document_id ORDER BY f.id"
            )
        ).all():
            fid = int(fid)
            self.texts[fid] = fact
            self.document[fid] = int(doc)
            self.fact_class[fid] = fact_class
            self.corpus_class[fid] = corpus_class
        self.state.facts = len(self.texts)
        self.state.unembedded = int(
            self.session.execute(text(f"SELECT count(*) FROM facts f WHERE NOT {_has_vector(self.table)}")).scalar_one()
        )

    def other_fact_tables(self) -> list[str]:
        tables = []
        for (name,) in self.session.execute(
            text("SELECT table_name FROM embedding_models WHERE id <> :id"), {"id": self.model.id}
        ).all():
            table = fact_table_name(name)
            if self.session.execute(text("SELECT to_regclass(:t) IS NOT NULL"), {"t": table}).scalar():
                tables.append(table)
        return tables

    def stale_elsewhere(self, ids: Sequence[int]) -> None:
        """Drop other models' vectors for distilled facts whose nodes changed; the backfill remakes them."""
        if not ids:
            return
        for table in self.other_fact_tables():
            self.session.execute(
                text(f"DELETE FROM {table} WHERE distilled_fact_id = ANY(CAST(:ids AS bigint[]))"), {"ids": list(ids)}
            )

    # -- level 1 --------------------------------------------------------------

    def restate_documents(self, full: bool) -> None:
        """Link each document's restatements to their representative; see :func:`document_restatements`."""
        key = self.params.document_key(self.model.slug)
        if full:
            docs = sorted(set(self.document.values()))
        else:
            docs = [
                int(d)
                for (d,) in self.session.execute(
                    text(
                        f"""
                        SELECT DISTINCT f.document_id FROM facts f
                        WHERE (f.dedup_key IS NULL AND {_has_vector(self.table)})
                           OR (f.dedup_key IS NOT NULL AND f.dedup_key <> :key)
                           -- a representative deleted from under its restatement
                           OR (f.restates_fact_id IS NULL AND f.restates_similarity IS NOT NULL)
                        ORDER BY 1
                        """
                    ),
                    {"key": key},
                ).all()
            ]
            if docs:
                # Their facts are placed afresh at level 2.
                self.session.execute(
                    text(
                        "UPDATE facts SET distilled_fact_id = NULL, distilled_similarity = NULL"
                        " WHERE document_id = ANY(CAST(:docs AS bigint[]))"
                    ),
                    {"docs": docs},
                )
        by_doc: dict[int, list[int]] = {}
        for fid, doc in self.document.items():
            by_doc.setdefault(doc, []).append(fid)
        above = text(
            f"""
            WITH v AS (
                SELECT c.fact_id, f.document_id, f.fact_class, e.embedding
                FROM chunks c JOIN facts f ON f.id = c.fact_id JOIN {self.table} e ON e.chunk_id = c.id
                WHERE f.document_id = ANY(CAST(:docs AS bigint[]))
            )
            SELECT a.fact_id, b.fact_id, 1 - (a.embedding <=> b.embedding)
            FROM v a JOIN v b ON b.document_id = a.document_id AND b.fact_class = a.fact_class AND a.fact_id < b.fact_id
            WHERE 1 - (a.embedding <=> b.embedding) >= :threshold
            """
        )
        pairwise = text(_pairwise_sql(self.table))
        reset = text(
            f"""
            UPDATE facts f SET restates_fact_id = NULL, restates_similarity = NULL,
                               dedup_key = CASE WHEN {_has_vector(self.table)} THEN :key END
            WHERE f.document_id = ANY(CAST(:docs AS bigint[]))
            """
        )
        link = text("UPDATE facts SET restates_fact_id = :rep, restates_similarity = :similarity WHERE id = :id")
        for start in range(0, len(docs), DOCUMENT_BATCH):
            batch = docs[start : start + DOCUMENT_BATCH]
            # Above-threshold pairs, by document and class.
            found: dict[tuple[int, str], dict[tuple[int, int], float]] = {}
            for a, b, sim in self.session.execute(above, {"docs": batch, "threshold": self.params.threshold}).all():
                a, b = int(a), int(b)
                found.setdefault((self.document[a], self.fact_class[a]), {})[pair(a, b)] = float(sim)
            links: list[dict[str, object]] = []
            for doc in batch:
                by_class: dict[str, list[int]] = {}
                for fid in by_doc.get(doc, []):
                    by_class.setdefault(self.fact_class[fid], []).append(fid)
                for fact_class, ids in by_class.items():
                    if len(ids) < 2:
                        continue
                    sims = found.get((doc, fact_class), {})
                    for group in connected_groups(ids, sims):
                        if 2 < len(group) <= self.params.max_pairwise:
                            for a, b, sim in self.session.execute(pairwise, {"ids": group}).all():
                                sims[pair(int(a), int(b))] = float(sim)
                    for fid, (rep, sim) in document_restatements(ids, self.texts, sims, self.params.threshold).items():
                        links.append({"id": fid, "rep": rep, "similarity": sim})
            self.session.execute(reset, {"docs": batch, "key": key})
            if links:
                self.session.execute(link, links)
            self.state.documents += len(batch)
            self.report("documents")
        self.state.restatements = int(
            self.session.execute(text("SELECT count(*) FROM facts WHERE restates_fact_id IS NOT NULL")).scalar_one()
        )

    # -- level 2: deciding and writing groups ----------------------------------

    def confirm(self, members: Sequence[int], centroid: Vector, spread: float) -> _Statement | None:
        """How a group is stated, or None when the model says its members state different claims."""
        stated = _Statement(self.texts[representative(members, self.texts)], False, None)
        if not needs_model(spread, self.params.tight_similarity):
            self.state.accepted += 1
            return stated
        if self.distiller is None:
            return stated
        shown = sorted(members, key=lambda m: (-cosine(self.vectors[m], centroid), m))[: self.params.distill_facts]
        self.state.distilled += 1
        if not self.distiller.may_send(self.corpus_class[m] for m in shown):
            self.state.withheld += 1
            return stated
        try:
            same, statement = self.distiller.distill([self.texts[m] for m in shown])
        except Exception as exc:  # noqa: BLE001 - counted; the group stays, stated by its representative
            self.state.failed += 1
            if len(self.state.errors) < 5:
                self.state.errors.append(str(exc))
            return stated
        finally:
            self.report("distill")
        if not same:
            self.state.dissolved += 1
            return None
        if statement:
            return _Statement(statement, True, self.distiller.model_id)
        return _Statement(stated.text, False, self.distiller.model_id)

    def write_group(self, members: Sequence[int], centroid: Vector, seed: Vector, statement: _Statement) -> int:
        var = variability([self.vectors[m] for m in members], centroid, seed)
        did = self.session.execute(
            text(
                """
                INSERT INTO distilled_facts (fact_class, statement, statement_generated, representative_fact_id,
                                             members_sha256, model_slug, threshold, distill_model,
                                             nodes, spread, drift, radius)
                VALUES (:fact_class, :statement, :generated, :rep, :sha, :slug, :threshold, :distill_model,
                        :nodes, :spread, :drift, :radius)
                RETURNING id
                """
            ),
            {
                "fact_class": self.fact_class[members[0]],
                "statement": statement.text,
                "generated": statement.generated,
                "rep": representative(members, self.texts),
                "sha": members_sha256(members),
                "slug": self.model.slug,
                "threshold": self.params.threshold,
                "distill_model": statement.distill_model,
                "nodes": len(members),
                "spread": var.spread,
                "drift": var.drift,
                "radius": var.radius,
            },
        ).scalar_one()
        self.session.execute(
            text(
                f"INSERT INTO {self.fact_table} (distilled_fact_id, embedding, seed)"
                f" VALUES (:id, {self.cast('centroid')}, {self.cast('seed')})"
            ),
            {"id": did, "centroid": vector_literal(centroid), "seed": vector_literal(seed)},
        )
        self.link(did, members, centroid)
        return int(did)

    def link(self, did: int, members: Sequence[int], centroid: Vector) -> None:
        self.session.execute(
            text("UPDATE facts SET distilled_fact_id = :did, distilled_similarity = :similarity WHERE id = :id"),
            [{"did": did, "similarity": cosine(self.vectors[m], centroid), "id": m} for m in members],
        )

    def write_single(self, fact_id: int) -> int:
        did = self.session.execute(
            text(
                """
                INSERT INTO distilled_facts (fact_class, statement, representative_fact_id, members_sha256,
                                             nodes, spread, drift, radius)
                VALUES (:fact_class, :statement, :id, :sha, 1, 0, 0, 0)
                RETURNING id
                """
            ),
            {
                "fact_class": self.fact_class[fact_id],
                "statement": self.texts[fact_id],
                "id": fact_id,
                "sha": members_sha256([fact_id]),
            },
        ).scalar_one()
        vector = vector_literal(self.vectors[fact_id])
        self.session.execute(
            text(
                f"INSERT INTO {self.fact_table} (distilled_fact_id, embedding, seed)"
                f" VALUES (:id, {self.cast('v')}, {self.cast('v')})"
            ),
            {"id": did, "v": vector},
        )
        self.session.execute(
            text("UPDATE facts SET distilled_fact_id = :did, distilled_similarity = NULL WHERE id = :id"),
            {"did": did, "id": fact_id},
        )
        return int(did)

    def nodes(self) -> list[int]:
        return [
            int(i)
            for (i,) in self.session.execute(
                text(
                    f"SELECT f.id FROM facts f WHERE f.restates_fact_id IS NULL AND {_has_vector(self.table)}"
                    " ORDER BY f.id"
                )
            ).all()
        ]

    def knn_nodes(self, centroid: Vector, fact_class: str, k: int) -> list[int]:
        rows = self.session.execute(
            text(
                f"""
                SELECT c.fact_id, e.embedding::text
                FROM {self.table} e JOIN chunks c ON c.id = e.chunk_id JOIN facts f ON f.id = c.fact_id
                WHERE f.fact_class = :fact_class AND f.restates_fact_id IS NULL
                ORDER BY e.embedding {self.op} {self.cast("v")}
                LIMIT :k
                """
            ),
            {"fact_class": fact_class, "v": vector_literal(centroid), "k": k},
        ).all()
        found = []
        for fid, literal in rows:
            fid = int(fid)
            self.vectors.setdefault(fid, parse_vector(literal))
            found.append(fid)
        return found

    # -- level 2: a full run ----------------------------------------------------

    def regroup(self) -> None:
        previous = {
            bytes(sha): _Statement(statement, bool(generated), distill_model)
            for sha, statement, generated, distill_model in self.session.execute(
                text(
                    "SELECT members_sha256, statement, statement_generated, distill_model"
                    " FROM distilled_facts WHERE model_slug IS NOT NULL"
                )
            ).all()
        }
        self.session.execute(text("DELETE FROM distilled_facts"))

        nodes = self.nodes()
        self.state.nodes = len(nodes)
        self.report("neighbors")
        neighbors: dict[int, list[tuple[int, float]]] = {}
        neighbor_sql = text(_neighbor_sql(self.table, self.op))
        for start in range(0, len(nodes), NEIGHBOR_BATCH):
            batch = nodes[start : start + NEIGHBOR_BATCH]
            for a, b, sim in self.session.execute(neighbor_sql, {"ids": batch, "k": self.params.neighbors}).all():
                if sim is not None and float(sim) >= self.params.threshold:
                    a, b, sim = int(a), int(b), float(sim)
                    neighbors.setdefault(a, []).append((b, sim))
                    neighbors.setdefault(b, []).append((a, sim))
            self.state.scanned += len(batch)
            self.report("neighbors")

        # Densest first: a seed with many close neighbours is likelier the middle of a claim than its edge.
        seeds = sorted(neighbors, key=lambda n: (-len({b for b, _ in neighbors[n]}), n))
        taken: set[int] = set()
        grown: list[Grown] = []
        for seed in seeds:
            if seed in taken:
                continue
            wanted = self.signature(seed)
            close = sorted(neighbors[seed], key=lambda nb: (-nb[1], nb[0]))
            core = [seed]
            for b, sim in close:
                if (
                    sim >= self.params.seed_threshold
                    and b not in taken
                    and b not in core
                    and self.signature(b) == wanted
                ):
                    core.append(b)
            self.load_vectors(core)
            fact_class = self.fact_class[seed]
            group = grow_group(
                core,
                self.vectors,
                self.signature,
                lambda centroid, fact_class=fact_class: self.knn_nodes(
                    centroid, fact_class, self.params.growth_neighbors
                ),
                taken,
                threshold=self.params.threshold,
                max_drift=self.params.max_drift,
                rounds=self.params.growth_rounds,
            )
            if len(group.members) > 1:
                taken.update(group.members)
                grown.append(group)
                self.state.candidates = len(grown)
                self.report("grow")

        self.state.to_distill = len(grown)
        for group in grown:
            members = sorted(group.members)
            spread = variability([self.vectors[m] for m in members], group.centroid, group.seed).spread
            statement = previous.get(members_sha256(members))
            if statement is not None:
                self.state.kept += 1
            else:
                statement = self.confirm(members, group.centroid, spread)
            if statement is not None:
                self.write_group(members, group.centroid, group.seed, statement)

        for fact_id in nodes:
            if fact_id not in taken:
                self.load_vectors([fact_id])
                self.write_single(fact_id)

    # -- level 2: an incremental run ---------------------------------------------

    def refresh(self) -> None:
        """Re-centre the distilled facts that lost nodes (a document re-extracted or re-compared)."""
        changed = self.session.execute(
            text(
                """
                SELECT df.id, df.nodes, df.model_slug IS NOT NULL,
                       coalesce(array_agg(f.id ORDER BY f.id) FILTER (WHERE f.id IS NOT NULL), '{}')
                FROM distilled_facts df
                LEFT JOIN facts f ON f.distilled_fact_id = df.id AND f.restates_fact_id IS NULL
                GROUP BY df.id
                HAVING count(f.id) IS DISTINCT FROM df.nodes
                """
            )
        ).all()
        stale: list[int] = []
        for did, _, grouped, members in changed:
            did, members = int(did), [int(m) for m in members]
            if not members:
                self.session.execute(text("DELETE FROM distilled_facts WHERE id = :id"), {"id": did})
                continue
            self.load_vectors(members)
            members = [m for m in members if m in self.vectors]
            if not members:
                continue
            stale.append(did)
            row = self.session.execute(
                text(f"SELECT seed::text FROM {self.fact_table} WHERE distilled_fact_id = :id"), {"id": did}
            ).first()
            centroid = mean_vector([self.vectors[m] for m in members])
            seed = parse_vector(row[0]) if row is not None and row[0] is not None else centroid
            if len(members) == 1:
                seed = centroid
            var = variability([self.vectors[m] for m in members], centroid, seed)
            single = len(members) == 1
            self.session.execute(
                text(
                    """
                    UPDATE distilled_facts SET
                        nodes = :nodes, spread = :spread, drift = :drift, radius = :radius,
                        members_sha256 = :sha, representative_fact_id = :rep,
                        statement = CASE WHEN :single THEN :text ELSE statement END,
                        statement_generated = statement_generated AND NOT :single,
                        model_slug = CASE WHEN :single THEN NULL ELSE model_slug END,
                        threshold = CASE WHEN :single THEN NULL ELSE threshold END,
                        distill_model = CASE WHEN :single THEN NULL ELSE distill_model END
                    WHERE id = :id
                    """
                ),
                {
                    "id": did,
                    "nodes": len(members),
                    "spread": var.spread,
                    "drift": var.drift,
                    "radius": var.radius,
                    "sha": members_sha256(members),
                    "rep": representative(members, self.texts),
                    "single": single,
                    "text": self.texts[members[0]],
                },
            )
            self.upsert_vector(did, centroid, seed)
            if not single:
                self.link(did, members, centroid)
            elif grouped:
                self.session.execute(
                    text("UPDATE facts SET distilled_similarity = NULL WHERE id = :id"), {"id": members[0]}
                )
        self.stale_elsewhere(stale)

    def upsert_vector(self, did: int, centroid: Vector, seed: Vector) -> None:
        self.session.execute(
            text(
                f"""
                INSERT INTO {self.fact_table} (distilled_fact_id, embedding, seed)
                VALUES (:id, {self.cast("centroid")}, {self.cast("seed")})
                ON CONFLICT (distilled_fact_id) DO UPDATE
                    SET embedding = EXCLUDED.embedding, seed = EXCLUDED.seed, embedded_at = now()
                """
            ),
            {"id": did, "centroid": vector_literal(centroid), "seed": vector_literal(seed)},
        )

    def place(self) -> None:
        """Attach each new node to the nearest distilled fact that takes it, or make it one of its own."""
        # A distilled fact of one member made before its fact had a vector here is made again.
        self.session.execute(
            text(
                f"""
                DELETE FROM distilled_facts df
                WHERE df.model_slug IS NULL
                  AND NOT EXISTS (SELECT 1 FROM {self.fact_table} fe WHERE fe.distilled_fact_id = df.id
                                                                     AND fe.seed IS NOT NULL)
                  AND EXISTS (SELECT 1 FROM facts f WHERE f.id = df.representative_fact_id
                                                     AND {_has_vector(self.table)})
                """
            )
        )
        new = [
            int(i)
            for (i,) in self.session.execute(
                text(
                    f"SELECT f.id FROM facts f WHERE f.distilled_fact_id IS NULL AND f.restates_fact_id IS NULL"
                    f" AND {_has_vector(self.table)} ORDER BY f.id"
                )
            ).all()
        ]
        self.state.nodes = len(new)
        self.load_vectors(new)
        candidates = text(
            f"""
            SELECT fe.distilled_fact_id, fe.embedding::text, fe.seed::text, df.representative_fact_id
            FROM {self.fact_table} fe JOIN distilled_facts df ON df.id = fe.distilled_fact_id
            WHERE df.fact_class = :fact_class AND fe.seed IS NOT NULL
            ORDER BY fe.embedding {self.op} {self.cast("v")}
            LIMIT :k
            """
        )
        group_nodes = text("SELECT id FROM facts WHERE distilled_fact_id = :id AND restates_fact_id IS NULL")
        for fact_id in new:
            vector = self.vectors[fact_id]
            placed = False
            for did, centroid, seed, rep in self.session.execute(
                candidates,
                {
                    "fact_class": self.fact_class[fact_id],
                    "v": vector_literal(vector),
                    "k": self.params.attach_candidates,
                },
            ).all():
                if rep is None or self.signature(int(rep)) != self.signature(fact_id):
                    continue
                members = [int(m) for (m,) in self.session.execute(group_nodes, {"id": did}).all()]
                accepted = attach_ok(
                    vector,
                    parse_vector(centroid),
                    parse_vector(seed),
                    len(members),
                    threshold=self.params.threshold,
                    max_drift=self.params.max_drift,
                )
                if accepted is None:
                    continue
                self.load_vectors(members)
                members = sorted([*members, fact_id])
                moved, seed_vector = accepted[1], parse_vector(seed)
                var = variability([self.vectors[m] for m in members], moved, seed_vector)
                statement = self.confirm(members, moved, var.spread)
                if statement is None:
                    continue
                self.join(int(did), members, moved, seed_vector, var, statement)
                self.state.attached += 1
                placed = True
                break
            if not placed:
                self.write_single(fact_id)
            self.state.scanned += 1
            if self.state.scanned % 100 == 0:
                self.report("attach")

    def join(
        self, did: int, members: Sequence[int], centroid: Vector, seed: Vector, var: Variability, statement: _Statement
    ) -> None:
        current = self.session.execute(
            text(
                "SELECT statement, statement_generated, distill_model, model_slug FROM distilled_facts WHERE id = :id"
            ),
            {"id": did},
        ).one()
        # A group the model already stated keeps its sentence unless the model restated it.
        if current[3] is not None and current[1] and not statement.generated:
            statement = _Statement(current[0], True, current[2])
        self.session.execute(
            text(
                """
                UPDATE distilled_facts SET
                    statement = :statement, statement_generated = :generated, distill_model = :distill_model,
                    representative_fact_id = :rep, members_sha256 = :sha, model_slug = :slug,
                    threshold = :threshold, nodes = :nodes, spread = :spread, drift = :drift, radius = :radius
                WHERE id = :id
                """
            ),
            {
                "id": did,
                "statement": statement.text,
                "generated": statement.generated,
                "distill_model": statement.distill_model,
                "rep": representative(members, self.texts),
                "sha": members_sha256(members),
                "slug": self.model.slug,
                "threshold": self.params.threshold,
                "nodes": len(members),
                "spread": var.spread,
                "drift": var.drift,
                "radius": var.radius,
            },
        )
        self.upsert_vector(did, centroid, seed)
        self.link(did, members, centroid)
        self.stale_elsewhere([did])

    # -- both ------------------------------------------------------------------------

    def finish(self) -> None:
        # Representatives with no vector here stand alone until they have one.
        self.session.execute(
            text(
                """
                INSERT INTO distilled_facts (fact_class, statement, representative_fact_id, members_sha256, nodes)
                SELECT f.fact_class, f.fact, f.id, sha256(convert_to(f.id::text, 'UTF8')), 1
                FROM facts f WHERE f.distilled_fact_id IS NULL AND f.restates_fact_id IS NULL
                """
            )
        )
        self.session.execute(
            text(
                """
                UPDATE facts f SET distilled_fact_id = df.id, distilled_similarity = NULL
                FROM distilled_facts df
                WHERE f.distilled_fact_id IS NULL AND f.restates_fact_id IS NULL
                  AND df.model_slug IS NULL AND df.representative_fact_id = f.id
                """
            )
        )
        # A restatement backs what its representative backs.
        self.session.execute(
            text(
                """
                UPDATE facts r
                SET distilled_fact_id = rep.distilled_fact_id, distilled_similarity = r.restates_similarity
                FROM facts rep
                WHERE r.restates_fact_id = rep.id AND r.distilled_fact_id IS DISTINCT FROM rep.distilled_fact_id
                """
            )
        )
        self.session.execute(
            text(
                "DELETE FROM distilled_facts df"
                " WHERE NOT EXISTS (SELECT 1 FROM facts f WHERE f.distilled_fact_id = df.id)"
            )
        )
        self.session.execute(
            text(
                """
                INSERT INTO fact_cluster_state (id, model_slug, params) VALUES (1, :slug, :params)
                ON CONFLICT (id) DO UPDATE SET model_slug = EXCLUDED.model_slug, params = EXCLUDED.params,
                                               updated_at = now()
                """
            ),
            {"slug": self.model.slug, "params": self.params.corpus_key()},
        )
        self.session.commit()
        self.state.clusters, self.state.clustered_facts, self.state.distilled_facts = self.session.execute(
            text(
                """
                SELECT count(*) FILTER (WHERE df.model_slug IS NOT NULL),
                       coalesce(sum(n) FILTER (WHERE df.model_slug IS NOT NULL), 0),
                       count(*)
                FROM distilled_facts df
                JOIN (SELECT distilled_fact_id, count(*) AS n FROM facts GROUP BY distilled_fact_id) m
                  ON m.distilled_fact_id = df.id
                """
            )
        ).one()

    def needs_full_run(self) -> bool:
        row = self.session.execute(text("SELECT model_slug, params FROM fact_cluster_state WHERE id = 1")).first()
        return row is None or (row[0], row[1]) != (self.model.slug, self.params.corpus_key())


def _neighbor_sql(table: str, op: str) -> str:
    return f"""
        SELECT src.fact_id AS a, nb.fact_id AS b, nb.similarity
        FROM (
            SELECT c.fact_id, f.fact_class, e.embedding
            FROM chunks c
            JOIN facts f ON f.id = c.fact_id
            JOIN {table} e ON e.chunk_id = c.id
            WHERE c.fact_id = ANY(CAST(:ids AS bigint[]))
        ) src
        CROSS JOIN LATERAL (
            SELECT c2.fact_id, 1 - (e2.embedding <=> src.embedding) AS similarity
            FROM {table} e2
            JOIN chunks c2 ON c2.id = e2.chunk_id
            JOIN facts f2 ON f2.id = c2.fact_id
            WHERE f2.fact_class = src.fact_class AND c2.fact_id <> src.fact_id AND f2.restates_fact_id IS NULL
            ORDER BY e2.embedding {op} src.embedding
            LIMIT :k
        ) nb
    """


def _pairwise_sql(table: str) -> str:
    return f"""
        SELECT ca.fact_id AS a, cb.fact_id AS b, 1 - (ea.embedding <=> eb.embedding) AS similarity
        FROM chunks ca JOIN {table} ea ON ea.chunk_id = ca.id,
             chunks cb JOIN {table} eb ON eb.chunk_id = cb.id
        WHERE ca.fact_id = ANY(CAST(:ids AS bigint[])) AND cb.fact_id = ANY(CAST(:ids AS bigint[]))
          AND ca.fact_id < cb.fact_id
    """


def cluster_facts(
    session: Session,
    model: EmbeddingModel,
    params: ClusterParams,
    *,
    full: bool = False,
    distiller: Distiller | None = None,
    progress: Callable[[ClusterProgress], None] | None = None,
) -> ClusterProgress:
    """Dedup the potential facts in two levels and link each to a distilled fact; see the module docstring.

    Groups come from ``model``'s vectors. The run is full when ``full`` is set or
    the model or a grouping parameter changed since the last run, incremental
    otherwise. Without a ``distiller`` every group is kept and stated by its
    representative's text. Commits once, at the end; potential facts are only
    re-linked, never changed.
    """
    run = _Pass(session, model, params, distiller, progress)
    run.state.full = full or run.needs_full_run()
    run.load_facts()
    apply_search_tuning(session)
    _iterative_scan(session)
    run.restate_documents(run.state.full)
    if run.state.full:
        run.regroup()
    else:
        run.refresh()
        run.place()
    run.finish()
    run.report("done")
    return run.state
