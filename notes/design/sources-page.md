# Garage Sources page: design (branch claude/project-thread-2tznkh)

## What the page is for

People open Sources to answer, in order: is everything I pointed Garage at being read? Is it
indexing right now, and how far along? Which folders are in, and how current is each? And to do
three things: add a folder, index one (or all) now, and take one out.

## Critique of the page on `main`

It reads as a diagnostics panel, the way the menu bar popover did before PR #81.

- **Disk access takes the top of the page even when it is fine.** A permanent "App Sandbox &
  Disk Access" box with four buttons (Select Root Hard Drive, Open Privacy Settings, Revoke
  Access, re-check), a raw status string ("Granted: /System/Volumes/Data (security-scoped)") and
  a nested "Overall Disk Access: All Paths Accessible" panel. On a healthy Mac all of it is noise
  above the thing the page is about.
- **Every source card is six rows tall.** Slug and buttons; a badge row (CONFIG & DB, 25/30 DOCS,
  5 UNINGESTED, CODE, DISK OK); a Path line with the tilde-expanded path repeated in parentheses;
  "Kind: filesystem • Class: document • Trust: authored"; an ingest sub-panel with its own
  progress bar; and a "Disk Access Test" sub-panel with the resolved path. A source that is fine
  says so in four places (DISK OK, UP TO DATE, "1,204 documents indexed in database", "Disk Access
  Test: OK").
- **Progress is shown twice, in different vocabularies.** "Live Ingest Progress" above the list
  (with INGEST and XPC HELPER badges, five count badges) and again inside the card. The execution
  mode has one value; the badge tells the user nothing.
- **Actions are scattered.** Cancel All in the progress box and again in the list header; Remove
  in the card menu and again under the form; "Populate Form for Editing" and "Fill from existing"
  are two ways to do the same thing; Scan & Ingest is a blue prominent button on every card.
- **The vocabulary is the pipeline's, not the person's.** "UNINGESTED", "Reconcile (Apply
  Deletions)", "Sync Config → DB", "TCC Permission Prompt…", "expected elements".

## The design as built

The page is a stack of five sections; the first two appear only when there is something to say.

```
Sources

╭ Attention (only while something can't be read) ───────────────────────────────╮
│ (🔒) Messages needs permission     [Ask macOS…] [Open Privacy Settings…] [Grant Folder Access…] │
│      macOS protects Messages databases (~/Library/Messages)…                  │
╰───────────────────────────────────────────────────────────────────────────────╯

╭ Activity (only while the pipeline runs, and 4 s after it ends) ───────────────╮
│ (⬇) Ingesting notes  42%                                              [Stop] │
│ ▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│ 1,204 of 2,860 documents · 1,180 indexed · 24 skipped                         │
│ ~/Notes/2024/retro.md                                                         │
╰───────────────────────────────────────────────────────────────────────────────╯

╭ 1,234 documents in 3 sources ──── [Update Everything] [Scan & Ingest All] [⟳ Sync] ╮
│ (📄) notes   Document Authored                            [Scan & Ingest] (⋯) │
│      ~/Notes  filesystem                                                      │
│      ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░░░░░ │
│      24 items to go                                   1,180 of 1,204 documents │
│ ──────────────────────────────────────────────────────────────────────────── │
│ (💬) apple-sms   Communication Received PERMISSIONS NEEDED [Scan & Ingest] (⋯) │
│      ~/Library/Messages  sqlite                                                │
│      Needs permission to read this folder                          0 documents │
│ ──────────────────────────────────────────────────────────────────────────── │
│ ✓ Every source folder can be read. Reads / with the access you granted.  Re-check (⋯) │
╰───────────────────────────────────────────────────────────────────────────────╯

╭ Add a Source ─────────────────────────────────────────────────────────────────╮
│ ╭ (📄) Documents          ⊕ ╮ ╭ (🖥) Desktop         ⊕ ╮ ╭ (⬇) Downloads      ⊕ ╮ │
│ │ Your Documents folder     │ │ Files kept on the… │ │ Received files…    │ │
│ │ ~/Documents               │ │ ~/Desktop          │ │ ~/Downloads        │ │
│ ╰───────────────────────────╯ ╰────────────────────╯ ╰────────────────────╯ │
│ ╭ (☁) iCloud Drive  ADDED ✓ ╮ ╭ (📦) Dropbox NOT FOUND ╮ ╭ (</>) Developer CODE ⊕ ╮ │
│ ╭ (💬) Messages PRIVATE  ⊕ ╮ ╭ (✉) Apple Mail PRIVATE ⊕ ╮                        │
│                                                                               │
│ [📁 Add Folder…] [⚙ Custom Source…]                                            │
│ ─────────────────────────────────────────────────────────────── (when opened) │
│ Custom source                                    Start from a preset [Choose preset…] │
│   Folder [~/Notes                                              ] [Choose…]    │
│     Name [notes        ] from the folder                                      │
│ Contents [filesystem ▾] [document ▾] [authored ▾]  files in a folder, indexed as document you wrote. │
│ [Add Source] [Remove Source] [Clear]                                          │
╰───────────────────────────────────────────────────────────────────────────────╯

╭ Automatic Updates ────────────────────────────────────────────────────────────╮
│ [x] Keep every source up to date   Every [hour ▾]                             │
│ [ ] Also run when Garage starts                                               │
╰───────────────────────────────────────────────────────────────────────────────╯

▸ Ingest Output  1,532 lines            (collapsed; remembered per user)
```

### Rows

One row per source: a tinted circle (colour = corpus class, glyph = what it is: folder, Documents,
Downloads, Dropbox, iCloud, code, Messages, Mail, feed), the slug, the class and trust badges,
then only the badges that mark something unusual (DISABLED, CODE, NOT SYNCED, PERMISSIONS NEEDED,
UNREADABLE), then the actions. Below: the path as configured, a thin bar while there is
something to index, one status line in the person's words, the counts in monospace at the right.

| State | Status line | Bar |
|---|---|---|
| Never scanned or ingested | Not indexed yet | none |
| Scanned, nothing indexed | 1,204 items found, none indexed yet | empty |
| Behind | 24 items to go | fraction |
| Up to date | Up to date | none |
| Ingesting | Ingesting 42% · current file under it | fraction, or moving without a total |
| Scanning | Counting items… | moving |
| Queued | Waiting for its turn | fraction |
| Removing | Removing… | none |
| Protected folder | Needs permission to read this folder | fraction |
| Unreadable | Can't be read: Path does not exist | fraction |
| Last ingest failed | Last ingest failed, error under it in red | fraction |
| Disabled | Disabled: skipped by every scan and ingest | none |

What the pipeline is doing is the status line and the Cancel button, never a badge as well.

### Actions

- **Scan & Ingest** on the row (bordered, not prominent) becomes **Cancel** (red tint) while the
  source is queued, scanned, ingested or removed.
- The row's ⋯ menu: Ingest Including Code, Re-index Everything, Scan Only, Glean Facts, Check for
  Deleted Files, Forget Deleted Files, Reveal in Finder, Edit…, (Grant Folder Access…, Open
  Privacy Settings… when the folder can't be read), Remove Source.
- **Update Everything** (Rick, 2026-09-25: "some button that kicks off all processes") is the
  primary button in the list header: scan, ingest every source, embed with every model, then
  glean facts from the documents no enabled prompt has distilled yet (`stale_only`), as one run
  (`AppState.updateEverything`). While it runs the Activity module shows each step with the
  menu bar's "Scan › Ingest › Embed › Distill" trail under it, and Stop ends it at the current
  step. Automatic updates keep to scan, ingest and embed, as before.
- **Stop** lives in the Activity module, once, and stops the run and everything queued after it.
- **Scan & Ingest All** and **Sync** are in the list header. Sync's tooltip explains both
  directions; the two separate import/apply commands stay folded into it.
- Disk access has one line at the foot of the list with **Re-check** and a ⋯ menu (Open Privacy
  Settings…, Choose Another Disk…, Revoke Disk Access, the last two only for a security-scoped
  grant). Problems go to the Attention module at the top, each with the button that fixes it.

### Adding a source (Rick, 2026-09-25: "more like the first run, with a specific UI for custom")

The section is the setup assistant's data page for a running app. The eight common locations
(`FirstRunSourceTemplate.builtIn()`) are cards, two to four a row; one click adds the source
(no select-then-commit, since there is nothing else to wait for), the card then shows ADDED
with a green check and can't be clicked again. A location that doesn't exist on this Mac is
greyed out with NOT FOUND. Messages and Mail carry PRIVATE, Developer carries CODE, as in the
assistant. **Add Folder…** opens the folder chooser (several at once), keeps the grant the
sandbox needs, and adds each folder as a document source named after it. **Custom Source…**
unfolds the form for a source of another kind or with its own class and trust: Folder first,
then Name, then one Contents row of three pickers with a one-line gloss ("files in a folder,
indexed as document you wrote", "…communication you received, never sent off this Mac").

The name fills itself in from the folder and kind (`SourceSlugSuggestion.suggest`): a
preset's location gets the preset's slug (`~/Library/Messages` → `apple-sms`); otherwise the
last path component folded to `[a-z0-9-]` the way the assistant names a custom folder
("My Notes (2024)" → `my-notes-2024`); a database its file name (`chat.db` → `chat`); a feed
its host; "-2", "-3" when the name is taken. "from the folder" is shown beside it while the
field still holds the suggestion; a name the person typed is kept when the folder changes.
The button reads Add Source, or Update Source once the name matches a listed source; Remove
Source is enabled only then. A row's Edit… opens the form on that source. "Fill from
existing" is gone.

### Automatic updates (Rick, 2026-09-25: "perform updates at startup")

"Also run when Garage starts" (`AppState.maintenanceRunsAtLaunch`, default off) runs the
scan → ingest → embed pass once the database is up after launch, instead of waiting a whole
interval for the first run. It is once per launch (a database restart from the Database page
does not count), shares the debounce with the sources the assistant or garage.json register at
start, and the assistant still holds it until it closes. The UI tests launch with it off.

### Kept for the UI tests

The accessibility identifiers (`sources.form.*`, `sources.row.<slug>`, `.scanIngest`, `.cancel`,
`sources.scanIngestAll`, `sources.sync`, `sources.diskAccess.refresh`, `sources.cancelAll`), the
"Choose preset…" menu, the "PERMISSIONS NEEDED" badge, the "Grant Folder Access…" button and the
"No sources configured yet." empty state. Changed: the navigation marker for the page is now
"Add a Source"; the maintenance test waits for the Activity module's Stop button; the helpers
that fill the form first open it through `sources.form.show` (`revealCustomSourceForm`).

### Files

- `macapp/Sources/GarageApp/Views/SourcesPresentation.swift`: rows, attention list, activity
  module, summary line and suggested names, as plain values. Tested in `SourcesPresentationTests.swift`.
- `AppState.swift`: `maintenanceRunsAtLaunch`, `runMaintenanceAtLaunchIfEnabled()`.
- `macapp/Sources/GarageApp/Views/SourcesView.swift`: the layout.
- Reuses `MenuBarSymbolCircle` (the tinted circle), `StatusBadge`, `CorpusClassBadge`,
  `TrustTierBadge`, `DisclosureChevron`, `LogTableView`.
