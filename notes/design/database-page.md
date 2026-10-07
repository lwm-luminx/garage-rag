# Garage Database page: design (branch claude/project-thread-tb1wwu)

## What the page is for

People open Database to answer, in order: is Postgres up, and how do I reach it from another
tool? Is the schema current? What does the database hold? Do I have a backup? And, rarely, to
restore one or start over.

## Critique of the page on `main`

- **A settings sheet, not a status page.** The Postgres box opens with a 10-point dot and
  "Running on port 14824", then five label/value rows (data directory, port, database, "Bundled
  binaries: yes (vendored)", the URL with two buttons) that almost nobody needs at a glance.
- **Schema & Migrations mixes two jobs.** Check Migrations, Apply Migrations (always prominent,
  even when there is nothing to apply), then under a divider Initialize schema and Show stats.
  "Show stats" prints a text dump into Last Command Output instead of showing the numbers.
- **Restore replaces the whole database with no confirmation.** `restoreDatabase` runs
  `dropdb --force` the moment a file is picked.
- **Back Up and Restore give no progress and no result on the page**; the only feedback is the
  shared Last Command Output box, which also shows whatever another page did last.
- **Reset Database sits next to Back Up** as a peer, with the same weight.
- **No logs.** Postgres's own output (start-up failures, pg_dump errors) is only on the Logs page.

## The design as built

```
Database

╭ Postgres ─────────────────────────────────────────────────────────────────────╮
│ (✓) Running                                                  [Restart] [Stop] │
│     On this Mac, port 14824 · 1,234 documents · 2.3 GB                        │
│     postgresql://rick:••••••@localhost:14824/garage-rag  ⧉ ↗       Details ›  │
│       (open) Data folder  ~/…/pgdata   Reveal in Finder                        │
│              Database     garage-rag on port 14824                             │
│              Server       PostgreSQL 18.0, bundled with Garage                 │
│              Extensions   age 1.6.0, vector 0.8.1                              │
╰───────────────────────────────────────────────────────────────────────────────╯
╭ Schema ───────────────────────────────────────────────────────────────────────╮
│ (✓) Schema up to date                                      [Check Again] (⋯)  │
│     Every migration this version of Garage carries is applied.                 │
│   — or —                                                                       │
│ (!) 2 updates to apply                                   [Apply Updates] (⋯)  │
│     This version of Garage expects schema changes … Your data is kept.         │
│     013_fact_prompts.sql                                                       │
│     014_….sql                                                                  │
╰───────────────────────────────────────────────────────────────────────────────╯
╭ Contents ─────────────────────────────────────────────────────────────── (↻) ╮
│ Sources   Documents   Chunks    Embedded   On Disk                            │
│ 3         1,234       56,789    98%        2.3 GB                             │
│           12 failed             2 models                                      │
╰───────────────────────────────────────────────────────────────────────────────╯
╭ Backups ──────────────────────────────────────────────────────────────────────╮
│ (⛁) Last backup 2 days ago                                [Back Up…] [Restore…] │
│     garage-rag-20260923-101500.dump  Reveal                                    │
│     ✓ Saved garage-rag-20260923-101500.dump.        (this page's last result)   │
│ ─────────────────────────────────────────────────────────────────────────────  │
│ (🗑) Start Over                                            [Reset Database…]    │
│     Deletes the database and builds a new, empty one. Your files are not touched.│
╰───────────────────────────────────────────────────────────────────────────────╯
▸ Postgres Output  312 lines        (collapsed; remembered; opens itself when Postgres fails)
```

### Postgres

One row in the MCP page's style: a tinted circle, a title and one line.

| State | Title | Line |
|---|---|---|
| Running | Running | On this Mac, port 14824 · N documents · size |
| Missing migrations | Needs a schema update | N schema updates to apply below … |
| Starting / Stopping | Starting… / Stopping… | |
| Stopped | Stopped | Search, ingest and the MCP server need the database running. |
| Failed | Couldn't start | the error, in red |
| Resetting | Resetting… | Stopping Garage's services and deleting the database. |

Actions follow the state: Start (prominent) while stopped, Try Again after a failure, Restart and
Stop while running. The URL stays, password hidden, with icon buttons to copy it and open it in
the registered `postgresql://` app. Everything else is behind Details, which adds what was never
shown before: the server version and the installed extensions (one `psql` call,
`PostgresService.fetchServerDetails`, which also reads `pg_database_size`).

### Schema

One row. Apply Updates is prominent only when there is something to apply; otherwise the button
is a quiet Check Again. The pending files are listed under it. "Initialize schema" became
"Re-apply the Whole Schema" in the ⋯ menu, with Check for Updates. The result of an apply or
re-apply is shown under the row, not in the shared output box.

### Contents

Replaces "Show stats". The numbers from `corpusStats` (already fetched for the Status page) plus
the size on disk, refreshed on appear, when Postgres comes up, after a restore, and by (↻).

### Backups

The last backup made from this Mac (Back Up… here or Back Up First… in the reset sheet; kept in
user defaults) with Reveal, or "moved or deleted" if the file is gone. Back Up… and Restore…
show a spinner while running and one result line when done. **Restore now asks first**
("Replace the database with this backup?"), and afterwards rereads pending migrations, sources,
models and stats, since an older dump can predate a migration. Reset moved under a divider as
"Start Over", same sheet.

### Postgres Output

The Sources/MCP pattern: a folded GroupBox at the bottom with `LogTableView` over
`postgres.logs`, the line count beside the title, the open/closed state in
`garage.database.showPostgresOutput`. It opens itself when Postgres fails to start. The
"Last Command Output" box is gone from this page.

### Kept for the UI tests

`database.backup`, `database.restore`, `database.reset`, the reset sheet, and the text
"Schema up to date". New identifiers: `database.start`, `.stop`, `.restart`, `.copyURL`,
`.openURL`, `.details.toggle`, `.applyMigrations`, `.checkMigrations`, `.schema.more`,
`.contents.refresh`, `.restore.confirm`, `.postgresOutput.toggle`. The navigation test's marker
for the page is now "Backups".

### Files

- `Views/DatabasePresentation.swift`: headline, schema row, contents figures, backup record,
  as plain values. Tested in `DatabasePresentationTests.swift`.
- `Views/DatabaseView.swift`: the layout.
- `Services/PostgresService.swift`: `fetchServerDetails()` and `DatabaseServerDetails`.
- `AppState.swift`: `backupDatabase`/`restoreDatabase` are async and return success; restore
  refreshes what the pages show.
- `Views/DatabaseResetSheet.swift`: Back Up First… records the last backup too.
