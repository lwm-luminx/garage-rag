"""Grouping facts that state the same claim (``garage cluster-facts``).

Every fact already has a vector: its chunk (``chunks.fact_id``) is embedded by
the ordinary backfill under every registered model. This pass reads those
vectors under one model (the default, unless named) and builds an overlay of
``fact_clusters`` on top of the facts (``data/sql/015_fact_clusters.sql``):

1. **Candidates.** Each fact's nearest neighbours among the facts of the same
   class, from the model's ``emb_`` table (its HNSW index, where the model's
   distance allows), kept when their cosine similarity reaches the threshold.
   The kept pairs link facts into connected groups.
2. **Guard.** Embeddings put "42 employees" beside "45 employees" and "the
   meeting is on Tuesday" beside "the meeting is not on Tuesday". A group is
   split by what each fact says about numbers, dates and negation, so facts
   that differ there are never grouped (:func:`claim_signature`).
3. **Average linkage.** Within each guarded group, clusters merge only while
   their *average* pairwise similarity clears the threshold, so A~B and B~C do
   not chain A and C together when A and C differ (:func:`average_linkage`).
4. **Distill.** The local chat model (:class:`~garage_rag.enrich.generation.LocalChatModel`,
   ``inference.*`` falling back to ``facts.*``) is shown each cluster's facts
   and asked whether they state one claim; a "no" dissolves the cluster, a
   "yes" comes with one sentence stating it (``fact_clusters.statement``).
   A cluster with a communication among its members is only sent to a
   loopback model; otherwise it keeps no statement.

Clustering never touches a fact: each member keeps its verbatim text and its
grounded span, and a re-run rebuilds the overlay. A cluster whose members are
unchanged keeps its row and statement (``members_sha256``), so re-running
only asks the model about new groups.
"""

from __future__ import annotations

import hashlib
import logging
import re
from collections.abc import Callable, Iterable, Sequence
from dataclasses import dataclass, field

from sqlalchemy import text
from sqlalchemy.orm import Session

from garage_rag.db.emb_tables import assert_safe_table
from garage_rag.db.engine import apply_search_tuning
from garage_rag.db.models import CorpusClass, EmbeddingModel
from garage_rag.db.registry import distance_operator
from garage_rag.net import egress

log = logging.getLogger(__name__)

# Source facts per neighbour query.
NEIGHBOR_BATCH = 256
# A connected group larger than this is linked from its neighbour pairs alone
# rather than from every pairwise similarity (which grows as the square).
MAX_PAIRWISE = 300
# Facts shown to the model for one cluster; a larger cluster shows its most
# central members.
MAX_DISTILL_FACTS = 20

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


@dataclass
class ClusterProgress:
    """Where a run is. ``phase`` is ``neighbors``, ``distill`` or ``done``."""

    phase: str = "neighbors"
    facts: int = 0
    # Facts of the scope with no vector under the model yet (run the backfill).
    unembedded: int = 0
    scanned: int = 0
    candidates: int = 0
    distilled: int = 0
    to_distill: int = 0
    clusters: int = 0
    clustered_facts: int = 0
    kept: int = 0
    dissolved: int = 0
    failed: int = 0
    withheld: int = 0
    errors: list[str] = field(default_factory=list)


def _iterative_scan(session: Session) -> None:
    """Let a filtered HNSW scan keep going until it finds enough fact rows (pgvector 0.8+)."""
    try:
        with session.begin_nested():
            session.execute(text("SET LOCAL hnsw.iterative_scan = relaxed_order"))
    except Exception:  # noqa: BLE001 - older pgvector has no such setting; recall is then ef_search's
        log.debug("hnsw.iterative_scan is not available")


def _neighbor_sql(table: str, model: EmbeddingModel) -> str:
    # Order by the model's own distance, so its index serves the scan; judge
    # similarity by cosine regardless, so one threshold means one thing. The
    # binary-quantized models index a quantization, not the column: their scan
    # is exact and unindexed.
    op = distance_operator(model.distance) if model.index_kind != "hnsw_bq" else "<=>"
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
            WHERE f2.fact_class = src.fact_class AND c2.fact_id <> src.fact_id
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


def _scope(source: str | None, fact_class: str | None) -> tuple[str, dict[str, object]]:
    clauses = ["TRUE"]
    params: dict[str, object] = {}
    if source and source != "*":
        clauses.append("s.slug = :source")
        params["source"] = source
    if fact_class:
        clauses.append("f.fact_class = :fact_class")
        params["fact_class"] = fact_class
    return " AND ".join(clauses), params


def cluster_facts(
    session: Session,
    model: EmbeddingModel,
    *,
    threshold: float,
    neighbors: int,
    distiller: Distiller | None = None,
    source: str | None = None,
    fact_class: str | None = None,
    progress: Callable[[ClusterProgress], None] | None = None,
) -> ClusterProgress:
    """Rebuild the fact clusters of the scope under ``model``'s vectors; see the module docstring.

    ``source``/``fact_class`` narrow which facts are clustered (neighbours still
    come from the whole corpus, so a scoped fact can join a group outside the
    scope). Without a ``distiller`` every guarded cluster is kept, with no
    statement. Commits once, at the end; the facts themselves are never changed.
    """
    table = assert_safe_table(model.table_name)
    state = ClusterProgress()

    def report(phase: str) -> None:
        state.phase = phase
        if progress is not None:
            progress(state)

    where, params = _scope(source, fact_class)
    joins = "FROM facts f JOIN documents d ON d.id = f.document_id JOIN sources s ON s.id = d.source_id"
    rows = session.execute(
        text(
            f"""
            SELECT f.id, f.fact, d.corpus_class::text,
                   EXISTS (SELECT 1 FROM chunks c JOIN {table} e ON e.chunk_id = c.id WHERE c.fact_id = f.id)
            {joins} WHERE {where} ORDER BY f.id
            """
        ),
        params,
    ).all()
    state.facts = len(rows)
    embedded = [int(r[0]) for r in rows if r[3]]
    state.unembedded = state.facts - len(embedded)
    report("neighbors")

    # 1. Candidate pairs from each fact's nearest neighbours.
    apply_search_tuning(session)
    _iterative_scan(session)
    similarity: dict[tuple[int, int], float] = {}
    neighbor_sql = text(_neighbor_sql(table, model))
    for start in range(0, len(embedded), NEIGHBOR_BATCH):
        batch = embedded[start : start + NEIGHBOR_BATCH]
        for a, b, sim in session.execute(neighbor_sql, {"ids": batch, "k": neighbors}).all():
            if sim is not None and float(sim) >= threshold:
                similarity[pair(int(a), int(b))] = float(sim)
        state.scanned += len(batch)
        report("neighbors")

    ids = {i for p in similarity for i in p}
    texts: dict[int, str] = {}
    classes: dict[int, str] = {}
    if ids:
        for fid, fact, corpus_class in session.execute(
            text(
                "SELECT f.id, f.fact, d.corpus_class::text FROM facts f JOIN documents d ON d.id = f.document_id "
                "WHERE f.id = ANY(CAST(:ids AS bigint[]))"
            ),
            {"ids": sorted(ids)},
        ).all():
            texts[int(fid)] = fact
            classes[int(fid)] = corpus_class

    # 2-3. Guard and average linkage within each connected group.
    clusters: list[list[int]] = []
    pairwise_sql = text(_pairwise_sql(table))
    for group in connected_groups(ids, similarity):
        if len(group) <= MAX_PAIRWISE:
            for a, b, sim in session.execute(pairwise_sql, {"ids": group}).all():
                similarity[pair(int(a), int(b))] = float(sim)
        clusters.extend(guarded_clusters(group, texts, similarity, threshold))
    state.candidates = len(clusters)

    # 4. Keep unchanged clusters, distill the new ones, then replace the overlay.
    existing = {
        bytes(sha): (int(cid), statement, distill_model)
        for cid, sha, statement, distill_model in session.execute(
            text("SELECT id, members_sha256, statement, distill_model FROM fact_clusters WHERE model_slug = :slug"),
            {"slug": model.slug},
        ).all()
    }
    keep: set[int] = set()
    fresh: list[tuple[list[int], str | None, str | None]] = []
    to_ask: list[list[int]] = []
    for members in clusters:
        found = existing.get(members_sha256(members))
        if found is not None and (found[2] is not None or distiller is None):
            keep.add(found[0])
        else:
            to_ask.append(members)
    state.kept = len(keep)
    state.to_distill = len(to_ask) if distiller is not None else 0
    report("distill")

    for members in to_ask:
        if distiller is None:
            fresh.append((members, None, None))
            continue
        if not distiller.may_send(classes[m] for m in members):
            state.withheld += 1
            fresh.append((members, None, None))
        else:
            central = centrality(members, similarity)
            shown = sorted(members, key=lambda m: (-central[m], m))[:MAX_DISTILL_FACTS]
            try:
                same, statement = distiller.distill([texts[m] for m in shown])
            except Exception as exc:  # noqa: BLE001 - counted; the cluster stays, unconfirmed
                state.failed += 1
                if len(state.errors) < 5:
                    state.errors.append(str(exc))
                fresh.append((members, None, None))
            else:
                if same:
                    fresh.append((members, statement, distiller.model_id))
                else:
                    state.dissolved += 1
        state.distilled += 1
        report("distill")

    # Replace every cluster of the scope that this run did not keep. Clusters of
    # other models go too: a fact belongs to one cluster at a time.
    session.execute(
        text(
            f"""
            DELETE FROM fact_clusters fc
            WHERE fc.id <> ALL(CAST(:keep AS bigint[]))
              AND (fc.model_slug <> :slug OR EXISTS (
                    SELECT 1 FROM fact_cluster_members m
                    JOIN facts f ON f.id = m.fact_id
                    JOIN documents d ON d.id = f.document_id
                    JOIN sources s ON s.id = d.source_id
                    WHERE m.cluster_id = fc.id AND {where})
                OR NOT EXISTS (SELECT 1 FROM fact_cluster_members m WHERE m.cluster_id = fc.id))
            """
        ),
        {**params, "keep": sorted(keep), "slug": model.slug},
    )
    # Facts still in a cluster: the kept ones, and those outside the scope.
    kept_members = {int(fid) for (fid,) in session.execute(text("SELECT fact_id FROM fact_cluster_members")).all()}
    insert_cluster = text(
        """
        INSERT INTO fact_clusters
            (model_slug, threshold, fact_class, statement, representative_fact_id, members_sha256, distill_model)
        SELECT :slug, :threshold, f.fact_class, :statement, f.id, :sha, :distill_model FROM facts f WHERE f.id = :rep
        RETURNING id
        """
    )
    insert_member = text(
        "INSERT INTO fact_cluster_members (fact_id, cluster_id, similarity)"
        " VALUES (:fact_id, :cluster_id, :similarity) ON CONFLICT (fact_id) DO NOTHING"
    )
    for members, statement, distill_model in fresh:
        # A fact already in a cluster this run keeps (or one out of its scope) stays there.
        members = [m for m in members if m not in kept_members]
        if len(members) < 2:
            continue
        cluster_id = session.execute(
            insert_cluster,
            {
                "slug": model.slug,
                "threshold": threshold,
                "statement": statement,
                "rep": representative(members, texts),
                "sha": members_sha256(members),
                "distill_model": distill_model,
            },
        ).scalar_one()
        central = centrality(members, similarity)
        session.execute(
            insert_member,
            [{"fact_id": m, "cluster_id": cluster_id, "similarity": central[m]} for m in members],
        )
    session.commit()

    state.clusters, state.clustered_facts = session.execute(
        text(
            f"""
            SELECT count(DISTINCT m.cluster_id), count(*)
            FROM fact_cluster_members m JOIN facts f ON f.id = m.fact_id
            JOIN documents d ON d.id = f.document_id JOIN sources s ON s.id = d.source_id
            WHERE {where}
            """
        ),
        params,
    ).one()
    report("done")
    return state
