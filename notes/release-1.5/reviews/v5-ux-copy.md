# Garage 1.5 review: UX copy and accessibility (copy half), at 0a35384

**Verdict: OK to ship once the Should-fix items are done.** These are copy-only changes: several help texts say things that are not true, and the built-in engine and the gRPC backend each go by three or four names. There are no typos, no Intel or x86 strings, and only two real VoiceOver gaps.

Paths are relative to `macapp/Sources/GarageApp/` unless they start with `docs/` or `macapp/`.

## Should fix (18)

### Help text that is wrong

| # | Where | Current | Proposed |
|---|---|---|---|
| 1 | `Services/VolumeAccessService.swift:65,67` (copy in `macapp/Sources/IngestClient/IngestEngine.swift:386,388`) | "Full Disk Access in System Settings **or** selecting the Messages directory directly is required…" (and the same for Mail) | Selecting a folder does not satisfy TCC for Messages or Mail, so Full Disk Access is always needed, and the Store build also needs the disk or folder grant. Proposed: "macOS protects Messages (~/Library/Messages). Turn on Full Disk Access for Garage in System Settings, then select your startup disk or the Messages folder so Garage can open it." Mail: the same wording with Mail. |
| 2 | `Views/FirstRunView.swift:454` | "…and macOS will ask for Full Disk Access before Garage can read them." | macOS never prompts for Full Disk Access. Proposed: "…Garage can read them only after you turn on Full Disk Access for it in System Settings → Privacy & Security." |
| 3 | `Views/SourcesView.swift:317` | "Embedding and facts wait for the next automatic update." | Scheduled maintenance stops after embedding (`runPipeline(gleansFacts: false)`), and with Automatic Updates off nothing ever runs. Proposed: "Count what every source holds, then index what is new or changed. Use Update Everything to also embed and glean facts." |
| 4 | `Views/FirstRunView.swift:669` | "…embedding starts automatically once a model is on disk." | No code runs a backfill when a download finishes. Embedding happens only after an ingest. Proposed: "…Garage embeds after each ingest; if a download finishes later, use Embed All on the Models page." |
| 5 | `Views/FactsView.swift:225` | "Choose Glean Facts on a document, or run Enrich Facts, to distill documents into facts." | The app has no "Enrich Facts" control. Proposed: "Nothing has been gleaned yet. Choose Glean Facts on a document, or on the Models page's Distillation tab." |
| 6 | `Views/SourcesPresentation.swift:391`, `Services/VolumeAccessService.swift:729-732` | "Ask macOS…" opens Garage's own alert, which reads "Permission Required: Messages (apple-sms)" and "…grant folder access directly via Open Panel…" | Button: "Explain…". Alert title: "Garage needs permission to read Messages". Alert body: "…Select the folder, or turn on Full Disk Access in System Settings." |
| 7 | `GarageApp.swift:32` + `Services/BugReport.swift:11` | Help menu item "Garage Support Guide" opens `troubleshooting.html` | Either link it to `/support/guide.html` or rename the item "Troubleshooting Guide". |
| 8 | `Views/DatabaseView.swift:303` | "Check for Updates" (in the schema ⋯ menu) | This clashes with the app menu's Sparkle "Check for Updates…". Proposed: "Check for Schema Updates". |

### The same thing under different names

| # | Thing | Current names (file:line) | Proposed |
|---|---|---|---|
| 9 | The llama.cpp engine | "Llama XPC": `Views/ModelsView.swift:57,182,377`, `Views/ModelsView+ModelRow.swift:80,220`, `Views/ModelsView+AddModel.swift:119`, and "via Llama XPC" on the Overall tab. "Inference": `Views/StatusPagePresentation.swift:799`. "Llama can't be reached": `:289`. "LLaMa": `Views/LogsView.swift:17`. "built-in engine": every docs page. | Use **"Built-in engine"** everywhere: `displayName`, the Providers row, "Loaded in the built-in engine", "Built-in engine can't be reached", Logs tab "Built-in Engine", Status helper "Built-in Engine". |
| 10 | The Python backend | "Index Manager": `Views/StatusView+Services.swift:11`, `Views/StatusPagePresentation.swift:838`. "Pipeline service" / "Starting the gRPC bridge…": `Services/FirstRunCoordinator.swift:151-152`. "gRPC Server": `Views/LogsView.swift:16`. "gRPC backend": `Views/StatusView+Services.swift:54`. "MCP and gRPC servers": `Views/DatabaseView.swift:160`. | Use "Index Manager" everywhere. First-run detail: "Starting the service that runs ingest, search and models". Logs tab: "Index Manager". Database help: "…with the MCP server and Index Manager". |
| 11 | "via gRPC" shown to users | `Views/DocumentsView.swift:155`, `Views/FactsView.swift:169`, `Views/SearchView.swift:203,520` ("Loading documents via gRPC…", "Searching via gRPC…"), `Views/SearchView.swift:251` ("…retrieval over gRPC.") | Drop "via gRPC": "Loading documents…", "Searching…", "…using hybrid semantic and keyword search." |
| 12 | Fact extraction | Tab "Distillation", boxes "Fact Distillation", button "Glean Facts", stage "Distill" (`Views/MenuBarStatus.swift:86`), "Distilling facts" (`:357`), log label "Enrich Facts" (`Views/ModelsView.swift:551`, which shows as "No log output has been produced by Enrich Facts yet"), "to distill" / "facts distilled" (`Views/StatusPagePresentation.swift:541,553`) | Keep "Glean Facts" as the verb and "Distillation" as the model tab. Stage: "Glean". Menu bar: "Gleaning facts". Log label: "Glean Facts". Status: "to glean" / "facts gleaned". |
| 13 | Schema migration | Menu bar: "Database needs a migration" / "Open Status to apply it." (`Views/MenuBarStatus.swift:270`), "Migration needed" (`:348`), "Schema needs a migration" (`:402`). Status and Database pages: "needs a schema update" / "Apply Updates". | Menu bar: "Database needs a schema update", "Schema update needed". |
| 14 | MCP clients | Menu bar: "no clients registered" / "1 client" (`Views/MenuBarStatus.swift:249-251,424`). MCP page: "assistants … connected". First run: "Installed agents", "A connected agent", "Agents you connect" (`Views/FirstRunView.swift:84,753,794`) | Use "assistant(s) connected" everywhere, e.g. "Database and MCP running · 2 assistants connected", and "Installed assistants" in the first run. |

### Jargon on screen

| # | Where | Current | Proposed |
|---|---|---|---|
| 15 | `Services/VolumeAccessService.swift:204,206,136`, shown on Sources rows through `Views/SourcesPresentation.swift:176,401` | "Can't be read: TCC permission required (Messages (apple-sms))", "Permission denied / not readable", "Stale bookmark: … (needs re-grant)" | "Needs permission (Messages)", "Garage isn't allowed to read this folder", "Saved access to … no longer works". Also drop the slug from `displayName` (`:18,20`): "Messages", "Mail". |
| 16 | `Views/FirstRunView.swift:476` + `Services/VolumeAccessService.swift:612-613` | "Select Root Hard Drive…" / "…select your root hard drive (e.g. Macintosh HD or root '/')…". Elsewhere the same action is "Select Disk…", "Choose Disk…" or "Choose Another Disk…". | "Select Startup Disk…" / "Select your startup disk (usually Macintosh HD) and click Grant Access." |

### Accessibility (VoiceOver)

| # | Where | Issue | Fix |
|---|---|---|---|
| 17 | `Views/ModelsView+ModelRow.swift:445-452` | The copy-SHA-256 button shows only an icon, with `.help` and no `accessibilityLabel` | `.accessibilityLabel("Copy SHA-256")` |
| 18 | `Views/FirstRunView.swift:524,679,884` | The source, model and assistant cards show selection only with a checkmark icon, so VoiceOver never announces "selected" | `.accessibilityAddTraits(selected ? .isSelected : [])` on each card button, and hide the checkmark image |

## Nice to have (14)

| # | Where | Current | Proposed |
|---|---|---|---|
| 19 | `Views/ModelsView+AddModel.swift:93,119,126,151`, `Views/ModelsView+ModelRow.swift:310` | "Register \(slug)…", "…under this slug", field "Slug", "…differs from the slug" | "Short name" (with help: letters, digits, `-`). The help can say "Register \(preset.name)". |
| 20 | `Views/FactPromptsSection.swift:196` | prompt "source slugs, comma-separated; empty = all" | "source names, comma-separated; leave empty for all" |
| 21 | `Views/FirstRunView.swift:342` | "Garage keeps its database in ~/Library/Application Support/GarageApp." | That path is not real in the App Store (sandboxed) build. Use `Paths.displayPath(of: Paths.pgDataDir)`, or say "in its data folder on this Mac". |
| 22 | `Views/StatusPagePresentation.swift:225`, `Views/MenuBarStatus.swift:286` | "Claude can't reach your corpus…" | "Assistants can't reach your corpus…" (Cursor, VS Code and others connect too) |
| 23 | `Views/SourcesPresentation.swift:389,402` vs `Views/StatusPagePresentation.swift:40` | "Grant Folder Access…" vs "Grant Access…" | Use one label, "Grant Folder Access…" |
| 24 | `Views/MenuBarView.swift:154` vs `Views/SourcesView.swift:313` | "Ingest Now" vs "Scan & Ingest All" for the same run | "Scan & Ingest" in the menu bar, or "Update Everything" if the popover should run the full pipeline |
| 25 | `Views/FirstRunView.swift:694`, `Views/ModelsView+AddModel.swift:58` | badge "1024 DIMS" | "1024 dimensions" or "1024-D" |
| 26 | `Views/DocumentsView.swift:476` | "\(n) tok" | "\(n) tokens" |
| 27 | `Views/FirstRunView.swift:419` | "greyed out" | "dimmed" (US and Apple style) |
| 28 | `Views/StatusView+Services.swift:162,169` | "Call GetStatus, GetVersion, ListModels, ListSources and GetStats" / "The Python GarageService over gRPC: …" | "Ask the Index Manager for its status, models, sources and counts" / "Runs search, documents, sources, models and every operation the app starts." |
| 29 | `Views/Components/DisclosureChevron.swift:9` | The chevron image is not hidden, so VoiceOver reads it beside "Details"; the model row's label is "Show details" with no model name (`Views/ModelsView+ModelRow.swift:136`) | `.accessibilityHidden(true)` on the image. Label the row "Show \(item.name) details". |
| 30 | `Views/SearchView.swift:249` vs elsewhere | "Search Knowledge Base" / "corpus" / "library" / "index" | Pick "corpus" for UI headings, as the menu bar search does ("Search your corpus"). |
| 31 | `Services/VolumeAccessService.swift:75` | "…required for complete system ingestion." | "…required to index folders macOS protects." |
| 32 | `Views/DocumentsView.swift:186`, `Views/FactsView.swift:220`, `Views/SearchView.swift:259` | "Database is offline." | "The database is stopped.", matching the Status and Database pages |

## docs/ (Jekyll site)

| # | Group | Where | Current | Proposed |
|---|---|---|---|---|
| D1 | Should fix | `docs/support/guide.md:228`, `docs/support/index.md:89`, `docs/support/troubleshooting.md:234` | "add **GarageApp**" to Full Disk Access | The app's display name, and the name System Settings lists, is **Garage**. Proposed: "add **Garage**". |
| D2 | Should fix | `docs/support/guide.md:74`, `docs/support/troubleshooting.md:181` | The Logs tabs are listed as "Postgres, App, Ingest, Embed, MCP Server, gRPC Server, LLaMa, Downloader" | The app also has a **Unified Log** tab. Update the list to match the renames in #9 and #10. |
| D3 | Should fix | `docs/support/guide.md:66,69` | "Inference is the built-in model engine"; "the Providers box lists the models the built-in engine has loaded" | The Providers row currently reads "Llama XPC". Fixing #9 makes this correct, so update the wording along with it. |
| D4 | Should fix | `docs/support/troubleshooting.md:188`, `docs/support/contact.md:60` | "**gRPC Server** (search, backfill, facts)" | "**Index Manager** (search, embedding, facts)" |
| D5 | Nice | `docs/support/guide.md:68` | The Sources toolbar is described without **Scan & Ingest All** and **Sync** | Add one clause naming them. |
| D6 | Nice | `docs/support/guide.md:140`, `docs/support/index.md:90` | `garage backfill` is described with no link to the app | Add "(the app's **Embed All**)" once. |

Verified as matching the app: Setup Assistant… (Garage menu), Help → Report a Bug… (⇧⌘B), the menu bar Ingest Now / Stop and ⌘O / ⌘Q, Update Everything, Automatic Updates, Scan & Ingest / Cancel, Add Folder…, Custom Source…, the Models tabs Overall / Embedding / Distillation, Connect / Update / Disconnect, Try It, Back Up… / Restore… / Reset Database… / Back Up First…, Skip setup, and the keychain service name `com.rickmark.garage.postgres`.

Searched and found clean: Intel / x86 / Rosetta (none in the app or docs), and typos (a spell-check of every string literal and support page found none).
