# Build: Query It

Part two of the build. [Build: Extract the Graph](build-extract.md) left two files at the vault root: `edges.csv` with the plain links and `typed_edges.csv` with the typed pass. This page turns them into answers, in a little over forty lines of Python.

The store is NetworkX in memory, loaded fresh from the CSVs on every call — the second rung on the ladder in [graph stores](graph-stores.md). No server, no schema migration, and at personal-vault scale a full load takes milliseconds. One dependency:

```
pip install networkx
```

NetworkX 3.7 at the time of writing; anything in the 3.x line works.

## The script

Save this as `scripts/graph_query.py` in the vault:

```python
#!/usr/bin/env python3
"""Query the vault graph. Reads edges.csv and typed_edges.csv from the
current directory.

Usage:
    python graph_query.py neighbors "Page"
    python graph_query.py path "Page A" "Page B"
    python graph_query.py communities
    python graph_query.py connects "Page A" "Page B"
"""
import csv
import os
import sys

import networkx as nx

FILES = ["edges.csv", "typed_edges.csv"]


def load():
    g = nx.DiGraph()
    for name in FILES:
        if not os.path.exists(name):
            continue
        with open(name, encoding="utf-8") as fh:
            for row in csv.DictReader(fh):
                g.add_edge(row["source"], row["target"],
                           type=row.get("type", "links-to"))
    return g


def neighbors(g, node):
    out = [f"-> {t} ({g.edges[node, t]['type']})" for t in sorted(g.successors(node))]
    out += [f"<- {s} ({g.edges[s, node]['type']})" for s in sorted(g.predecessors(node))]
    return "\n".join(out) or "No links."


def path(g, a, b):
    try:
        return nx.shortest_path(g.to_undirected(as_view=True), a, b)
    except (nx.NetworkXNoPath, nx.NodeNotFound):
        return None


def communities(g):
    found = nx.community.label_propagation_communities(g.to_undirected())
    groups = sorted((sorted(c) for c in found), key=len, reverse=True)
    return "\n".join(f"[{len(c)}] " + ", ".join(c) for c in groups)


def connects(g, a, b):
    p = path(g, a, b)
    if p is None:
        return f"Nothing connects {a} and {b}."
    hops = []
    for s, t in zip(p, p[1:]):
        d = g.get_edge_data(s, t)
        hop = f"{s} -[{d['type']}]-> {t}" if d else f"{s} <-[{g.edges[t, s]['type']}]- {t}"
        hops.append(hop)
    return "\n".join(hops)


if __name__ == "__main__":
    g = load()
    cmd, args = sys.argv[1], sys.argv[2:]
    if cmd == "neighbors":
        print(neighbors(g, args[0]))
    elif cmd == "path":
        print(" -> ".join(path(g, args[0], args[1]) or ["No path."]))
    elif cmd == "communities":
        print(communities(g))
    elif cmd == "connects":
        print(connects(g, args[0], args[1]))
    else:
        print(__doc__)
```

Design notes, briefly. Loading typed edges after plain ones means a typed edge overwrites the `links-to` between the same pair — deliberate, since the typed edge is the better description of the same link. Paths run over an undirected view, because "how do these relate" does not care which page linked which. And label propagation stands in for the Leiden step in [GraphRAG](graphrag.md): cruder, but stdlib-plus-NetworkX and instant at this scale.

## What each command answers

```
$ python scripts/graph_query.py neighbors "RAG"
-> GraphRAG (links-to)
-> LlamaIndex (uses)
<- GraphRAG (extends)
<- Lost in the Middle (links-to)

$ python scripts/graph_query.py communities
[4] GraphRAG, Long context replaces RAG, Lost in the Middle, RAG
[2] Jerry Liu, LlamaIndex
```

`neighbors` is the one-hop view of a page, both directions, with the relationship named. `communities` is the theme layer: each line one cluster, largest first.

## What connects X and Y

The reason this build exists. `connects` returns the shortest chain between two pages with every hop typed:

```
$ python scripts/graph_query.py connects "Jerry Liu" "Lost in the Middle"
Jerry Liu -[built]-> LlamaIndex
LlamaIndex <-[uses]- RAG
RAG <-[links-to]- Lost in the Middle
```

That is a multi-hop join, computed rather than guessed — the exact question [why graphs](why-graphs.md) says vector retrieval fails on. It is also a plain function taking two strings and returning a string, which is precisely the shape an agent tool wants. Wiring that up is [Build: Put It in the Loop](build-use.md).
