# Build: Put It in the Loop

Part three. The graph exists and answers questions; now the agent has to reach it without you in the middle. No MCP server, no framework — the tool interface is "shell out to a script that prints text", which Claude Code already does natively and which survives every framework migration.

## A slash command, not a server

Drop this in the vault as `.claude/commands/connects.md`:

```markdown
---
description: What connects two pages
---

Regenerate the edge list with `python scripts/graph_export.py . edges.csv`,
then run `python scripts/graph_query.py connects` with the two page names
from $ARGUMENTS, each in quotes. Explain the chain in one short paragraph,
naming the edge types, and say plainly if nothing connects them.
```

Now `/connects "Jerry Liu" "Lost in the Middle"` gives the agent a computed chain to explain instead of an association to invent. Regenerating the export first matters: the agent edits pages constantly, and a query over yesterday's CSV answers about yesterday's vault. The typed edges go stale slower — re-run the extraction pass from [Build: Extract the Graph](build-extract.md) monthly, or after a big ingestion batch.

The deeper change is in the agent's standing instructions. Add one line to the vault's `CLAUDE.md`:

```text
Before answering any question about how two topics relate, run
scripts/graph_query.py connects with both page names and ground
the answer in the chain it returns.
```

That turns the graph from a tool the agent can use into one it does use — the difference between owning a reference book and citing it.

## The weekly health check

Graphs rot, and [why graphs](why-graphs.md) is blunt that a stale graph is worse than none. So the graph gets a maintenance loop like everything else in the vault. Run this weekly, by hand or on a schedule:

```text
Run python scripts/graph_export.py . edges.csv, then
python scripts/graph_query.py communities. Report three things:

1. Orphans: pages under wiki/ that appear in no edge at all
   (compare filenames against the nodes in edges.csv). Propose a
   page each should be linked from, or flag it for deletion.
2. Weak clusters: communities of three pages or fewer that are not
   from this week's ingestion. Say whether each should be linked
   into a larger cluster or left to grow.
3. One bridge worth building: the two largest communities with no
   typed edge between them, and the page or link that would
   connect them.

Keep the report to ten lines. Do not change anything without asking.
```

Orphans are capture failures, weak clusters are themes that never took, and the missing bridge is usually the most interesting line in the report — two bodies of knowledge you own that have never met. The read-only rule matters: a health check that silently rewires links is how a vault stops being yours.

## When to graduate

Signals that the CSV-and-NetworkX layer is no longer enough, in the order they tend to arrive:

- Queries need history — "what did I believe in March" — and flat edges have no timestamps.
- Several agents write concurrently, and last-write-wins on a CSV starts eating edges.
- The reload takes seconds instead of milliseconds, somewhere past tens of thousands of nodes.

Each is an entry on the ladder in [graph stores](graph-stores.md), and the migration is an afternoon because the edge list is the interchange format everything imports. Until a signal actually fires, stay where you are: the whole layer is two scripts, one prompt and two CSVs, and every part of it is readable by the person who owns it.

## What you have

An extractor, a query tool, a slash command and a maintenance loop — a working GraphRAG-lite over your own notes for the cost of an evening. If the appetite grows from here, the surveyed frameworks in [tools](tools.md) are the same shape, scaled up.
