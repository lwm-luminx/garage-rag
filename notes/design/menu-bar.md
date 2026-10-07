# Garage menu bar item: design (as built in PR #81)

## What the menu bar item is for

People click a menu bar item to answer one question in under a second and, occasionally, to do
one thing without opening the app. For Garage the questions are, in order of how often they come
up:

1. Is it healthy? (database up, MCP up)
2. Is it doing something right now, and how far along is it?
3. Can Claude reach my corpus? (MCP serving, clients registered)
4. Is there something in my corpus about X? (quick search)

And the things: start an ingest, stop one, open the window, quit. Everything else the app can do
is a page in the window, one click away.

## Critique of the first draft (PR #81)

It is a real improvement over `main` (which was a debug panel: "Postgres: Running on port 14824",
Start/Stop, a blue box), but it still reads as a small window, not a menu bar extra.

- **The header wastes the best 50 points.** A 32 pt app icon and the word "Garage" tell the user
  what they just clicked. Native extras (Wi-Fi, Bluetooth, Battery, Control Center) never repeat
  their own name; the first row is the state.
- **Two `.borderedProminent`/`.large` CTAs look like a dialog.** No menu bar extra on macOS has a
  blue primary button. "Open Garage" is a footer command, and "Ingest Now" belongs next to the
  thing it acts on.
- **MCP is missing entirely.** The app exists to serve the corpus to Claude, and the popover never
  says whether that works or how many clients are registered. The database gets a row and a
  toggle; the reason the database runs gets nothing.
- **The app-menu commands are in the wrong place.** Setup Assistant, About & Support, Report a
  Bug and Check for Updates are all already in the app menu. Four rows of rarely-used commands
  push the useful part up and make the popover scroll-length. A menu bar extra shows state and
  one or two actions; the window shows commands.
- **"Stop Database" is a footgun next to Quit.** One accidental click takes down the database, MCP
  and gRPC with no confirmation, from a surface where nothing else is destructive. The Database
  page already has Stop with context. What the popover needs is *Start* when it is stopped and
  *Apply* when it needs a migration.
- **Headline and card say the same thing.** "Ingesting notes…" under the title and "Ingesting
  notes" as the card title, with the percentage in the menu bar and in the card again.
- **The icon is the Database sidebar glyph.** `cylinder.split.1x2` says "database", not "Garage".
  Filled vs. outlined for busy is hard to see at 16 pt; nothing moves. Showing "42%" beside the
  icon makes every item to its left jump when a run starts and ends, and maintenance runs hourly.
- **Errors that matter are not surfaced.** A failed ingest (`ingestService.lastError`), a failed
  MCP start, and a failed backfill all leave the popover green and "Ready".
- **Corpus stats as a card.** Documents / Sources / Embedded % is a Status-page widget. "Embedded
  97%" is not something to glance at; the only number that matters at a glance is "1,234 documents
  in 3 sources".
- Smaller: `AnyView` for the card switch; Cancel as a caption-sized `.link` under a progress bar;
  `.help` on the Database row is the only place the port appears.

## The design as built (PR #81, head 1048c28)

Fable's second design, revised with Rick's feedback on 2026-09-25:
- One "All systems go" row replaces the per-service rows while everything is fine.
- When something is wrong, the popover shows a short summary that opens the Status page. It has no
  Start, Retry or Apply buttons.
- Open Garage and Quit are icon buttons in a header at the top.
- The popover is 540 pt wide (1.5 times the earlier 360 pt), and the search field has focus
  whenever the popover opens.

The content is a stack of Control Center-style modules. The header comes first, then a search
field, one services row, and, while the database runs, an Activity module.

### Idle, everything running

```
┌──────────────────────────────────────────┐
│ Garage                          (▭)  (⏻) │  Open Garage ⌘O, Quit ⌘Q (tooltips)
│                                          │
│ ⌕ Search your corpus                     │  results appear below while typing
│                                          │
│ ╭──────────────────────────────────────╮ │
│ │ (✓) All systems go                 › │ │  one green circle; opens Status
│ │     Database and MCP running · 2 clients │
│ ╰──────────────────────────────────────╯ │
│ ╭──────────────────────────────────────╮ │
│ │ 1,234 documents in 3 sources [Ingest Now]│  no second green dot
│ ╰──────────────────────────────────────╯ │
└──────────────────────────────────────────┘
```

### Ingesting

```
│ ╭──────────────────────────────────────╮ │
│ │ ● Ingesting notes  42%        [Stop] │ │  blue dot; Stop is red-tinted
│ │ ▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░ │ │
│ │ 1,204 of 2,860 documents             │ │
│ │ ~/Notes/2024/retro.md                │ │  middle-truncated
│ │ Scan › Ingest › Embed                │ │  current stage in the accent colour
│ ╰──────────────────────────────────────╯ │
```

Scanning, embedding and distilling show an indeterminate bar. Stop cancels whichever stage is
running.

### Something wrong

```
│ ╭──────────────────────────────────────╮ │
│ │ (!) Database failed to start       › │ │  red circle; opens Status
│ │     port 14824 already in use        │ │
│ ╰──────────────────────────────────────╯ │
```

There is one row, naming the worst problem in a few words; clicking it opens the Status page, which
has the fixes. The Activity module is hidden while the database is down.

| State | Row title | Detail | Tint |
|---|---|---|---|
| Database failed | Database failed to start | first line of the error | red |
| Needs migration | Database needs a migration | Open Status to apply it. | orange |
| Database stopped | Database stopped | Open Status to start it. | grey |
| Starting / stopping | Starting up… / Shutting down… | one line | yellow |
| MCP failed | MCP server failed | first line of the error | red |
| MCP not running | MCP server not running | Claude can't reach your corpus. | orange |
| Everything fine | All systems go | Database and MCP running · N clients | green |

A database failure hides the MCP failure it causes. A failed ingest adds a one-line warning under
Activity, such as "Last ingest failed: notes: permission denied" or "2 sources failed: notes, mail".
The line opens Status and is kept for the whole Ingest Now run.

### Icon states (16 pt template)

| State | Symbol | Motion |
|---|---|---|
| Database stopped / stopping | `door.garage.closed` | none |
| Database starting | `door.garage.closed` | pulse |
| Running, idle | `door.garage.open` | none |
| Running, pipeline busy | `door.garage.open` | pulse |
| Database failed, needs migration, MCP failed | `exclamationmark.triangle` | none |

There is never text beside the icon, so its width in the menu bar stays the same.

### Header, search and navigation

- **Header:** "Garage", plus two round icon buttons: `macwindow` (Open Garage, ⌘O) and `power`
  (Quit Garage, ⌘Q). They have no border until the pointer is over them. Open Garage opens a new
  window when a background launch never showed one.
- **Quick search:** the field takes focus each time the popover opens, so typing right after
  clicking the icon searches. The search runs 250 ms after typing stops and shows five hits. A hit that is a
  file opens in its own app (plain absolute paths and `file://` URLs); any other hit, Return, or
  "See all results" opens the Search page and runs the query there.
- **Navigation:** rows open their page through the `garageShowSection` notification.

### Taken out of the popover

- Setup Assistant, About & Support, Report a Bug and Check for Updates, which remain in the app menu.
- Stop Database, which remains on the Database page.
- The Start, Retry and Apply buttons, which are on the Status page.
- The stats card and the percentage beside the menu bar icon.

### Files

- `macapp/Sources/GarageApp/Views/MenuBarStatus.swift`: all the logic (summary row, icon, headline,
  copy, formatting). Tested in `MenuBarStatusTests.swift`.
- `macapp/Sources/GarageApp/Views/MenuBarView.swift`: the layout.
- `macapp/Sources/GarageApp/Views/Components/MenuBarModule.swift`: the module card, rows, header
  button, button styles and stage trail.
- `macapp/Sources/GarageApp/Views/Components/MenuBarQuickSearch.swift`: search.
- `macapp/Sources/GarageApp/Views/MenuBarNavigation.swift`: opening the window on a page.
- `GarageApp.swift` (`MenuBarLabel`), plus `ContentView.swift` and `SearchView.swift`, which
  receive the page hand-off.
- `AppState.swift`: `lastIngestAllFailure`.

## Ask Garage (v1.5-beta, thread "menu bar search and ask")

Rick, 2026-09-27: the menu bar item should support both search and asking llama.cpp a question
with Garage's MCP server attached as tools.

- The field keeps its live search. Its placeholder becomes "Search or ask your corpus" while the
  MCP server runs (`MenuBarStatus.canAsk`: database and MCP both running).
- While there is text, the results module starts with an **Ask Garage** row (sparkles, indigo).
  Clicking it, or Shift-Return in the field, sends the text as a question to the `rag_agent` MCP
  tool through `GarageMCPService.executeToolCall` with a five-minute allowance (the model may be
  loading). Return alone still opens the Search page, as before.
- `rag_agent` (`garage_python/src/garage_rag/mcp_server/agent.py`) runs the local model
  (`facts.provider` / `facts.model`) in a loop with the read-only corpus tools (`rag_search`,
  `rag_get_document`, `rag_list_sources`, `rag_list_authors`, `rag_stats`). Tool calls are JSON
  objects in the conversation, not the OpenAI `tools` field, because the app's llama engine renders
  the chat template from role/content only; the same loop then works on Ollama and LM Studio.
- The answer shows in its own module above the results: the question in bold with a spinner and
  Stop while it runs, then the answer (up to 14 lines, selectable, with a copy button), "Based on"
  rows for up to four documents the model saw (a file opens in its app; anything else opens the
  Search page), and a footnote such as "Searched twice and read 1 document · gemma2-2b".
- Communications never reach an off-box model host: `rag_agent` restricts searches to documents and
  code and refuses to read a communication when `facts.provider` points off the machine.
- Files: `Views/Components/MenuBarAnswer.swift` (the decoded result and its wording, tested in
  `MenuBarAnswerTests.swift`), `MenuBarQuickSearch.swift` (the row, the ask and the answer module),
  `MenuBarStatus.canAsk`, `GarageMCPService.executeToolCall(timeout:)`.
