# Garage 1.5 code review (v8): #102 and v1.0..0a35384

**Verdict: ship after four Should-fix items. No Blockers. #102 (UI tests, fixtures, docs, accessibility identifiers) is clean. The four fixes are in 1.5 code outside it: fact vectors are lost silently, the Reset Database relaunch can fail, large threads cannot be opened, and a stale postmaster.pid is trusted.**

Scope: `git diff origin/main 0a35384` (#102), then `git diff v1.0 0a35384`, reviewed at
`review-tree` (0a35384). I read every finding's code path end to end. Python suite on the review tree
(`PYTHONPATH=src`, repo venv): 1201 passed, 52 skipped. `test_postgres.py` skipped: this container has no
pgvector, so migration re-apply was checked by reading the SQL only. I could not build or run the Swift app here.

---

## Should fix

### 1. "Re-index Everything" (or a chunk-size change) permanently unembeds every fact, and Update Everything never repairs it
- `garage_python/src/garage_rag/ingest/gateway.py:618-630`: `replace_document` treats every chunk with
  `fact_id IS NOT NULL` as stale and deletes it. The `facts` rows stay, because the FK runs chunks→facts.
- `garage_python/src/garage_rag/enrich/facts.py:302-315`: `is_stale` compares only prompt hash, `content_sha256` and model.
- `macapp/Sources/GarageApp/AppState.swift:1454`: Update Everything runs `EnrichFacts(stale_only: true)`.
- **Failure scenario:**
  1. The user gleans facts.
  2. They choose Sources → ⋯ → "Re-index Everything" (`SourcesView.swift:621`, `force: true`), or change `chunking.size`.
  3. `ingest_one` reaches step 5 with the same `content_sha256` but `force`, or a new chunker signature. `replace_document` drops every fact chunk and its vectors in every `emb_*` table.
  4. Update Everything's stale-only pass sees an unchanged `fact_runs` row and skips every document.
- **Result:**
  - Hybrid search reads only `chunks` (`search/hybrid.py` never queries `facts`), so facts vanish from search and `rag_*` retrieval.
  - The Facts page and the Database page's "current fact runs" figure still report them as current.
  - Nothing reports an error.
- **New in 1.5:** `fact_runs` and stale-only are new, and v1.0 had no stale-only path.
- **Fix:** In `replace_document`, keep fact chunks when the new `content_sha256` equals the stored one, and renumber
  their `ord`s after the new text chunks. Otherwise, when fact chunks are deleted, also delete that document's
  `fact_runs`, so stale-only redoes it. Add a gateway test for force re-ingest.

### 2. "Skip setup" during the post-reset startup makes the reset fail, and garage.json's sources are not re-registered
- `macapp/Sources/GarageApp/Services/FirstRunCoordinator.swift:478-484`: when `finish()` runs with a reset pending, it
  calls `appState.startPostgres()` and then `finishDatabaseReset()`.
- `macapp/Sources/GarageApp/Services/PostgresService.swift:429`: `start()` returns silently unless the status is
  `.stopped` or failed.
- `macapp/Sources/GarageApp/AppState.swift:609`: `finishDatabaseReset` throws unless the status is `.running`.
- **Failure scenario:**
  1. The user clicks Reset Database.
  2. The relaunched instance opens on the assistant. Its readiness loop is inside initdb, start or migrations (several seconds, status `.starting` or `.needsMigration`), and Skip is enabled because `isWorking` is still false.
  3. The user clicks "Skip setup". `finish()` cancels the loop, and the second `startPostgres()` is a no-op.
  4. `finishDatabaseReset()` throws "Postgres did not start with the new database".
  5. The Database page shows the new red `database.resetOutcome` error.
  6. The first start still finishes in the background. The database comes up, but `syncSources` never runs, so the Sources page is empty although garage.json lists them.
  7. With status `.needsMigration`, `AppState.startPostgres` also calls `applyMigrations()` again while the loop's copy runs (`AppState.applyMigrations`, line 640, checks `isApplyingMigrations` nowhere). The result is two concurrent `psql -f` runs of the same DDL.
- **Fix:**
  - In `finish()`'s reset branch, wait for `postgres.status` to settle (poll as the readiness loop does), or don't cancel the in-flight start.
  - Disable Skip until Postgres has started.
  - Guard `applyMigrations()` with `isApplyingMigrations`.

### 3. The Documents page cannot open a long Messages thread (grpc-swift 4 MiB receive limit)
- `macapp/Sources/GarageApp/Services/GarageGRPCService.swift:254`: `ClientConnection.insecure(group:)` keeps
  grpc-swift 1.16's default `maximumReceiveMessageLength` of 4 MiB.
- `GetDocument` (`service/server.py:444`) returns every chunk and fact.
- Conversation documents are not capped by `max_chunks_per_document`: `ingest/conversations.py:89-127` makes one chunk per message.
- **Failure scenario:** a thread of about 30k or more messages (years with one contact) is roughly 130 bytes per chunk
  with `heading_path`, which exceeds 4 MiB. Selecting it in Documents fails with RESOURCE_EXHAUSTED, surfaced as
  "search failed". The server raised its own limit to 256 MiB for exactly this case ("a years-long Messages thread
  outgrows gRPC's 4 MiB default", `server.py:1410`), but the app's client was not changed to match.
- **Fix:**
  - Set `.withMaximumReceiveMessageLength(256 << 20)` on the connection builder.
  - Longer term, page chunks in `GetDocument`.

### 4. A stale `postmaster.pid` is trusted without checking that the process is Postgres
- `macapp/Sources/GarageApp/Services/PostgresService.swift:563-603` (`stopAnyRunningInstanceSync`, run by every `start()`)
  runs `pg_ctl stop -m fast`, which signals the pid in the file. If the process is still alive after 1 s,
  the code sends SIGINT and then SIGKILL.
- `GarageDataMigration.swift:139-148` (`runningPostmaster`) counts any live pid, including one that returns EPERM, as "postgres still running".
- **Scenario A:** after a power loss or panic, the file survives the reboot. Garage starts as a login item, and the old pid
  now belongs to another app of the same user. pg_ctl sends SIGINT and the fallback sends SIGKILL to that app, which loses its unsaved work.
- **Scenario B (1.0→1.5 upgrade):**
  1. The legacy `pgdata` has a stale pid file whose pid is now a system daemon (EPERM).
  2. `runAtLaunch` skips moving `pgdata`.
  3. `ensureInitialized` (`PostgresService.swift:373`) then throws "Quit every copy of Garage, then open it again" on every launch. Nothing ever clears the legacy pid file, because only `Paths.pgDataDir` is cleaned.
  4. The corpus stays unreachable until the user deletes the file by hand.
- **Present in v1.0 too:** v1.0 had the same pattern with SIGTERM. The migration check is new in 1.5.
- **Fix:** Before signalling or blocking, confirm that the pid is a `postgres` whose `proc_pidpath` is under the bundle's
  `Paths.postgresTool` directory. Treat anything else as stale and remove the file. Don't use `pg_ctl stop` blindly
  when the file's pid fails that check.

---

## Notes

- **Upgraded clusters never create Apache AGE.**
  - `PostgresService.applyMigrations` (`PostgresService.swift:864`) skips every file already recorded in `schema_migrations`.
  - v1.0 installs have `001_extensions` recorded, so 1.5's new `CREATE EXTENSION age` in 001 never runs on them. Only a fresh or reset cluster gets it.
  - This is harmless today, since nothing depends on AGE. It does contradict CLAUDE.md's "meant to be re-applied", and any future edit to an existing file will be skipped the same way.
  - Put new DDL in a new numbered file, or re-apply all files as the docs describe.
- **Migration errors are swallowed at start.** `PostgresService.swift:510,878` use `(try? fetchPendingMigrations()) ?? []`. A failed
  `schema_migrations` query marks the server `.running` with nothing pending, and the error is not logged.
  `applyMigrations` also ignores the `INSERT INTO schema_migrations` result (line 874).
- **The quit timeout turns into an immediate SIGKILL.**
  - `AppDelegate.swift:86-90` cancels the shutdown task after 15 s.
  - Once cancelled, `postgres.stop()`'s poll (`PostgresService.swift:538`, `try? await Task.sleep`) returns immediately and calls `forceKill()`.
  - If `mcp.stop()` or `grpc.stop()` take most of the 15 s, Postgres gets SIGINT and then SIGKILL at once, with no shutdown checkpoint. That is exactly what the SIGINT change meant to avoid.
  - Fix: use a non-throwing sleep that ignores cancellation in the loop, or give Postgres its own budget.
- **The fallback after a failed reset relaunch doesn't restart everything.** In `AppState.swift:562-570`, when
  `openApplication` fails, the old instance calls `firstRun.begin(afterDatabaseReset:)`. It does not call `xpcServices.startStreamingAllServices()` or
  `configureScheduledMaintenance()`, which the delete-failure branch at lines 534-540 does. As a result, Logs stops streaming helper output until the next launch.
- **Keychain calls on the main actor.**
  - `IngestService.swift:337` (a `@MainActor` class) and `GarageGRPCService.swift:89` / `GarageMCPService.swift:730` call
    `LMStudioTokenStore.load()` synchronously. That is safe after `loadOffMainActor()` has cached the token.
  - A failed first read is not cached, though. If the user denied the prompt, every ingest start re-reads the Keychain on the main thread and can block the window behind a prompt.
  - `AppState.saveLMStudioToken` (line 720) also writes the Keychain on the main actor.
  - Cache the failure, or route both through `Task.detached`.
- **Test hooks a release build can reach.**
  - `--data-directory` is accepted in release. It is well guarded: overlap with real folders is refused, the password and LM Studio token are kept out of the Keychain, and first-run completion is not persisted (#102).
  - The isolated instance still uses the fixed port 14824.
  - Its quit path kills XPC services by executable name (`XPCServiceManager.swift:733`), which includes the real app's.
  - So a UI test run, or a user trying the flag, while the real app is open talks to the real server (and fails authentication) and kills the real app's helpers. Refuse to start when 14824 is already bound, or skip the name-based kill on an override.
  - `#if DEBUG` test setters are compiled out. `isRunningInTestEnvironment` keys on `TEST_*`/`BAZEL_TEST` environment variables, which a user never sets.
- **gRPC streams during cancel.** `_stream_events` (`service/server.py:209-251`) stops work only at the next progress
  event. One slow `enrich_facts` document or a hung model call keeps a pool worker (`max_workers=10`) busy after the client cancels. This is not a hang for the caller, but the thread stays in use.
- **Leftovers:**
  - `inference/client.py:610` has a TODO in a docstring. It is benign, since the method doesn't poll.
  - `ext/nomic_embed/BUILD.bazel:15` (#102) cites `garage_python/tests/test_llama_known_answers.py`, which does not exist.
  - `print` in `service/server.py:1439-1453` is the CLI `serve_grpc` path only. The MCP stdio server logs to stderr.
- **Ingest idempotency otherwise holds.** Checked:
  - the stat skip → `source_sha256` skip → `content_sha256` + chunker skip order (`pipeline.py:167-340`);
  - that remembered outcomes are invalidated by extractor revision;
  - chunk reuse by (ord, hash, text, chunker);
  - that a stale row is deleted and flushed before inserts.

  No double-insert or lost-update found. Migrations 006-013 use `IF NOT EXISTS` or `duplicate_object`/`duplicate_table` guards and re-apply cleanly on reading. 008's data move is guarded by `?|` and is idempotent.
- **#102 specifically:**
  - The GroupBox relayouts, accessibility identifiers, `ModelsPresentation` extraction and `databaseResetOutcome` are behaviour-preserving. The extracted logic matches the removed inline code line for line.
  - `FirstRunCoordinator.persistsCompletion` is correct.
  - No debug code is shipped.
