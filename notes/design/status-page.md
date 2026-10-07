# Garage Status page: design (branch claude/project-thread-9t0g3z)

## What the page is for

Status is the page the window opens on. Someone looks at it to answer, in order:

1. Is Garage healthy: database up, MCP serving, and if not, what do I press?
2. Is it doing something right now, and how far along is it?
3. How much of my corpus is indexed: scanned, ingested, embedded, distilled?
4. Rarely, when something is off: are the helper processes alive, and what does a self test say?
   The GarageXPCService "Llama Loader" self test is how a Llama XPC load failure is told apart
   from a dead LlamaXPCService, so it has to stay one click away.

## Critique of the page on `main`

- **The header says "All Systems Operational", then six cards say it again.** Database Running,
  MCP Server Running, Sources Configured & Accessible, Models & Llama Ready, Search Ready, Logs
  Active: each a green check, a headline, a details sentence ("Capturing diagnostic logs across
  all services." checks whether the `garage-mcp` launcher exists) and an "Open Logs ›" button.
  On a healthy Mac that is 400 points of nothing. A card only earns its place when it has a
  problem and a fix.
- **"Corpus & Pipeline Overview" is three metric cards and a table.** Sources / Ingestion Status
  / Chunk Embedding, each with a 24-point number, a progress bar and a caption in the pipeline's
  words ("24 uningested (1,180 of 1,204 docs)", "880 not embedded (9,120 of 10,000 across 1
  model)"), then a per-source breakdown that repeats the Sources page. "Waiting on scan" and
  "Waiting for ingest" are headlines.
- **Progress is split three ways.** Embedding is a card with no counts (the backfill's per-model
  progress went only to its log); distillation appears nowhere on the page, though the menu bar
  and Sources show it as a stage.
- **The "Get Started" quick-add boxes** duplicate the setup assistant and the Sources and Models
  pages' Add sections.
- **"Services & Daemon Health Diagnostics"** is an 800-line debugging panel: seven rows, each
  with a bundle id, a PID badge, a latency badge, "12/12 tests passed", "TEST PASSED", a
  marketing description ("Runs multi-threaded Python ingestion pipelines with crash isolation
  and sandboxed filesystem access."), a bordered Test and a prominent orange Restart, and an
  expander with "Beyond-Ping Functional Test", "In-Service Diagnostics" and four more restart
  buttons (Run Tests, Restart Services, Force Restart, Restart Process). Run All Tests is a
  purple prominent button.
- **Last Command Output** at the bottom is the shared box every page used to write to.

## The design as built

```
Status

╭ Health ─────────────────────────────────────────────────────────────────────╮
│ (✓) All systems go                                                          │
│     Database and MCP running · 2 assistants connected                        │
│  — or, one row per problem, worst first, each with its fix —                 │
│ (!) Database needs a schema update              [Apply Updates] [Database ›] │
│ (!) MCP server not running                      [Start]       [MCP Server ›] │
│ (!) Messages needs permission                   [Grant…]         [Sources ›] │
│ (!) No embedding model                                          [Models ›]   │
│ (!) Last ingest failed                                          [Sources ›]  │
│     notes: permission denied                                                 │
╰─────────────────────────────────────────────────────────────────────────────╯

╭ Indexing ───────────────────────────────────────────────────────────────────╮
│ (✓) Up to date                                          [Update Everything] │
│     1,234 documents in 3 sources · embedded under 2 models · facts distilled  │
│  — while the pipeline runs —                                                 │
│ (⬇) Ingesting notes  42%                                             [Stop] │
│     ▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│     1,204 of 2,860 documents · 1,180 indexed                                 │
│     ~/Notes/2024/retro.md                                                    │
│     Scan › Ingest › Embed › Distill                                          │
│  — behind —                                                                  │
│ (○) 1,204 items to index  87%                           [Update Everything] │
│     ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░ │
│     24 documents to ingest · 880 embeddings to go · 300 documents to distill │
│ ─────────────────────────────────────────────────────────────────────────── │
│ Sources     Documents     Chunks      Embedded     Facts                     │
│ 3           1,234         56,789      98%          4,120                     │
│             12 failed                 2 models     from 1,200 documents      │
╰─────────────────────────────────────────────────────────────────────────────╯

╭ Index Manager ──────────────────────────────────────────────────────────────╮
│ ● Running                                                        [Test]  ›  │
│   On 127.0.0.1:50051 · runs every scan, ingest, embedding and distillation   │
╰─────────────────────────────────────────────────────────────────────────────╯

╭ Helper Services ──────────── Checked 10:42 · [Test All] [Restart All] (↻) ─╮
│ ● Ingest            Running · 12 ms                        [Test] [Restart] › │
│ ● Embeddings        Running · 8 ms                         [Test] [Restart] › │
│ ● Inference         Can't be reached: Couldn't communicate… [Test] [Restart] › │
│ ● Model Downloads   Running · 5 ms                         [Test] [Restart] › │
│ ● MCP Server        Running · 6 ms                         [Test] [Restart] › │
│ ● Garage Backend    Running · 9 ms · 12 of 12 self tests passed  [Test] [Restart] › │
│     ▸ details: ready, up 2h 14m · Python 3.13.7 · managed services · every   │
│       self test with its output (Llama Loader among them) · recent errors ·  │
│       crash report · log file · the functional test's output with Copy       │
│       (⋯) Restart Managed Services, Force Restart Managed Services           │
╰─────────────────────────────────────────────────────────────────────────────╯

▸ Service Output  312 lines            (collapsed; remembered per user)
```

### Health

One row while nothing is wrong: the menu bar's "All systems go" line and its client count.
Otherwise one row per problem, critical first, in the person's words, with the button that fixes
it in place and the page it belongs to a click away. Healthy pages get no row; "in progress" is
not a problem and lives under Indexing.

| Problem | Row | Fix |
|---|---|---|
| Postgres failed | Database couldn't start · the error in red | Try Again |
| Postgres stopped | Database stopped · Search, ingest and the MCP server need it. | Start |
| Pending migrations | Database needs a schema update | Apply Updates |
| MCP failed (database up) | MCP server failed · the error | Try Again |
| MCP stopped (database up) | MCP server not running · Claude can't reach your corpus. | Start |
| MCP check failed | MCP server isn't answering · the error | Test Again |
| No disk access / stale / denied | Garage can't read your disk · reason | Choose Disk… |
| Protected folder | Messages needs permission | Grant… / Open Privacy Settings… |
| Unreadable source path | A source can't be read · the test's message | Check Again |
| Llama XPC error | Llama can't be reached · the error | Try Again |
| No sources | No sources yet · Add a folder to index. | (Sources ›) |
| No embedding model | No embedding model · Search needs one. | (Models ›) |
| Last ingest failed (idle) | Last ingest failed · the error | (Sources ›) |
| garage-mcp launcher missing | Command-line tools missing · path | (Logs ›) |

A database that is down hides the MCP problem it causes, as the popover does.

### Indexing (was "Chunk Embedding"; Rick's backlog note of 2026-09-25)

One headline, one bar, one line of what is left, one action. The bar covers the three stages
together, each weighted equally where it applies: ingest (documents against the scan's count),
embed (vectors against chunks × registered models) and distill (documents whose every applicable
enabled prompt has a `fact_runs` row with the prompt's current hash, the document's current text
and the facts model, the test `enrich-facts --stale-only` makes, against documents, only while a
facts model is configured). A corpus with no
embedding model skips the embed stage here; the Health box says a model is missing.

| State | Title | Line | Bar | Action |
|---|---|---|---|---|
| No sources | Nothing to index yet | Add a folder on the Sources page… | | Add a Source… |
| Never scanned | Not indexed yet | 2 sources · Update Everything scans, ingests, embeds and distills them. | | Update Everything |
| Scanning | Scanning all sources… | 1,234 items so far | moving | Stop |
| Ingesting | Ingesting notes · 42% | 1,204 of 2,860 documents · 1,180 indexed · current file | fraction | Stop |
| Embedding | Embedding with bge-m3 · 91% | 9,120 of 10,000 chunks | fraction (from the backfill's own events) | Stop |
| Distilling | Gleaning facts · 3% | 30 of 1,000 documents · current document | fraction | Stop |
| Waiting | Waiting to scan notes, mail | Each source gets its own scan… | moving | Stop |
| Behind | 1,204 items to index · 87% | 24 documents to ingest · 880 embeddings to go · 300 documents to distill | combined | Update Everything |
| Up to date | Up to date | 1,234 documents in 3 sources · embedded under 2 models · facts distilled | | Update Everything |
| Last run failed | Up to date / behind, plus the error under the line in red | | | |

The stage trail (Scan › Ingest › Embed › Distill) appears under the bar while a run is on, as in
the menu bar and on Sources; all four stages are always listed (the menu bar used to drop Distill
unless it was running; Rick asked for it on both). The backfill and enrich-facts runners now publish their progress
(`AppState.backfillProgress`, `enrichFactsProgress`, from the gRPC stream's `total`/`embedded`
and `total`/`index`), so Embed and Distill get real bars instead of the indeterminate ones.

Under a divider, the figures: Sources, Documents (failed count as a note), Chunks, Embedded
(percent, models as a note), Facts (documents distilled as a note). `CorpusStats` gained
`factsCount` and `documentsDistilledCount` (one guarded statement over `facts`/`fact_runs`, built
from the enabled prompts and `facts.model`, so a database from before migration 013 still reports
the rest).

### Index Manager and Helper Services

The gRPC backend gets its own box, Index Manager (Rick, 2026-09-25: "Coordinator or Index
Manager or some better language"), since it is the process that runs the pipeline rather than
one helper among six: the row reads its state ("Running") with the address and its job under it.
Under that, Helper Services: one row per XPC helper, in the style of the Models page's summary
lines: an 8-point dot rather than a filled circle (Rick: seven green circles were "crowded and
busy"), a short name (Ingest, Embeddings, Inference, Model Downloads, MCP Server, Garage
Backend), one line of state ("Running · 12 ms", "Running · 12 of 12 self tests passed", or the
error in red), Test and Restart (bordered, not prominent), and a chevron. The header has the
time of the last check, Test All, Restart All and a refresh glyph. Expand/Collapse All is gone.

The details behind the chevron are everything the old expander had, minus the badges: lifecycle
and uptime, the Python line, managed services, the self tests with pass/fail, duration and
output (the "Llama Loader" test on Garage Backend is here, run by that row's Test), recent
errors, the crash report, the log file, and the functional test's summary and output with Copy.
Restart Managed Services and Force Restart Managed Services moved into a ⋯ menu in the details;
Restart Process is the row's Restart. "Beyond-Ping Functional Test", "In-Service Diagnostics"
and "Query Services" are gone as words; the tests themselves are unchanged.

### Service Output

The page's log, folded away at the bottom like Postgres Output and Ingest Output: the XPC
manager's log (`xpcServices.logs`) in a `LogTableView`, the line count beside the title, the
state in `garage.status.showServiceOutput`. The shared Last Command Output box is gone.

### Taken out

The six page cards, the quick-add boxes (the Sources and Models pages and the setup assistant
have them), the per-source breakdown (Sources has it), the bundle ids, PIDs and latency badges
on rows, the Ping reply line, Restart Process / Restart Services / Force Restart as row buttons.

### Kept / changed for the UI tests

- Navigation marker for the page is now "Helper Services"; `PagesUITests` also checks "Index Manager".
- `PagesUITests.testStatusShowsOverviewAndServiceControls` checks "Health", "Indexing",
  "Helper Services", the "Nothing to index yet" headline on an empty corpus, and the Test /
  Restart buttons (no Ping) as before.
- The ingest checks on Sources and Store tests read the Documents figure
  (`status.figure.documents`) instead of waiting for "All 2 docs ingested".
- New identifiers: `status.health.<kind>`, `status.updateEverything`, `status.stop`,
  `status.addSource`, `status.services.testAll`, `.restartAll`, `.refresh`,
  `status.service.<id>.test`, `.restart`, `.details`, `status.figure.<label>`,
  `status.indexing.title`, `.detail`, `status.serviceOutput.toggle`.

### Files

- `Views/StatusPagePresentation.swift`: `StatusHealth` (problems and their fixes),
  `IndexingPresentation` (headline, bar, remaining, figures), `ServiceRowPresentation`, as
  plain values with `init(appState:)` readers. Tested in `StatusPagePresentationTests.swift`.
- `Views/StatusView.swift`: the layout. `Views/StatusView+Services.swift`: the service rows and
  details. `PageStatus.swift`, `StatusView+QuickAdd.swift` and
  `StatusView+ServiceDiagnostics.swift` are gone.
- `Services/PostgresService.swift`: `CorpusStats.factsCount`, `documentsDistilledCount`.
- `AppState.swift`: `backfillProgress`, `enrichFactsProgress`.
