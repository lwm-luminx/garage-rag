# Graph Stores

Where the graph lives matters less than people think and more than vendors admit. The honest ordering for personal and agent scale runs from plain text upward, not from database downward.

## Wikilinks as the graph

A folder of markdown files where `[[Page]]` links are edges is a knowledge graph. It is the pattern this whole site is built on: entities are pages, relationships are links — typed, if you follow [typed links](../05-graphs/typed-links.md) — and the store is the filesystem. An agent queries it with grep and link-following; you query it in Obsidian. No server, no driver, no migration, and the graph is readable by the person who owns it. At a few thousand nodes this is not a compromise. It is the correct choice.

## NetworkX in files

When you need algorithms — PageRank, community detection, centrality — load the graph into [NetworkX](https://networkx.org) and persist it as GraphML or JSON alongside your notes. In-memory Python, no infrastructure, fine into the tens of thousands of nodes. Several [GraphRAG](graphrag.md) implementations use exactly this as their default backend, which tells you what scale they actually expect.

## Embedded databases, and the Kuzu lesson

Kuzu was the obvious embedded choice — DuckDB-for-graphs, Cypher, a single file. Then Kùzu Inc. was acquired by Apple and the [repository](https://github.com/kuzudb/kuzu) was archived in October 2025 with 0.11.3 as the final release. It still works, community forks exist, but the episode is the argument for the layers above: an MIT licence saved the code, and plain files would have needed no saving. The [post-Kuzu landscape](https://gdotv.com/blog/kuzu-legacy-embedded-graph-database-landscape/) is still sorting itself out.

## Servers: Neo4j and FalkorDB

[Neo4j](https://neo4j.com) is the incumbent: Cypher, the largest ecosystem, first-class integrations in every framework, and a free tier that covers personal use. The cost is operational — it is a server, and you now run one. [FalkorDB](https://www.falkordb.com/) is the lighter alternative, a Redis-module graph database aimed squarely at GraphRAG workloads, with its own actively developed SDK. Reasonable when an agent fleet shares one graph and query latency matters.

## What fits what

- One person, curated corpus: wikilinks. You are reading the proof of concept.
- Personal corpus plus graph algorithms: NetworkX over exported links.
- Single-agent memory: whatever your memory library defaults to — [Graphiti](https://github.com/getzep/graphiti) wants Neo4j or FalkorDB, others bundle NetworkX. See [tools](tools.md).
- Multi-agent, shared, concurrent writes: a real server, and now you have a database to operate.

Choose the store after the extraction pipeline works, not before. A graph in files can move to Neo4j in an afternoon; the reverse migration is how projects discover their graph was never worth the server. The threshold logic is in [why graphs](why-graphs.md).
