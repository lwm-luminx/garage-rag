# Garage launch drafts (for Rick's approval)

Nothing here has been posted. Edit anything, then say which ones to send.
Common facts used: free, MIT-licensed, v1.5 out now, macOS 14+ on Apple silicon, Mac App Store (TestFlight now) and notarized download,
Garage uploads nothing, assistants get only the excerpts they search for.

## 1. Directory blurb (MCP registry, mcp.so, Smithery, Glama, PulseMCP, AlternativeTo, awesome-mcp-servers)

**Name:** Garage
**Tagline (≤60):** Private local RAG and MCP server for your Mac
**Short (≤160):** Garage indexes your documents, code, notes and messages on your Mac and serves them to Claude and other AI assistants over MCP. Nothing is uploaded.
**Long:**
Garage is a free, open-source Mac app that turns the files you already have into a searchable library for your AI assistant. It indexes folders, git repositories, PDFs, Office documents, scanned images, Apple Mail and Messages into a private PostgreSQL + pgvector database on your Mac, and serves hybrid vector and keyword search over the Model Context Protocol. Claude Desktop, Claude Code, Cursor, LM Studio and any other MCP client can connect with one click. Embeddings and the optional answer model run locally on your Mac through llama.cpp. Garage uploads nothing: your assistant receives only the excerpts it searches for.
**Links:** https://garagerag.app · https://github.com/rickmark/garage-rag
**Categories:** Knowledge & memory, Search, Productivity, Developer tools
**Alternative to (AlternativeTo):** Rewind, Recall, Mem, Khoj

awesome-mcp-servers line (Knowledge & Memory section):
`- [rickmark/garage-rag](https://github.com/rickmark/garage-rag) 🏠 🍎 - Local-first RAG over your Mac's documents, code, Mail and Messages in PostgreSQL + pgvector, with hybrid search served over MCP.`

## 2. Show HN

**Title:** Show HN: Garage – a local RAG and MCP server for everything on your Mac
**URL:** https://garagerag.app
**First comment:**
I built Garage because I wanted Claude to answer from my own notes, code and email without uploading any of it.

It's a Mac app that indexes folders, git repos, PDFs, Office files, scanned images, Mail and Messages into a Postgres + pgvector database it runs itself, and serves hybrid search (vector + full text, fused with Reciprocal Rank Fusion) over MCP. Any MCP client can connect: Claude Desktop, Claude Code, Cursor, LM Studio.

Some things that were fun to build:
- Postgres running inside the App Store sandbox. That needed a flock() data-directory interlock and pthread semaphores in place of System V IPC; I've prepared them as a patch series for upstream Postgres.
- One egress choke point: a single module may import a network client, an AST test enforces it, and communications can never be sent to a host that isn't loopback.
- Authorship attribution from git history, document metadata and mail senders, so search knows what you wrote versus what you received.

It's MIT-licensed, Apple silicon only, and free (there's an optional tip jar in the App Store build). I'd love feedback, especially on retrieval quality and on which file types you'd want next.

## 3. Reddit r/LocalLLaMA

**Title:** I built a local RAG + MCP server for your whole Mac (Postgres/pgvector, llama.cpp embeddings, nothing uploaded)
**Body:** Garage indexes documents, code, PDFs, scanned images, Mail and iMessage on your Mac and serves hybrid search to any MCP client. Embeddings run locally through llama.cpp, or through LM Studio or Ollama if you prefer; each model gets its own pgvector table, so switching models is a backfill, not a re-index. Messages and mail are hard-blocked from ever going to a host that isn't loopback. It's free and MIT-licensed. Feedback welcome: https://garagerag.app (source: https://github.com/rickmark/garage-rag)

## 4. Reddit r/macapps

**Title:** Garage: give Claude (or any AI assistant) private search over your Mac's files, mail and messages
**Body:** It's a native SwiftUI menu-bar app with its own bundled Postgres. You pick folders, it indexes them, and Claude Desktop, Cursor or LM Studio can search them over MCP. Nothing is uploaded. It's free, on TestFlight now and in the Mac App Store soon, with a notarized download at https://garagerag.app. It needs Apple silicon and macOS 14 or later.

## 5. Product Hunt

**Tagline:** Your files, your Mac, your AI. Private RAG over MCP.
**Description:** Use the long directory blurb.
**Maker comment:** A shorter version of the Show HN comment.
**Media:** docs/assets/social-card.png plus the screenshots in /mnt/project-files/appstore-screenshots-1.5-beta/.

## 6. Newsletters (Console.dev, TLDR AI submit forms)

Use the short blurb and the site link.
