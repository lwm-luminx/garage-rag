# Building Graphs with LLMs

Extraction is the whole game. A graph store will faithfully persist whatever you put in it; whether that is knowledge or noise is decided in the pipeline. This page is the practical shape of that pipeline.

## Schema before extraction

Unconstrained extraction produces a junk drawer: `WORKS_AT`, `WORKS_FOR`, `EMPLOYED_BY` as three different edges for one fact. Decide the ontology first, even a small one — five entity types and ten relation types cover most personal and agent corpora. Every serious tool lets you pass this as a constraint: LangChain's [LLMGraphTransformer](https://reference.langchain.com/python/langchain-neo4j/graph_transformers/llm/LLMGraphTransformer) takes `allowed_nodes` and `allowed_relationships`; LlamaIndex's [property graph index](https://developers.llamaindex.ai/python/framework/module_guides/indexing/lpg_index_guide/) has a `SchemaLLMPathExtractor` that enforces types at extraction time.

Start narrower than feels right. Widening a schema later is cheap; collapsing a zoo of near-duplicate predicates is not.

## The extraction pass

The mechanics are stable across tools: chunk the source, prompt the model for typed triples plus a short description per entity, keep the provenance — which chunk, which document, which date each triple came from. Provenance is what lets you answer "why does the graph believe this" and delete edges when a source is retracted. Structured output modes make the parsing reliable; the residual failure is semantic, not syntactic, so sample and read a few dozen triples per batch rather than trusting the pass rate.

## Incremental updates

The original [GraphRAG](graphrag.md) pipeline assumed batch re-indexing, which is unaffordable for a corpus that changes daily. The current generation is built incremental-first. [Graphiti](https://github.com/getzep/graphiti) is the strongest design here: each new episode is extracted, checked against the existing graph, and contradicting edges are not deleted but marked invalid with a timestamp — the graph keeps both "true until March" and "true since March". For agent memory, that temporal layer is the difference between a memory and a cache.

## Dedup and entity resolution

The same person arrives as `J. Smith`, `John Smith` and `john from ops`. Merge policy, in rising cost order: exact and normalised name matching; embedding similarity over entity descriptions with a threshold; an LLM adjudicating candidate pairs. Do the cheap tiers first and send only the ambiguous residue to the model. Resolve at write time — dedup as a later batch job means every query until then sees a fractured graph.

## Keep the loop small

Extract a hundred documents, look at the graph, fix the schema, re-run. The pipelines that fail are the ones that process the whole corpus before anyone looks. Where the result lives — embedded database, files, or plain wikilinks — is the subject of [graph stores](graph-stores.md), and the off-the-shelf implementations are surveyed in [tools](tools.md).
