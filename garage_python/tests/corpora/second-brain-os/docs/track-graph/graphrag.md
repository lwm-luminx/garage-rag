# GraphRAG

GraphRAG is retrieval-augmented generation where the index is a graph built from the corpus, not a pile of embedded chunks. The canonical version is Microsoft Research's 2024 paper [From Local to Global](https://arxiv.org/abs/2404.16130), which targeted the question vector RAG answers worst: queries about the corpus as a whole.

## The pattern

Four stages, all at indexing time:

1. **Entity extraction.** An LLM reads every chunk and emits entities and relationships, usually as `(subject, predicate, object)` triples with descriptions.
2. **Graph construction.** Triples are merged into a graph; duplicate entities are resolved.
3. **Community detection.** A clustering algorithm (Leiden, in the original) finds densely connected neighbourhoods.
4. **Community summaries.** An LLM writes a report for each community, hierarchically, so the corpus has summaries at several zoom levels.

Local queries walk the graph from matched entities. Global queries map over community summaries and reduce to one answer — which is why "what are the main themes" finally works.

## Microsoft GraphRAG and its successors

The [microsoft/graphrag](https://github.com/microsoft/graphrag) repository is now in maintenance mode: bug fixes and CVE patches, no new features. Treat it as the reference implementation to read, not the framework to adopt.

The interesting work moved to cheaper descendants. [LazyGraphRAG](https://www.microsoft.com/en-us/research/blog/lazygraphrag-setting-a-new-standard-for-quality-and-cost/) defers nearly all LLM work to query time — no upfront summarisation — at a claimed 0.1% of the original's indexing cost, though it shipped into Microsoft's Azure products rather than the open library. In open source, [LightRAG](https://github.com/HKUDS/LightRAG) (EMNLP 2025, still actively developed) keeps a dual graph-plus-vector index with incremental updates, and [fast-graphrag](https://github.com/circlemind-ai/fast-graphrag) swaps community summaries for PageRank traversal. Most new 2026 deployments pick one of these; the [tools](tools.md) page surveys the field.

## Costs and trade-offs

The original pipeline is expensive in a specific way: every chunk passes through an LLM at ingest, then every community gets summarised, then re-summarised up the hierarchy. Indexing a modest corpus costs real money, and re-indexing after edits costs it again. That is the tax the successors exist to avoid — lazy evaluation, incremental updates, or skipping summaries entirely.

The quieter trade-off is fidelity. Extraction flattens nuance into triples; a hedge, a date qualifier or an attribution can vanish. Community summaries are summaries — they inherit every failure mode of asking a model to compress text it does not understand. GraphRAG answers global questions vector RAG cannot, but its answers are one more model-generated layer away from your sources.

## When it earns its keep

Large, uncurated corpora with genuine multi-hop and thematic questions — see [why graphs](why-graphs.md) for the threshold test. For a curated personal vault, you have already done the extraction by hand; what remains useful is the pipeline's shape, covered in [building graphs with LLMs](building-graphs-with-llms.md).
