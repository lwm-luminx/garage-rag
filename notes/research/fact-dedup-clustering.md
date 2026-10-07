# Clustering for fact dedup on pgvector: the options

*Briefing for Rick, 2026-09-29. Covers what #191 does today, the alternatives, and a recommendation.*

## The short version

Dedup needs a clustering method that finds **small, tight groups of restatements in a sea of
singletons**, under a **fixed meaning of "same claim"** (a similarity threshold), and that stays
**stable when new documents arrive** so already-distilled groups keep their statement and vectors.
Most classic clustering algorithms answer a different question: they partition everything into
topics, or they estimate density. Those are good for a "themes" feature, but they are the wrong
tool for dedup.

**Recommendation:** keep the shape #191 already has, which is pgvector kNN for blocking, then
connected components, then the claim guard, then average linkage, then a local-model yes/no. Make
the neighbour pass incremental, add a free exact-text pre-pass, and calibrate the threshold per
model. Don't add HDBSCAN, Leiden or k-means for dedup. They cost a large new dependency, don't
handle incremental ingest well, and still need the guard. Keep them in mind for a later topics
view.

## How big the problem is

These numbers are estimates, not measurements from a real corpus. A heavy personal corpus is
roughly 10⁴–10⁵ documents at 10–30 facts each, so **10⁵ to about 10⁶ potential facts**, split
across a handful of `fact_class` values. Most facts have no duplicate. The duplicates cluster in
mail (quoted replies, forwards), in drafts and versions of the same document, and in a small
model restating a compound claim along with its parts.

At 10⁶ facts with 1024 dimensions (bge-m3), the raw vectors take about 4 GB as float32. Any
method that pulls every vector into Python pays that cost. Methods that stay inside Postgres and
use the HNSW index don't.

## What #191 does today

`enrich/clusters.py`, `garage cluster-facts`:

1. **Blocking by kNN.** For every embedded fact, a `LATERAL` HNSW query returns its `k` nearest
   facts of the same `fact_class` (`facts.cluster_neighbors`, default 10), and the pass keeps the
   pairs at or above the cosine threshold (`facts.cluster_threshold`, default 0.9). It uses
   `hnsw.iterative_scan` so the class filter doesn't starve the scan.
2. **Connected components** over those pairs, with union-find.
3. **Guard.** Each component is split by `claim_signature`: its numbers, temporal words and
   negation. "42 employees" never meets "45 employees", and "is on Tuesday" never meets "is not
   on Tuesday".
4. **Average linkage** inside each part. The pass computes exact pairwise cosines for components
   of up to 300 facts and falls back to the kNN pairs for larger ones. Clusters merge only while
   their *average* similarity is at or above the threshold, so A≈B plus B≈C doesn't drag A and C
   together.
5. **Local-model confirm.** Each new group gets one yes/no call plus a single statement. The
   egress rule applies: a group containing a communication goes only to a loopback model.
6. **Stability.** `members_sha256` means an unchanged group keeps its row, its statement and its
   `fact_emb_*` vectors, so a re-run only asks the model about groups that changed.

One property matters when comparing it with the alternatives. Suppose two clusters had an
average similarity at or above the threshold. Then at least one pair between them is at or above
the threshold, so kNN would have connected them, as long as it found that pair. That makes
average linkage per component equal to **global average linkage, up to kNN recall**. The
component step is an optimisation, not an approximation of a different algorithm.

**Its weak spots:**
- **The neighbour pass is corpus-wide on every run.** It makes one ANN query per fact. At 10⁶
  facts that is roughly 10–30 minutes on an M-series Mac, which is an unmeasured estimate. This
  is the main cost worth fixing.
- **Components over 300 facts** fall back to sparse similarities, where an unknown pair counts as
  0. The error is safe, because it can only *under*-merge, but big genuine groups can split. This
  happens with boilerplate such as signature lines and disclaimers.
- **`k` limits recall for hub facts.** When one claim appears 50 times, each copy sees only 10
  neighbours. Transitivity usually still joins the component, and step 4 then measures the whole
  thing exactly.
- **The threshold depends on the model.** 0.9 is a sensible starting point for the bge and nomic
  families, but it hasn't been calibrated.

## The alternatives

### 1. Threshold graph plus connected components alone (single linkage)

This is steps 1–2 without the rest.

- **Fit:** trivially cheap, and all of it stays in Postgres.
- **Incremental ingest:** ideal. Union-find absorbs new edges, and nothing moves.
- **Knobs:** the threshold and `k`.
- **Failure mode:** **chaining.** Paraphrase chains ("Acme was founded in 1998", then "Acme,
  founded 1998, makes widgets", then "Acme makes widgets") collapse distinct claims into one
  group. Contradictions merge too, because embeddings place them close together.
- **Verdict:** good for blocking only. That is how #191 uses it.

DBSCAN with `min_samples=2` and `eps = 1 − threshold` computes the same thing, so it isn't a
separate option.

### 2. HNSW neighbour graph plus community detection (Louvain, Leiden, label propagation)

This builds the kNN graph as in step 1, then optimises modularity over it.

- **Fit:** the graph is cheap to build from pgvector. Apache AGE has no graph-algorithm library,
  so the detection runs in Python.
  - `networkx` Louvain is BSD but slow at 10⁶ edges.
  - `python-igraph` and `leidenalg` are fast, but they are **GPL-2/GPL-3**. That is a
    licensing problem for the app bundle.
- **Incremental ingest:** poor. Modularity is a global objective, so adding documents can
  relabel communities far from the change. That churns `members_sha256` and forces the model to
  re-distill groups that didn't really change.
- **Knobs:** the resolution parameter, `k`, and edge weighting.
- **Failure mode:** **wrong granularity.** Communities are "facts about Acme", not "the same
  claim about Acme". Getting them down to paraphrase size means pushing the resolution so high
  that the output amounts to thresholded components again. The method also doesn't prevent
  contradictions from merging.
- **Verdict:** a good fit for a later *topics* or *themes* view over distilled facts. The wrong
  tool for dedup.

### 3. DBSCAN or HDBSCAN in Python

`sklearn.cluster.HDBSCAN` (BSD) has shipped since scikit-learn 1.3.

- **Fit:** it needs the vectors in Python, which means about 4 GB at 10⁶ facts, or batching by
  `fact_class`. Density estimates degrade at 768–1024 dimensions, and the usual workaround is
  UMAP first. UMAP means `umap-learn` plus `numba`, heavy native dependencies that are
  impractical to bundle into the app's Python.framework. scikit-learn and SciPy alone would add
  roughly 100 MB to the bundle and to the third-party notices.
- **Incremental ingest:** none in scikit-learn. The standalone `hdbscan` package has
  `approximate_predict`, but new clusters still need a full re-run, which churns labels.
- **Knobs:** `min_cluster_size`, `min_samples` and `cluster_selection_epsilon`. It needs **no
  similarity threshold**, and that is its selling point.
- **Failure modes:**
  - *Density isn't meaning.* Dedup wants a fixed bar for "same claim", while HDBSCAN adapts its
    bar to local density. A dense region of related but distinct facts, such as many invoices
    from one vendor, becomes one cluster.
  - *Noise labelling.* Real pairs in sparse regions are labelled noise. That part is harmless
    here, since noise facts simply stay singletons.
  - It still needs the guard.
- **Verdict:** a powerful tool for exploratory topic discovery, with the wrong objective for
  dedup and the wrong dependency cost for the app.

### 4. Global agglomerative clustering (scikit-learn `AgglomerativeClustering`)

This uses `linkage="average"` and `distance_threshold`, with a kNN connectivity graph.

- **Fit:** without a connectivity graph it needs an O(n²) distance matrix, which is impossible at
  10⁵ and above. With the kNN graph it gives **the same answer #191 gets** (see the property
  above), but it moves the vectors into Python and adds scikit-learn.
- **Incremental ingest:** none. It re-runs over everything.
- **Knobs:** the linkage type and the threshold.
- **Failure modes:** single linkage chains; complete linkage is strict and splits genuine groups
  that have one outlier; average linkage is the right middle ground.
- **Verdict:** already implemented, in-database and per component. No reason to switch.

### 5. k-means or IVF-style partitioning

pgvector's IVFFlat lists are k-means centroids.

- **Fit:** easy. Mini-batch k-means scales, and IVFFlat already computes centroids in Postgres.
- **Incremental ingest:** new facts go to their nearest centroid cheaply, but centroids drift and
  need occasional rebuilds.
- **Knobs:** `k`, the number of clusters, which dedup can't know in advance.
- **Failure mode:** **the wrong shape entirely.** It partitions every fact into a Voronoi cell
  with no control over cluster radius. Dedup groups are tiny and tight, and most facts are
  singletons. Every cell would need an inner threshold clustering anyway, and a pair of
  duplicates that straddles a cell boundary is missed.
- **Verdict:** useful only as coarse blocking, and HNSW kNN already does blocking better.
  Possible centroids for a topics view.

### 6. Lexical near-duplicate detection (exact, normalised text, MinHash)

This isn't a vector method, but it belongs in this list.

- **Fit:** it's free. Normalised-text equality (casefold, whitespace, trailing punctuation) is
  one `GROUP BY`. MinHash LSH can be done in SQL, or in pure Python with no dependency.
- **Incremental ingest:** perfect, because it hashes on insert.
- **Failure mode:** it misses real paraphrases, and it doesn't aim to catch them.
- **Verdict:** a **pre-pass**. It removes the bulk of the mail duplicates (quoted replies,
  forwards) before any embedding work, and it shrinks the input to the vector stages. The Phase A
  findings (`/mnt/project-files/langextract-age/findings.md`) said the same.

## Comparison

| Method | Groups restatements (not topics) | Chaining-safe | Stable on re-runs | Incremental | Stays in Postgres | New dependency |
|---|---|---|---|---|---|---|
| **#191: kNN, components, guard, average linkage, model** | Yes | Yes | Yes (`members_sha256`) | Partly (see below) | Neighbours yes; linkage in Python on small groups | None |
| Components only (single linkage, DBSCAN minPts=2) | Yes | No | Yes | Yes | Yes | None |
| Leiden, Louvain or label propagation | No (topics) | Partly | No | No | Graph only | GPL (igraph, leidenalg) or slow (networkx) |
| HDBSCAN (± UMAP) | No (density) | Mostly | No | No | No | scikit-learn, SciPy (± umap, numba) |
| Global agglomerative | Yes | Yes (average) | No | No | No | scikit-learn |
| k-means or IVF | No (partitions) | n/a | Drifts | Assign only | Yes (IVF) | None or scikit-learn |
| Exact or MinHash text | Verbatim only | Yes | Yes | Yes | Yes | None |

## Recommendation, in priority order

1. **Keep #191's algorithm.** It already amounts to global average-linkage clustering at a fixed
   threshold, uses the HNSW index for the expensive part, has the guard and the model confirm,
   and keeps groups stable across runs.
2. **Make the neighbour pass incremental.** This is the one real scaling fix. *Superseded on
   2026-09-29:* the watermark-and-recluster design first proposed here was replaced by the
   two-level plan in the next section, which makes the corpus pass incremental by attaching new
   nodes to stored centroids instead of re-running components. The goal is the same: one query
   per new fact, and a full run only when the model or a parameter changes.
3. **Add the exact normalised-text pre-pass.** It's cheap and takes out the mail bulk.
4. **Calibrate the threshold per embedding model.** Use a small labelled fixture of paraphrase,
   non-paraphrase and contradiction pairs, and ship a per-model default in `models.json` instead
   of one global 0.9.
5. **Watch components over 300 facts.** If boilerplate starts producing them, fetch exact
   pairwise cosines in blocks rather than raising the cap.
6. **Keep HDBSCAN, Leiden and k-means for a separate "themes" feature** over distilled facts, if
   one is wanted. If it happens, prefer Louvain in `networkx` (BSD) over the GPL igraph stack.
7. **Use HDBSCAN where it fits: image embeddings, and as an audit.** (Added 2026-09-29.)
   - *Images, such as faces (the image embedding work on `next`, #158).* Rick has used HDBSCAN
     for this before. There the question really is density: how many people, with an unknown
     count, varying numbers of photos each, and many one-off faces left as noise. That is
     HDBSCAN's strength, and unlike fact dedup it has no absolute "same claim" bar to hold.
     Treat it as its own pass with its own dependency decision, separate from fact dedup.
   - *Fact dedup: a calibration audit, not a pipeline step.* On the M4, run HDBSCAN over the
     real fact vectors in a scratch script and compare its clusters with the two-level groups:
     - where HDBSCAN merges what we split, the threshold may be too strict (unless the guard
       split on a number or date, which is right);
     - where we merge what it splits or calls noise, the threshold or drift cap may be too loose.
     The disagreements are the list to review when tuning 0.92, 0.9 and the drift cap.
   - *Native implementations, to avoid scikit-learn (numpy, SciPy, joblib) or numba.* Checked
     2026-09-29:

     | Option | Language, license | Dependencies | Metrics | Notes |
     |---|---|---|---|---|
     | [rohanmohapatra/hdbscan-cpp](https://github.com/rohanmohapatra/hdbscan-cpp) | C++, MIT | STL only | Euclidean shown | Smallest; an easy `cc_library` in Bazel. Maintenance unclear. |
     | [JasonLovesDoggo/hdbscan-rs](https://github.com/JasonLovesDoggo/hdbscan-rs) | Rust, MIT/Apache-2.0 | a few crates | Euclidean, Manhattan, Cosine, Minkowski, precomputed | Checked against scikit-learn fixtures (ARI > 0.99); 500×1536-d in 27 ms. Young (7 stars). |
     | [tom-whitehead/hdbscan](https://github.com/tom-whitehead/hdbscan) (`hdbscan` crate) | Rust, MIT/Apache-2.0 | small | Euclidean, Manhattan, others | The established Rust crate. |
     | [petabi/petal-clustering](https://github.com/petabi/petal-clustering) | Rust, Apache-2.0 | `ndarray`, `petal-neighbors` | Euclidean shown | DBSCAN, HDBSCAN and OPTICS in one crate. |
     | [wangyiqiu/hdbscan](https://github.com/wangyiqiu/hdbscan) | C++, MIT | parlaylib, pybind11 | Euclidean | Fast parallel research code, but 2 to 20 dimensions only. Not for embeddings. |

     No Swift or Accelerate HDBSCAN turned up.
   - *Metric.* Faces and text embeddings are compared by cosine, but on L2-normalized vectors
     Euclidean distance orders pairs exactly as cosine does (‖a − b‖² = 2 − 2·cos). A
     Euclidean-only implementation is therefore fine if we normalize first.
   - *Build cost.* The Rust crates bring `rules_rust` and a Rust toolchain into the Bazel
     build, which is its own large dependency. The C++ option fits the existing `cc_library`
     setup, as llama.cpp already does.
   - *Or write it.* HDBSCAN is small once the neighbours are known: core distances from each
     point's k-th neighbour, a minimum spanning tree over mutual-reachability distance,
     then the condensed tree and stability pick. pgvector already gives the kNN graph. An
     MST built on that graph (approximate, as `fast_hdbscan` does) is a few hundred lines in
     Swift (Accelerate for the distances) or pure Python, with no new dependency.
   - *ClusterKit (Rick's pointer, 2026-09-29).* [scientist-labs/clusterkit](https://github.com/scientist-labs/clusterkit)
     (MIT) is a Ruby gem: Rust bindings for UMAP (`annembed`), `hnsw_rs`, K-means and HDBSCAN.
     Its HDBSCAN is the `hdbscan` crate (tom-whitehead, MIT OR Apache-2.0), whose only
     dependencies are `num-traits`, `kdtree` and an optional `rayon`. We would take that crate
     directly, not the gem, since the gem's Ruby bindings are no use to us. Findings:
     - *Footprint:* very small, three crates, all permissively licensed.
     - *Metrics:* Euclidean and Manhattan (ClusterKit notes only Euclidean is fully supported).
       Normalize vectors first and Euclidean ranks pairs exactly as cosine does.
     - *Fit to the split below:* it takes raw vectors and finds neighbours itself with a
       k-d tree. In 512 to 1536 dimensions a k-d tree degrades to brute force, O(N²) distance
       work: fine for thousands of faces, slow for 100k. It does not take a precomputed
       neighbour graph, so pgvector's index could not do the heavy half for it without a patch
       (the MST and condensed-tree code in it would still be reusable).
     - *Build and link:* `rules_rust` from the BCR with `crate_universe` pinning the three
       crates. A small wrapper crate exposes an `extern "C"` function (a `staticlib`); a
       `cc_library` wraps it for Swift, much as llama.cpp is linked into LlamaXPCService. As a
       Postgres extension it would need `pgrx`, whose `cargo pgrx` build tooling does not fit
       Bazel well. So it belongs in a helper process, not the database.
     - *Cost:* `rules_rust` and a Rust toolchain become part of every macOS build. That is the
       real dependency, not the crate.
     - *Verdict:* the best ready-made option if we accept Rust in the build. Use it as it is
       for up to tens of thousands of faces. For larger sets, either patch it to accept a
       neighbour graph, or port its MST and condensed-tree steps to Swift and keep Rust out.
   - *Where it runs (Rick, 2026-09-29: in the database, or a specialized non-Python process).*
     HDBSCAN has two halves. The heavy half is finding each point's k nearest neighbours; the
     light half is a minimum spanning tree over those neighbour edges, then the condensed tree.
     - **All in Postgres.** No HDBSCAN extension exists for Postgres or pgvector (searched
       2026-09-29). The kNN half is already natural in SQL: a `LATERAL` HNSW query per point, as
       `cluster-facts` does. The tree half is iterative, and in PL/pgSQL it would be slow and
       hard to maintain.
     - **Our own C extension**, built in `//ext` beside pgvector and AGE, such as a
       set-returning `hdbscan(...)` reading vectors through SPI. Nothing leaves the database,
       but we would own C code that can crash a backend. A long run also holds a connection and
       backend memory. Homebrew and the CI image would lack it, so it is optional, as AGE is.
     - **A dedicated helper process**, the pattern the app already uses: an XPC service in
       Swift with Accelerate, or a mode of the image embedder's service. It is crash-isolated,
       sandboxed, with no network and no Python. It is macOS-only, so the CLI and the Linux
       venv would need a fallback.
     - **Recommended split.** Postgres does the kNN half with pgvector's index. The helper
       receives only the neighbour edges: `(id, neighbour id, distance)`, N × k rows and no
       vectors. It builds the MST and the condensed tree, then writes labels back through the
       gRPC facade. The expensive work stays where the index is. The helper's input is small
       (100k faces × k = 15 is 1.5M edges, about 24 MB), and no embedding leaves Postgres. The
       same edge list feeds a portable fallback: a Python implementation of the light half is
       pure data structures, with no numpy.
   - *Leaning.* For faces, the split above, with the tree half written in Swift, or
     `hdbscan-cpp` vendored if its output matches scikit-learn on a test set. For the one-off
     fact audit, plain scikit-learn in a throwaway venv on the M4 is fine, since it never ships.

## The two-level plan as chosen (2026-09-29), and a review of it

*Agreed with Rick and being built on a branch stacked on #191 (`enrich/clusters.py`,
`data/sql/016_fact_dedup.sql`, the `seed` column in `fact_emb_<slug>`). Reviewed against the
in-progress code on 2026-09-29.*

### What was chosen

**Level 1, per document.** Inside the cluster pass (not at extraction, since vectors come from
the backfill), each document's facts *of one class* are compared pair by pair: exact cosine from
the `emb_` table, plus normalised-text equality counted as similarity 1.0. The claim guard and
average linkage apply, at the same threshold as level 2. Every member but the representative
(the longest text) gets `facts.restates_fact_id` and `restates_similarity`; it stays verbatim
and backs whatever its representative backs. `facts.dedup_key` (model slug plus threshold)
marks a fact as done; a document is redone when one of its facts gains a vector, its key is
stale, or its representative was deleted from under it, and redoing a document detaches its
facts from level 2 so they are placed again.

**Level 2, per corpus, over the level-1 representatives only (the *nodes*).**

- *Full run* (`--full`, or when the model or a parameter changed, tracked in
  `fact_cluster_state`): one kNN query per node gives each node its above-threshold neighbours.
  Nodes with any such neighbour are seeds, densest first. A seed's *core* is itself and its
  neighbours at or above `seed_threshold` (0.95) with the same claim signature; the core's mean
  is the group's `seed`. The group grows from the 50 nearest nodes to its centroid, nearest
  first: a candidate joins if its cosine to the current centroid is at least `threshold` (0.9)
  and the centroid it makes stays within `max_drift` (0.05) of the seed; guard mismatches and
  taken nodes are skipped, and growth stops at the first refusal. It re-centres and repeats, at
  most 4 rounds, dropping members the settled centroid left below threshold. Each group stores
  `nodes`, `spread` (mean distance to the centroid), `radius` (the largest) and `drift` (seed to
  centroid), and its centroid and seed as `fact_emb_<slug>.embedding` / `.seed`.
- *Tiers*: `spread ≤ 1 − tight_similarity` (0.97) is accepted with no model call; anything
  looser is one model YES/NO, where NO dissolves the group. A group whose members include a
  communication is only sent to a loopback model.
- *Incremental run* (the default): groups that lost nodes are re-centred from what remains
  (one node left makes it a singleton, none deletes it). Each new node is tried against the 5
  nearest distilled centroids of its class (the `fact_emb` HNSW): it joins the first that
  passes the guard, threshold and drift tests and either the tight tier or the model; otherwise
  it becomes a singleton distilled fact with its own centroid row, which later nodes can join.
  Restatements are linked to their representative's distilled fact.
- Other models' `fact_emb` rows are to be filled by the backfill as the mean of the member
  nodes' vectors under that model, and are deleted when a group changes.

**Graph.** A `RESTATES` edge (PotentialFact to PotentialFact); `SUPPORTS` from representatives.

### Verdict

The shape is right and is the correct evolution of #191: the level-1 split takes the mail and
compound-claim bulk out of the corpus pass, seed-and-grow with a drift cap gives bounded groups
without chaining, and attaching to stored centroids is what makes the incremental run one query
per new node. The recommendation above changes accordingly: item 1 stands (guard, average
linkage at level 1, model confirm), item 2 is now the plan below, and item 3 is done at level
1. Four things in the current code need fixing before it is trusted; the rest are improvements.

### Findings, ranked

1. **The tight tier is mis-scaled and removes the model from the most common case.** `spread`
   is a distance to the *centroid*, and for two unit vectors at pairwise cosine *s* each sits at
   half the angle: cosine to the centroid is √((1+s)/2). A pair at exactly the 0.90 threshold
   has spread 0.025, under the 0.03 cap, so **every pair at or above threshold is accepted
   without the model**; only a triple at 0.90 (spread 0.034) reaches it. Pairs are most groups.
   Fix: keep `tight_similarity` in pairwise terms and derive the cap, `spread ≤ 1 − √((1 +
   tight_similarity)/2)` (0.0075 at 0.97, 0.0126 at 0.95), or for groups small enough to show
   the model test the minimum pairwise similarity directly. Re-check `radius` the same way.
2. **Growth stalls at about `GROWTH_NEIGHBORS` members.** `knn_nodes(centroid)` returns the
   50 nearest nodes including the group's own members, so once a group holds ~50 the query
   returns nothing new and the remaining rounds are no-ops. Boilerplate hubs (signatures,
   disclaimers, a claim quoted 500 times) fragment into many near-identical groups, which is the
   old MAX_PAIRWISE problem in a new place. Fix: exclude members in SQL (`c.fact_id <>
   ALL(:members)`) or fetch `len(members) + 50`, and add the corpus-wide normalised-text
   pre-pass (one `GROUP BY` over `normalize_fact`) so verbatim copies collapse before any kNN.
3. **A full run at 10⁵–10⁶ nodes will not fit in memory as written, and will be slow.** Every
   vector loaded is cached in `_Pass.vectors` and never evicted, and `write_single` loads the
   vector of every singleton, which is most nodes. A 1024-float Python list is ~32 KB, so 10⁶
   nodes is ~30 GB. Fix: write singletons set-based in SQL (`INSERT INTO fact_emb ... SELECT
   e.embedding FROM chunks JOIN emb_`), keep vectors as `array('f')` (4 KB each) and evict them
   once a group is written. Separately, 10⁶ one-row inserts into `fact_emb` maintain the HNSW
   index row by row inside one transaction: drop the `fact_emb` index before a full run and
   rebuild it after, as pgvector recommends for bulk loads.
4. **A full run deletes every `distilled_facts` row.** Ids churn on every full run (the graph,
   any MCP client that cited a `distilled_fact_id`, the Facts page), and the cascade drops every
   other model's `fact_emb` rows, which the backfill must then remake. #191 kept unchanged rows
   by `members_sha256`. Fix: upsert by sha, delete only groups that no longer exist.
5. **The drift cap alone bounds the group loosely.** A member may be at 0.90 to the centroid
   while the centroid is 0.05 from the seed, so a member can be as far as cos 0.72 from the seed
   (angles add: 25.8° + 18.2°). Add a second membership test against the seed (cosine to the
   seed at or above `threshold`, or a `max_radius`); it is one dot product and it makes the
   result far less dependent on the order candidates arrive in. Also judge each round's
   candidates against the centroid the kNN was run from, then re-centre once: the walk is
   ordered by that centroid, but `attach_ok` moves the centroid after every join, so "stop at
   the first refusal because every later one is further away" does not hold as coded.
6. **Withheld loose groups are accepted unconfirmed.** When the members include a communication
   and the chat model is off-box, `confirm` counts the group as withheld and keeps it. That was
   tolerable in #191, where every group had passed average linkage; here the loose tier is by
   definition the case the model was needed for. Leave such groups ungrouped (singletons) and
   count them, so a user with an off-box chat model never gets an unconfirmed merge of private
   messages. The default `llama_xpc` is loopback, so nobody loses anything by default. The
   privacy rule is otherwise intact: nothing but the model call leaves the process, and filling
   other models' `fact_emb` rows by averaging removes the one remaining egress in
   `_backfill_facts` (embedding a generated statement off-box), which should then be deleted.
7. **NO has no memory.** A dissolved group has no row, so every full run re-forms it and asks
   again, and one outlier dissolves a group of twenty genuine restatements. Record rejections by
   `members_sha256` (a small table or a `dissolved` flag) and, on NO for a group larger than
   two, retry once without the member farthest from the centroid before giving up.
8. **Level 1 has no model gate and hides restatements from level 2 for good.** Two consequences.
   A wrong level-1 merge is never reviewed. And the node is the *longest* member, so a short
   restatement in document A is invisible to an identical short fact in document B unless B's
   fact reaches A's long representative at 0.9; for a pair that follows from level 1 itself, but
   in a larger average-linkage group the pairwise similarity can be lower and the match is
   missed. Give level 1 its own `restate_threshold` (default equal to `threshold`, so it can be
   raised independently), and consider the medoid (highest mean similarity to the group) as the
   node while keeping the longest text for display. This is a trade-off, not a bug: a tighter
   level 1 loses nothing, because what it leaves apart still meets at level 2, with the model.
9. **Redo churn.** A document is redone whenever any of its facts gains a vector, and a redo
   detaches all its facts from level 2. A large document embedded across several backfill
   batches is detached and re-placed several times. Process a document at level 1 only when all
   its facts have vectors under the model (or after the backfill reports the model complete).
10. **Incremental and full runs diverge in two ways, which is fine if it is documented and
    bounded.** The incremental run never merges two existing groups, and its seeds are single
    nodes rather than core means. Add `nodes_at_full_run` to `fact_cluster_state` and run full
    when new nodes since the last full run exceed a share (say 20%), or on request.
11. **pgvector specifics.** Normalise the centroid before storing it: cosine is scale-invariant
    but `<#>` and `<->` are not, and `l2_normalize()` exists for both `vector` and `halfvec`
    (0.7+). For the other models' rows, `l2_normalize(avg(embedding))` in SQL, filled only when
    every node has a vector under that model, else the mean is biased and the anti-join never
    refreshes it; `avg(halfvec)` is fine at this precision. A binary-quantized clustering model
    (`index_kind = hnsw_bq`) makes every kNN an exact scan of the whole table, O(N²) for a full
    run: refuse it as the clustering model, or add the two-stage Hamming prefilter `hybrid.py`
    uses. No catalog model is affected. With `iterative_scan` on, `hnsw.max_scan_tuples` (20000)
    caps a filtered scan, so a rare `fact_class` can return fewer than `k`; acceptable, and
    `hnsw.scan_mem_multiplier` can be raised if it shows.
12. **Cost, as planned.** Full run: one kNN per node (as #191, but over nodes only) plus growth
    queries only for seeds with an above-threshold neighbour, which are the minority, so it is
    dominated by the neighbour pass, roughly 10–50 minutes at 10⁶ nodes once finding 3 is fixed.
    Incremental: one 5-candidate query and one `fact_emb` insert per new node, plus a model call
    per loose attach. Level 1: pairwise inside a document in SQL, at most n² per document; a
    thread of 2000 facts is 2M distances, about a second.
13. **Graph.** `finish()` sets `distilled_fact_id` on restatements too (so the Facts page and
    the backfill keep working), so the `SUPPORTS` projection must add `restates_fact_id IS
    NULL`, and `RESTATES` carries `similarity` from `restates_similarity`.

### Corrections to the earlier sections

- "Its weak spots" above: the corpus-wide neighbour pass is now a full-run cost only; the
  incremental run does not pay it. The MAX_PAIRWISE fallback no longer applies at level 2
  (groups are grown, not linked), and at level 1 it is bounded by a document's size.
- Recommendation 2 (the watermark) is replaced by the two-level plan.
- Recommendation 3 (the exact-text pre-pass) is done at level 1 and should also be done across
  the corpus (finding 2).
- Recommendation 4 (calibrate per model) still stands, and now covers `seed_threshold`,
  `max_drift` and `tight_similarity` as well as `threshold`.
