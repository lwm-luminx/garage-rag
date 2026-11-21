---
name: search-garage
description: Search the person's Garage, their own index of documents, code, mail and messages on their computer, and answer from it with sources. Use when they ask about their own notes, files, projects, mail, messages or what they wrote, or say "in my Garage", "my documents" or "did I ever".
---

# Search the person's Garage

Garage is the person's own search engine over their documents, code and communications, kept on their computer.
Its MCP server (`garage`) offers these read-only tools:

| Tool | Use it to |
| --- | --- |
| `rag_search` | Find passages: hybrid semantic and keyword search, with filters. Start here. |
| `rag_get_document` | Read a whole document past its snippet, by `document_id` (or `location`). |
| `rag_list_sources` | See which folders, mailboxes and repositories are indexed, with their slugs. |
| `rag_list_authors` | See who wrote what, most documents first. |
| `rag_stats` | See what the corpus holds and whether embeddings are complete. |
| `rag_ask`, `rag_agent` | Have Garage's own local model answer. Use only when the person asks for that. |

## How to search

1. Turn the question into a short query of the words a matching passage would use. Search once broadly
   (`limit` 10), then narrow with filters or a second wording rather than paging.
2. Pick filters from what the person asked:
   - `trust: "authored"` for what they wrote or concluded themselves; `"received"` for what others sent them;
     `"reference"` for outside material.
   - `corpus_class`: `"document"` for prose, `"code"` for source and config, `"communication"` for mail and
     messages. Keep code out of prose answers unless they asked about code.
   - `direction: "sent"` for their own words in message threads, `"received"` for what others wrote to them.
   - `source` (a slug from `rag_list_sources`) or `author` when they name a place or a person.
   - `mode: "fts"` for an exact name, number or phrase; the default `hybrid` otherwise.
3. When a hit looks right but the snippet stops short, read the document with `rag_get_document` and its
   `document_id`. Lower `max_chars` for a long document unless you need all of it.
4. If nothing comes back, try other words once, then check `rag_stats` (embeddings may still be coming, so try
   `mode: "fts"`) and `rag_list_sources` (the folder may not be indexed). Say what you tried.

## How to answer

- Answer from the passages, and name where each fact came from: the document's title, or its file name from
  `location`, and the author or sender when it matters. Don't present a guess as something the Garage says.
- Keep quotes short. Mail and messages are private: quote only what the question needs.
- Say when sources disagree, and prefer the newer or the person's own (`authored`) one, saying which you chose.
- If the Garage holds nothing on it, say so plainly before you add anything from general knowledge.
