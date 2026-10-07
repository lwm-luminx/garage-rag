# Garage UI test coverage gaps (PR #102 head 6febee6d)

The suite has 42 XCUITests across 10 files. Of those, 37 pass on the M4 and 5 are store Mail/Messages tests that cannot run until xctrunner gets the "access data from other apps" permission. This compares the tests with the sidebar pages (ContentView: Status, Sources, Models, MCP Server, Documents, Facts, Search, Database, Logs), the menu bar, and the launch flows.

## The biggest gap: nothing runs with a model

No UI test starts an inference server, so every path that needs a model goes unexercised end to end:
- search that returns results (only "no model registered" is tested);
- embedding backfill, and the Status counts moving as it runs;
- fact distillation (Glean Facts), and the Facts page listing what it produced;
- MCP Server "Try it" and the rag_ask/rag_generate playground;
- loading a model on demand (#87).

LlamaTestSupport's MockLlamaServerEngine already fakes llama-server for the unit tests. A launch argument that points LlamaXPCService at it, or a tiny GGUF such as //ext/nomic_embed's Q2_K, would open all of these to UI tests.

## Pages with no UI test at all

| Page or surface | What is untested |
|---|---|
| Documents | the list after an ingest, the detail with chunks and facts, and filtering |
| Facts | listing, search, class and source filters, the excerpt with its grounded span |
| Fact prompts (Models page, FactPromptsSection) | adding, editing, enabling and deleting a prompt, and Run |
| Menu bar item and popover | status summary, quick search, opening pages from the popover |
| Check for Updates (Developer ID) | the menu item and the Sparkle sheet |

## Pages covered only thinly

| Page | Covered | Missing |
|---|---|---|
| Search | the empty state without a model | queries, results, opening a hit |
| Logs | opening the bug reporter from Logs | the log table filling, filters, clearing |
| Models | the overview, Manage buttons, segment tabs, the toolbar on an empty registry | Add Model (catalog and custom), downloads and their progress, removing a model, setting the default, embedding inspection |
| MCP Server | details, stop/start, the list of assistants | installing or removing a client registration, Try it |
| Setup assistant | it shows when setup is incomplete, and the data page fits | the full walk: sources, models, MCP clients, Finish and Skip |
| Bug reporter | opening and cancelling | redaction preview, and composing a report |
| Sources | add/remove, sync, scan & ingest, toolbar state, name from folder | presets other than a plain folder (outside the store tests), cancel mid-scan, a source's error state |
| Database | status, details, stop/start, migrations, cancelling reset, reset hand-over | none worth adding |

## Store build only

StoreMailMessagesUITests (5) covers the sandbox's view of ~/Library/Mail and ~/Library/Messages, but none of it has run yet (setup fails with EPERM on the App Group folder). No UI test covers the sandboxed build's folder-access (security-scoped bookmark) flow for an ordinary folder.

## Suggested order

1. Grant xctrunner the permission, so the 5 store tests run at all.
2. A mock or tiny-model server for UI tests, then search results, backfill and Facts.
3. Documents and Facts page tests on an ingested fixture folder. SourcesUITests already builds one.
4. The full setup-assistant walk.
5. The menu bar popover.
