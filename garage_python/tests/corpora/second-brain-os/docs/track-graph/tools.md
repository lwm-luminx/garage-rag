# Tools

The ecosystem survey, as of September 2026. The field consolidated hard in 2025: the batch-indexing generation went quiet and the incremental, memory-oriented generation took over.

## Memory and graph-RAG frameworks

- [Graphiti](https://github.com/getzep/graphiti) — temporal knowledge graphs for agent memory, from Zep. Every edge carries a validity window, contradictions invalidate rather than overwrite, and point-in-time queries work. The strongest option for long-running agents; backs Zep's hosted [memory platform](https://www.getzep.com).
- [Cognee](https://github.com/topoteretes/cognee) — self-hosted memory engine combining graph and vector in one pipeline, with a growing integration ecosystem (n8n, agent frameworks) and a Rust core in progress. Active and well maintained.
- [LightRAG](https://github.com/HKUDS/LightRAG) — the pragmatic GraphRAG: dual graph-plus-vector index, incremental updates, multiple storage backends (Neo4j, PostgreSQL, MongoDB). EMNLP 2025 paper, still under active development.
- [fast-graphrag](https://github.com/circlemind-ai/fast-graphrag) — Circlemind's PageRank-driven take; skips community summaries for cheap traversal.
- [microsoft/graphrag](https://github.com/microsoft/graphrag) — the original, now maintenance-mode. Read it, do not build on it; context in [GraphRAG](graphrag.md).

## Framework integrations

- [LlamaIndex property graph index](https://developers.llamaindex.ai/python/framework/module_guides/indexing/lpg_index_guide/) — the most complete framework-native option: pluggable extractors (schema-enforced or free-form) and retrievers over any property graph store.
- [LangChain LLMGraphTransformer](https://reference.langchain.com/python/langchain-neo4j/graph_transformers/llm/LLMGraphTransformer) — documents in, graph documents out. Note it moved from `langchain-experimental` into the `langchain-neo4j` package; old import paths are dead.
- [Neo4j LLM Knowledge Graph Builder](https://neo4j.com/labs/genai-ecosystem/llm-graph-builder/) — a hosted point-and-click pipeline from PDFs, web pages and YouTube transcripts to a Neo4j graph. Good for a first look at what extraction does to your material before writing any code.
- [FalkorDB GraphRAG-SDK](https://github.com/FalkorDB/GraphRAG-SDK) — ontology-first SDK over FalkorDB, production-stable and iterating quickly.

## Visualisers

[Gephi](https://gephi.org) remains the workhorse for offline analysis of an exported graph — load GraphML, run layout and community colouring, find the structure you did not know was there. Neo4j's bundled Browser and Bloom cover the database-native case.

## Obsidian graph tooling

The built-in graph view is a painting, not an instrument; plugins do the real work. [InfraNodus](https://github.com/noduslabs/infranodus-obsidian-plugin) adds proper network analysis over a vault — topical clusters, centrality, structural gaps — plus AI question generation over the gaps. [Extended Graph](https://www.obsidianstats.com/plugins/extended-graph) upgrades the native view with filtering and per-type styling. The Obsidian Hub keeps a current [graph plugins list](https://publish.obsidian.md/hub/02+-+Community+Expansions/02.01+Plugins+by+Category/Graph+plugins).

## Choosing

Agent memory: Graphiti or Cognee. Query a document corpus: LightRAG. Already inside LlamaIndex or LangChain: their native extractors, writing to a store from [graph stores](graph-stores.md). Curated vault: your links are the graph; add InfraNodus when you want the analytics.
