# Garage 1.5 beta backlog

Collected 2026-09-27 02:40 UTC from the release checklist (Beta and After release sections), the
1.5 reviews, the M3 and M4 threads, GitHub issue #118, project memory and the Dropbox research
thread. Branch: `v1.5-beta`, cut from `v1.5-alpha` at 50ef577. Everything here is work Rick moved
past the alpha cut or that turned up during alpha testing and was left alone to ship the alpha.

Legend: **Cloud** a cloud session can do it and CI can prove it. **Mac** needs a Mac build or a
person at the keys. **Rick** a decision or a signing step.

## A. Bugs found during alpha testing

| # | Item | Where from | Needs |
|---|---|---|---|
| A1 | **Sandboxed `garage ingest` reports success with 0 files** when the helper cannot read the source (`garage extract` says "not readable"). Scan and ingest should fail with a clear error when the root is unreadable, instead of "ok". **Draft PR #140.** | M3 store check, 26 Sep | Cloud (walker/ops), Mac to confirm the store CLI |
| A2 | **Workers back out of the app process.** The alpha fix runs Scan, ingest and the client-config writes in the app process so folder grants work. Beta: spawn the Python workers as `com.apple.security.inherit` children (as the vendored Postgres already is), which share the app's grants and keep crash isolation. Children carry only `app-sandbox` + `inherit`, so the app passes the DB URL. | M3 thread, Dropbox research §4 | Cloud draft, Mac to verify |
| A3 | **Database-reset handover UI test is flaky** (failed once each on the #102 and alpha passes, passed on re-run). Cause: after Skip the second half of the reset (cluster, schema, gRPC, MCP, sync) starts from scratch and the test gave the report 30 s; the page showed nothing meanwhile. **Draft PR #148**: a progress line while `finishDatabaseReset` runs, and the test waits for it, then 120 s for the report. M4 to run the UI test. | M4 final pass, 27 Sep | Cloud done, Mac to confirm |
| A4 | **Helper self tests skipped rows**: Ingest 2 skipped, Embeddings 2, Built-in Engine 1, MCP 1 on the Developer ID build. Cause: helpers self-test at bootstrap and only the backend helper was ever given the DB URL and gRPC address, so Ingest/Embed skipped Database + gRPC and MCP skipped gRPC; the engine's Model File skip (no model loaded) is expected. **Draft PR #146** (stacked on #143): the app pushes the configuration after the backend starts and re-runs the tests; skipped tests are named in the row. Mac to confirm the rows fill in. | M4, 26 Sep | Cloud, Mac to verify |
| A5 | Store build: Mail and Messages need Full Disk Access; confirm the greyed-out flow once the store build runs again; the 5 store UI tests need a clean run. | Checklist a5, d1 | Mac |

## B. Dropbox and cloud placeholders (from this thread)

| # | Item | Needs |
|---|---|---|
| B1 | Dropbox folder under File Provider: `~/Dropbox`, then `~/.dropbox/info.json`, then `~/Library/CloudStorage/Dropbox`. **PR #134, CI green, ready for review.** | Cloud, Mac CI |
| B2 | **Dataless-file guard**: `setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES)` OFF for the process, ON only on the materialize thread, so no other read can start a download; treat EDEADLK/EAGAIN as "still a placeholder". Reword `placeholder.py`'s Dropbox note for File Provider. **PR #139, open.** | Cloud (ctypes), Mac to confirm on a real placeholder |
| B3 | Evict after indexing (opt-in): `evictUbiquitousItem` on files Garage found dataless, so disk use stays at one file. Verify it works for Dropbox's provider on the M3 first. | Mac check, then Cloud |
| B4 | Try `startDownloadingUbiquitousItem` on a CloudStorage Dropbox file; if it works, prefetch a budget slice asynchronously instead of blocking threads. | Mac check |
| B5 | Dropbox API (content_hash without download, streaming reads): parked. Needs OAuth, Dropbox app review and a new egress origin. | Rick |

## C. Checklist "Beta" section (UI test gaps, ui-coverage-gaps.md)

| # | Item | Needs |
|---|---|---|
| C1 | Fact prompts: add, edit, enable, delete and run (b6) | Cloud draft, Mac run |
| C2 | Catalog downloads, embedding inspection and on-demand load, #87 (b7) | Cloud draft, Mac run |
| C3 | Sparkle Check for Updates (b8) | Mac |
| C4 | Bug reporter redaction and compose (b9) | Cloud draft, Mac run |
| C5 | The store build's security-scoped bookmark flow (b10) | Mac |
| C6 | Documents and Facts pages on an ingested fixture; the menu bar popover; the full setup-assistant walk | Cloud draft, Mac run |

## D. IPC and security (checklist p5, b11, ipc-hardening/brief.md, memory)

| # | Item | Needs |
|---|---|---|
| D1 | Unix domain sockets for gRPC, llama HTTP and Postgres in a short `s/` directory under the App Group container; peer check on connect; egress `CALLERS` learns UDS | **Done on `main`; reaches beta with #143.** |
| D2 | `setCodeSigningRequirement` on every XPC listener, team-pinned; hardened runtime and library validation on the app | **Done on `main`; reaches beta with #143.** |
| D3 | Route Python's `llama_xpc` calls over NSXPC and drop the 8790 listener (b11) | **Done on `main`; reaches beta with #143.** |
| D4 | Gate `SetSetting` and other config-changing RPCs behind the peer check: with no token, only a peer on the Unix socket may call them; TCP gets `PERMISSION_DENIED`. **Draft PR #144**, stacked on #143. | Cloud |
| D5 | Trim store entitlements the services do not use (review V3-S5): `user-selected` and `bookmarks.app-scope` on Embed, MCPServer, Llama and ModelDownload; `network.client` on Llama. **PR #141, CI green incl. macOS, ready for review.** | Cloud, store build to verify |
| D6 | Enhanced Security (hardened process) on a branch (p4) | Mac |
| D7 | **Support in the App Store build through an App Store purchase.** 08f2f73 hides the splash's Patreon ask and button in the store build (guideline 3.1.1, review V3-S3). Beta: offer a StoreKit consumable tip (or tip tiers) there instead, behind `offersDonationLink`'s store branch. Needs the in-app purchase products made in App Store Connect. Asked by Rick 2026-09-27 18:15 UTC. | Cloud draft (StoreKit 2), Rick (App Store Connect products), Mac to test in the StoreKit sandbox |

## E. Deferred to 1.5.1 or later

| # | Item | Needs |
|---|---|---|
| E1 | One model catalog (`models.json` as the only source) and remove `.actrc`, issue #118. **PR #142, CI green incl. macOS, ready for review.** | Cloud |
| E2 | One Library bar covering chunking, embedding and distillation (d2 leftover). **Already on the beta line**: the Status page's Library box (`IndexingPresentation`) weights ingest, embedding and distillation equally in one bar, lists what is left per stage ("24 documents to read · 880 chunks to index · 300 documents to glean") and has unit tests for it; the checklist note predates the Status redesign. Nothing to do. | Done |
| E3 | Unify grpcio and cryptography on `//ext/openssl` (p6) | Rick said later |
| E4 | Plan docs/plans/v1.5.md as 1.6 (p4) | Rick |
| E5 | Merge `main` (now 18 commits: site and appcast work, plus D1 sockets, D2 peer check and D3 NSXPC inference, which landed on `main` directly) into `v1.5-beta`. **PR #143, macOS build green, ready for review**; the `known-answers` red on it is E6 (#147). Codex found two socket bugs in main's code (a second server could unlink a live `s/grpc`; a failed llama bind unlinked another instance's `s/llama`): fixed in **PR #149 against `main`**, and #143 carries the same commit. | Cloud, Mac to confirm |
| E6 | The `known-answers` workflow's macOS jobs (CPU and Metal) have failed on all 14 runs since the workflow was added, on `main` too: Apple silicon cosines against the Linux reference come out near 0.989, below the 0.999 tolerance in `tools/llama/known_answers.py`. Cause: the reference was generated on Linux x86-64 and Apple silicon (CPU and Metal alike, 0.989 to 0.995) was held to the same-machine Metal-vs-CPU tolerance; Q2_K kernels differ per ISA. **Draft PR #147** makes the macOS CPU job the reference. Its first run measured Metal against that reference at 0.988 worst-case, so the same-machine 0.999 never held for Q2_K either; the PR now holds Metal and Linux x86-64 to one measured tolerance of 0.98, documented with the numbers. Its second run is green on all three (Apple CPU reference, Metal, Linux x86-64); **ready for review**. | Done, waiting on Rick |

## State on 2026-09-27 04:05 UTC

05:45 UTC: #147 green on every known-answers job and marked ready.

05:40 UTC: #146's first macOS run was lost (the build step never finished, no logs, `failure` after 109 min); re-ran the failed job once. #143, #147 (metal), #148, #149 still queued or building on the saturated macOS runners.

04:40 UTC: Rick merged #134 (B1), #139 (B2), #140 (A1), #141 (D5) and #142 (E1) into `v1.5-beta`; #143 merges cleanly against the new tip and is waiting on macOS CI.

04:35 UTC: Rick merged #144 (D4) into #143's branch, so D4 lands with #143. `v1.5-beta` itself gained six direct commits (Python 3.14, test-run manifest, its own XPC peer requirement); #143 merged them back in, resolving the duplicate `GarageXPCPeerRequirement` in favour of main's with beta's `apply(to:)` entry point added. macOS CI re-running.

04:20 UTC: Codex reviews answered. #144 now also guards `InitDb` (caller-chosen `schema_dir` runs SQL). #142 adds the two Llama 3.2 Instruct presets to models.json and matches a registration's `model_id`. #149 (against `main`) fixes the two socket findings; #143 carries it. #147 formatted the way the format task does (ruff defaults for `tools/`).

Ready for review: #134 (B1), #139 (B2), #140 (A1), #141 (D5), #142 (E1), #143 (E5, merge of main),
#144 (D4, stacked on #143). Drafts: #146 (A4, stacked on #143; macOS CI, then a Mac to confirm the
rows fill in), #147 (E6; its own known-answers run decides), #148 (A3; M4 to run the UI test).
Left for a cloud session: A2 (a design first, since it reshapes how the helpers get their grants).
Everything else needs a Mac (A5, B3, B4, C-series runs, D6) or Rick (B5, E3, E4).

## Suggested order for cloud sessions

1. B2 dataless-file guard (small, this thread, starting now).
2. A1 unreadable root reports an error (small, Python, testable on Linux).
3. D5 entitlement trim and E1 (#118), both mechanical.
4. A2 inherit children, then D1 to D4, which build on it.
5. C-series tests as drafts for a Mac to run.
- 05:50 UTC: Codex P1 on #147 ("macos-latest is Intel") is wrong: the reference job's runner image is macos-26-arm64 (CMAKE_SYSTEM_PROCESSOR arm64, GGML_SYSTEM_ARCH ARM). Replied with the log evidence and resolved; no push. macOS `test` still running or queued on #143, #146 (re-run), #148, #149.
- 06:15 UTC: #143 macOS `test` failed for real: test_config_changes_are_answered_over_the_unix_socket got PERMISSION_DENIED, because gRPC on macOS does not report a Unix-socket peer as `unix:...`. Fixed on the merge branch (9acde4c): the servicer records `callers_vouched_for` (token set, or bound to the Unix socket) and `_config_change` reads that instead of `context.peer()`; peer helpers removed, docs updated. Full pytest suite green on Linux; macOS run re-triggered by the push.
- 06:20 UTC: #143 fully green on 9acde4c (CI, macOS build 11 min on cache, Windows), mergeable clean, ready for review. Waiting on Rick to merge. #146 (re-run), #148, #149 macOS runs still in progress.
- 07:17 UTC: #148 (A3, reset progress line) macOS green, marked ready for review. #146 and #149 macOS runs still in progress.
- 07:25 UTC: Codex P2 on #148 was right (progress flag missed the startPostgres stage on the skip path); fixed in b590157, macOS run re-triggered. #148 stays ready.
- 07:36 UTC: #148 green again on b590157 (macOS 13 min on cache); stays ready. #146 and #149 macOS runs still in progress.
- 08:45 UTC: #146 and #149 macOS jobs are cold builds (Bazel cache restore took 1 s, so nothing restored) running since 05:39 and 04:07 UTC; live logs are not downloadable. 320-min timeout would end #149 about 09:27. Next check-in 09:35.
- 09:02 UTC: #149 (socket fixes, against main) macOS green after a 4h53m cold build; marked ready for review. #146 still building (cold, since 05:39).

### State 09:10 UTC
- #149: Codex P2 (stale-socket recovery race) fixed. 8b4155a: `_bind_unix_socket` holds an exclusive flock on `<socket>.lock` across probe, unlink and bind; two new tests. cc7cebc: same lock in Swift (`GarageSockets.withRecoveryLock`, used by `LlamaHTTPServer.start`), plus a unit test. Replied on the thread and resolved. 8b4155a ported to #143's branch (bd24d65). Both branches pushed; CI and macOS running.
- #146 still in its cold macOS build (re-run spent; timeout ~10:59 UTC).

### State 09:37 UTC
- #149 fully green on cc7cebc (CI, macOS 26 min, Windows); ready.
- #143 on bd24d65: CI and Windows green, macOS queued behind the concurrency group.
- #146 still in its cold macOS build (started 05:35, timeout ~10:55). Next check-in 10:30 UTC.

### State 09:56 UTC
- #146 macOS green (4 h 19 min cold build); marked ready for review. Stacked on #143.
- #143's macOS run on bd24d65 still queued; check-in at 10:30 UTC.

### State 10:05 UTC
- #146: two Codex P2s (first-run readiness loop bypassed startBackend; Restart relaunched a helper unconfigured) fixed in e2cccbf, replied and resolved. CI and macOS re-running (cache now warm from the 09:54 run). Still marked ready.

### State 10:27 UTC
- #146 green again on e2cccbf (CI, macOS 26 min); ready. Only #143's macOS run (queued since 09:07) is still pending.

### State 10:32 UTC
- #143's macOS run on bd24d65 restored no cache: cold build since 09:07, expect ~14:00 UTC (timeout 14:27). Everything else (#146, #147, #148, #149) green and ready. Next check-in 14:10 UTC.

### State 12:30 UTC
- Rick merged #149 and #148 into main (12:20 UTC).
- main now has three commits #143 lacks by SHA (rebase-merged #149); the Python content is already on #143. The Swift llama lock (89c7c8f on main) is cherry-picked onto a new stacked branch `claude/project-thread-f5ssau-llama-lock-beta` (PR against #143's branch, retarget to v1.5-beta after #143 merges) rather than pushed to #143, so #143's cold macOS build is not restarted.

### State 12:35 UTC
- Rick merged #147 (into main) and #146 (into #143's branch, its base) at 12:22 UTC. #143's head is now 484b6fe (29 commits); CI, Windows and a new macOS run started, the new macOS run waiting behind the old cold one (bd24d65, since 09:07). Expect #143 green around 14:20–14:40 if the new run restores the cache the old one saves.
- #152 (llama lock, stacked on #143) CI and macOS running.
- Remaining open: #143, #152. Check-in 14:40 UTC.

### State 13:45 UTC
- #143's old macOS run (bd24d65) finished green at 13:41 after 4 h 34 min and saved its cache; the run on the current head 484b6fe started at 13:41. #152's macOS build has been running since 12:22 (likely cold). Check-in 14:40 UTC.

### State 14:05 UTC
- Rick reported merge conflicts on #143. Merged v1.5-beta (18 new commits: the merged beta PRs) into #143's branch: no textual conflicts locally, full pytest 1535 passed, swiftcheck clean; pushed 9787f3b. Its macOS build restarts (should be warm now that the branch has a saved cache).

- 2026-09-27 14:20 UTC: #143 head 9787f3b (v1.5-beta merged in, 30 commits) fully green: CI, Windows, macOS build (14:01–14:15), known-answers; mergeable_state clean. Waiting on Rick to merge. #152 macOS build still running (36318780693); check-in at 14:40 UTC.

## B-menubar-ask: menu bar search + ask (Rick, 2026-09-27 14:40 UTC)
Rick: "can we get the garage menu icon to support both search an asking llama.cpp a question via inference with our MCP server attached?" Target v1.5-beta.
Plan (2026-09-27 14:55 UTC):
- Python: new `mcp_server/agent.py` + `rag_agent` MCP tool: a tool-calling loop over the local chat model (facts.provider/model) with the corpus tools (rag_search, rag_get_document, rag_list_sources, rag_list_authors, rag_stats) offered as JSON tool calls in the prompt (works with every backend: the Swift engine renders chat templates with role/content only, no native `tools`). Returns answer + steps + citations. Content rule: off-box model host gets no communication content (search restricted, get_document refused).
- Swift: `MenuBarQuickSearch` gains an "Ask Garage" row (⇧↩) that calls `rag_agent` through GarageMCPService (longer timeout) and shows the answer, citations and the tools used; Return still opens Search.
- 2026-09-27 15:25 UTC: B-menubar-ask implemented as draft PR #155 (branch claude/project-thread-f5ssau-menubar-ask → v1.5-beta, head 3eae255). rag_agent tool + agent.py, Ask Garage row/answer module, docs. Watching CI; macOS build is the Swift compile proof. Mark ready when green.
- 2026-09-27 14:56 UTC: #155 first CI red: my hand-edited py_binary listed agent.py beside server.py without `main =` (Bazel refused to load the package: gazelle, lint and macOS test failed). Fixed in 1333b45 (binary keeps server.py, depends on :mcp_server; test target deps trimmed to what it imports). #152 macOS run still building since 12:22 (cold). Check-in trig_012pJ4xrarBvNn1zPnidFnD9 at 16:27 UTC.
- 2026-09-27 15:57 UTC: **#143 merged into v1.5-beta** by Rick (E5/D1/D2/D3 land on the beta line). GitHub retargeted #152 to v1.5-beta automatically; body updated. #155 after the BUILD fix: all Linux CI, Windows and lint green; macOS test still running. Check-in trig_012pJ4xrarBvNn1zPnidFnD9 at 16:27 UTC.
- 2026-09-27 16:28 UTC check-in: #152 macOS run still building (since 12:22, cold); #155 macOS run still building (since 14:56). #155 merges cleanly with the post-#143 v1.5-beta (4b885a9). Next check-in trig_01QhfNwPcgptboFV64iwuCPJ at 17:59 UTC.
- 2026-09-27 16:40 UTC: Rick's menu bar Ask test hit "Ping failed: Couldn't communicate with a helper application" = #136's listener-requirement crash (team-signed builds), still on v1.5-beta; fix #153 (thread f6mubj) now conflicts after #143. Ported #153 into #155 (ce8d34c, after merging beta 4b885a9 in): listener `apply` calls removed, the delegate already pins each connection. #155's macOS build restarts on ce8d34c.
- 2026-09-27 16:45 UTC: verified v1.5-beta 4b885a9 still calls the listener setter (GarageXPCServiceBase.swift:148, :166), so the #136 crash is still on beta; #153 remains needed and the port in #155 is not redundant. Told the coordinator.
- 2026-09-27 16:55 UTC: Rick's Messages (apple-sms) ingest through the helper failed: PersistScanRequest.details was map<string,int64> but the sqlite scanner's details hold lists/nested tables → TypeError. Fixed on #155 (fc4c8b4): proto field 5 reserved, details_json (7) carries the object; server stores it as before; live gRPC test round-trips it. Bug is on v1.5-beta (and main) independent of the menu bar work; rides #155.

### 2026-09-27 17:20 UTC — Status/Logs UI polish (PR #160, base v1.5-beta)
Rick's asks from testing the alpha.2 build, all on branch `claude/project-thread-f5ssau-logs-footer`:
- Logs table: counts + Copy/Details/Clear in a status bar under the table (Finder idiom); stream picker dropped (text filter matches stdout/stderr).
- Status page: Update Everything / Stop / Test / Restart are icon buttons (circling arrows, stop, flask, restart); Restart tinted red when unreachable, yellow when tests fail.
- Models page: Unload buttons use the eject symbol.
- Index Manager row: "On a private socket" → "Without remote access".
- Automatic Updates box moved from Sources to Status, under Library.
State: draft, waiting on CI; mark ready when green.
- 2026-09-27 17:42 UTC: #152 (llama socket recovery lock, Swift half) macOS build green after 5h18m; marked ready for review. #160 rebased onto the beta tip (which now carries #153 and #157), CI running.
- 2026-09-27 17:48 UTC: #152 merged into v1.5-beta by Rick. Open on the beta line: #155 (menu bar Ask, macOS build pending), #160 (Status/Logs/Models polish, CI running).
- 2026-09-27 17:58 UTC: Rick asked for #160 stacked on #155 (its scan-details fix). #155 rebased onto the beta tip (ae00ab0; its own #153 port dropped, beta has #153). #160 rebased onto #155 and its base set to #155's branch; retarget to v1.5-beta once #155 merges.
- 2026-09-27 18:00 UTC check-in: #155 (a9242a6) and #160 (6cbc7f5) green on every Linux/Windows check; macOS builds not started yet (queued). Next check-in 19:30 UTC.
- 2026-09-27 18:20 UTC: Rick: launch "Also run when Garage starts" fired before the helpers were configured. Fixed on #160 (0b83eb9): the launch run awaits startBackend's configureHelpers task, then re-checks postgres and gRPC. #155 also got nonisolated tool-call timeouts (8cf6d10); #160 re-stacked.
- 2026-09-27 19:31 UTC check-in: #155 (8cf6d10) and #160 (0b83eb9) green on every Linux/Windows check; #155's macOS run queued at 19:29, #160's not registered yet. Next check-in 21:31 UTC.

- 2026-09-27 21:40 UTC: #155 had a conflict with v1.5-beta (FAQ: beta's `rag_ask` wording vs the `rag_agent` entry). Merged beta into #155 (9188bc1, kept both; `rag_agent` picks up beta's `inference.model` fallback since all three tools build `LocalChatModel()` the same way). #160 rebased onto it (eb76188, 7 commits). Both now have macOS runs queued (401 and 402); Linux checks pending. Check-in scheduled for ~23:40 UTC.
- 2026-09-27 22:12 UTC: Rick merged #155 (menu bar Ask) into v1.5-beta. #160 retargeted to v1.5-beta and marked ready: required checks green, macOS `test` (run 402) in progress since 21:56.
- 2026-09-27 22:39 UTC: Rick merged #160 into v1.5-beta (merge commit). Both PRs from this thread (#155 menu bar Ask, #160 Status/Logs/Models polish + launch-run gate) are in; the macOS build of eb76188 was still running at merge time, so the Swift side is proven only by the tree-sitter check until the next beta macOS run.
