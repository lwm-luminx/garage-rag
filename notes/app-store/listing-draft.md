# Garage RAG App Store listing: proposed copy

Drafted 2026-09-25 from the App Store Connect page as the M3 read it (version 1.0, Waiting for Review, build 0.9 (66)). Nothing has been changed in App Store Connect. Character counts are against Apple's limits.

## Name (30): keep

Garage RAG

## Subtitle (30)

Current: Your AI Junk Drawer

Proposed: **Your files, your Mac, your AI** (29)

This matches the garagerag.app headline and says what the app is for. "Junk drawer" undersells it and doesn't say it's private or local.

## Promotional text (170)

Current: Garage RAG is your AI junk drawer.  Use it in conjunction with your favorite tools like LM Studio, Claude, and more to add information to your AI ecosystem.

Proposed (152):

> Index the documents, code and notes on your Mac and let your AI assistant search them over MCP. Runs entirely on your Mac, with no account and no cloud.

Promotional text can change at any time without a new version.

## Description (4000)

Current: two sentences.

Proposed:

> Garage RAG turns the folders on your Mac into a private knowledge base your AI assistant can search. Point it at your documents, notes and code repositories, and it reads them, indexes them and serves them over the Model Context Protocol (MCP) to Claude Desktop, Claude Code, Cursor and other MCP clients.
>
> Everything happens on your Mac. Garage RAG bundles its own PostgreSQL database with pgvector and runs embedding models on the built-in llama.cpp engine, so there's no account, no subscription and no cloud service. If you already run Ollama or LM Studio, Garage RAG can use those instead.
>
> WHAT IT INDEXES
> • Folders of Markdown, text, PDF and Microsoft Office documents
> • Git repositories, with authorship taken from the commit history
> • Scanned images and photos, read with on-device OCR
>
> HOW IT SEARCHES
> Hybrid search combines vector similarity with full-text search, so a question finds passages by meaning and a keyword finds the exact line. Register more than one embedding model and switch between them without re-indexing.
>
> KNOWS WHO WROTE WHAT
> Garage RAG records whether each document was written by you, is reference material, or was received from someone else, along with the evidence for that call.
>
> DISTILLED FACTS
> Optionally, a local language model distills each document into short, sourced facts that your assistant can search alongside the full text.
>
> PRIVATE BY DESIGN
> Garage RAG contains no cloud AI client. Your content goes only to the model servers you configure, and messages never leave your Mac. The app collects no data.
>
> REQUIREMENTS
> A Mac with Apple silicon. Embedding models download on first use and need a few hundred megabytes to a few gigabytes of disk space.

About 1,700 characters. Add "Apple Mail and Messages" to WHAT IT INDEXES only if the store build's Mail and Messages tests pass (checklist item d1). Otherwise guideline 2.1 applies to an advertised feature that doesn't work.

## Keywords (100)

Current: rag, ai, genai, search (22 used)

Proposed (100): mcp,search,semantic,embeddings,local,llm,ai,index,documents,knowledge,private,offline,pgvector,notes

No spaces after commas, and no words from the app name ("garage", "rag"), because Apple already indexes the name. No other companies' product names; Apple rejects those in keywords.

## URLs

| Field | Current | Proposed |
|---|---|---|
| Support URL | https://rickmark.github.io/garage-rag/ | https://garagerag.app/support/ |
| Marketing URL | https://rickmark.github.io/garage-rag/ | https://garagerag.app/ |
| Privacy Policy URL | https://rickmark.github.io/garage-rag/privacy-policy.html | https://garagerag.app/support/privacy-policy.html |

The old URLs probably still resolve: GitHub Pages redirects github.io to the custom domain, and privacy-policy.md has a `redirect_from` for /privacy-policy.html. But the listing should name the real site. I couldn't fetch any of them from the cloud session, so open each once before saving.

## Copyright

Current: Rick Mark - 2026. Apple's convention is year then holder: **2026 Rick Mark**.

## App Review information

- **Contact first name:** "Ricahrd" is misspelled. Fix it to Richard.
- **Notes** (currently empty). Proposed:

> Garage RAG needs no account or sign-in.
>
> Everything runs locally. On first launch the app starts its own PostgreSQL database, which listens only on 127.0.0.1. That, the local MCP server (127.0.0.1:8787) and the local inference server are why the app has the network server entitlement. No inbound connections from other machines are accepted.
>
> To try it:
> 1. Launch the app and follow the setup assistant. It waits for the local services to start.
> 2. Pick a starter source, or add any folder of documents (for example ~/Documents) when macOS asks for access.
> 3. Pick an embedding model. It downloads and runs on the built-in engine, so no other software is needed.
> 4. Choose Scan & Ingest on the Sources page, then search on the Search page.
> 5. Optional: the MCP Server page registers Garage RAG with Claude Desktop or Claude Code, which can then search the indexed folders.
>
> The only network requests the app makes on its own are the model download you choose and a small model catalog from garagerag.app. The privacy policy covers both.

- **Sandbox justification for sustained-execution:** once a 1.5 build signed with the profiles from #103 is attached, this entitlement is gone and the field should disappear. If it's still shown, clear it.

## Screenshots

There are 5, dark mode over a beach wallpaper, from Sep 12 (the 0.9 UI). For 1.5, retake them from the redesigned Status, Sources, Search, Models and MCP Server pages at 2880 × 1800. Use a neutral desktop, and put one light-mode shot in the set.

## What's New (only once a 1.5 version exists)

> Garage RAG 1.5 is a polish release.
> • Redesigned Status, Sources, Models, Database and MCP Server pages, and a new menu bar popover
> • A Facts page for browsing distilled facts
> • HEIC and HEIF images are indexed
> • Unchanged passages keep their embeddings when a document is updated, so re-indexing is faster
> • The database password stays in the Keychain, and the app no longer freezes on a Keychain prompt at launch
> • Many fixes to scanning, ingest and search
