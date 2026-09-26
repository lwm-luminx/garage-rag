# Build: Extract the Graph

An evening-sized build in three parts: a queryable graph layer over the vault your agent already maintains. This page gets you from a folder of markdown to two edge files; [Build: Query It](build-query.md) loads them into NetworkX, and [Build: Put It in the Loop](build-use.md) hands the queries to the agent.

The premise comes from [why graphs](why-graphs.md): a wiki with curated links already is a knowledge graph. What it lacks is types — every edge says "related", none says how. So the plan is mechanical export of the plain link graph, then one typed pass by Claude Code over the pages.

## The link graph in one command

The repo ships `scripts/graph_export.py`, stdlib only. Run it at the vault root:

```
python scripts/graph_export.py . edges.csv
```

Use `python3` on a Mac; on Windows that name is usually the Store stub. The script walks every page outside hidden, template and script folders, resolves `[[wikilinks]]` case-insensitively against filenames, and writes:

```csv
source,target
GraphRAG,RAG
Lost in the Middle,RAG
```

Links to pages that do not exist are dropped, which is right for this build: an edge to nowhere is a gap to fix, not a relationship to query. `--format graphml` produces the Gephi version instead — see [tools](tools.md) for what to do with that.

## Schema before extraction

[Building graphs with LLMs](building-graphs-with-llms.md) says decide the ontology first, and that holds at vault scale. Six edge types cover a corpus where the pages are people, tools, papers and claims. More types means more wrong choices per link, so resist adding a seventh until the sixth has earned its place.

## The extraction prompt

Run this in Claude Code at the vault root:

```text
Read every markdown page under wiki/, skipping templates and raw.
Build a typed edge list on top of the plain wikilinks.

For each page, note its type from the frontmatter (person, tool,
claim, concept, paper, note). Then emit one row per relationship
you can ground in the text, using only these edge types:

  built        person -> tool
  authored     person -> paper or claim
  uses         page -> tool
  supports     paper or claim -> claim
  contradicts  paper or claim -> claim
  extends      page -> page

Rules:
- Source and target must both be existing page names, spelt
  exactly as the filenames are, without the .md.
- Only record what a page states. If the relationship is your
  inference rather than the page's claim, skip it.
- Append rows to typed_edges.csv with the header
  source,target,type,found_in — where found_in is the page the
  relationship was stated on.

Work in batches of twenty pages and append after each batch, so
an interruption keeps partial work. When finished, report the row
count and the five most connected nodes.
```

Two lines do most of the work. Restricting endpoints to existing page names keeps the typed edges in the same namespace as the link graph, so both files load into one structure in the next step. And "only record what a page states" is the vault's typed-links rule: an agent inferring relationships produces a graph that quietly encodes its own assumptions.

## What comes out

```csv
source,target,type,found_in
Jerry Liu,LlamaIndex,built,Jerry Liu
RAG,LlamaIndex,uses,RAG
Lost in the Middle,Long context replaces RAG,contradicts,Long context replaces RAG
```

The `found_in` column is provenance — the answer to "why does the graph believe this". If you want richer provenance, ask for JSONL instead: one object per line, same fields plus a `quote` key holding the sentence the edge came from. CSV is what the next page loads, so keep that as the primary output.

## Read it before you trust it

Sample twenty rows against the pages they came from before moving on. Expect a few edges that are technically grounded but useless, and the odd direction flipped. Fix the prompt, not the rows, and re-run — the pass over a few hundred pages costs minutes. Then load the result in [Build: Query It](build-query.md).
