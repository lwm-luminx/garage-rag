# Garage 1.5 release reviews (25 September 2026)

These are read-only reviews of the release candidate: #102's head, 0a35384 (v1.0..0a35384). Each file has the full findings with file:line evidence. "Inferred" findings still need confirming on a Mac.

| Review | Verdict | File |
|---|---|---|
| v1 Security and privacy | No blockers. Fix 2 log leaks | v1-security-privacy.md |
| v2 Signing and entitlements (repo) | 2 blockers | v2-signing-entitlements.md |
| v3 App Review readiness | Not ready: 3 likely blockers (inferred) | v3-app-review.md |
| v5 UX copy | 22 should-fix, all copy | v5-ux-copy.md |
| v6 Docs and site | 3 should-fix | v6-docs-site.md |
| v7 Licenses | No blockers. 2 LGPL notice gaps | v7-licenses.md |
| v8 Code review | No blockers. 4 should-fix | v8-code-review.md |
| v9 App Review risk pass, build 579 (29 Sep) | 4 blockers, all metadata/permission-flow; no sandbox or payment blockers | v9-app-review-build-579.md |

Not run yet, because they need a Mac or Rick: v4 upgrade safety on real v1.0 data, v9 performance, and the Mac halves of v2 and v5.

## Split by release (25 September, 21:50 UTC)

Rick cut the App Store work out of the alpha. Where each finding stands now:

**Developer ID release (#102, #104)**: every finding that applies is fixed in #104:
- V1: the log leaks, the redactor, a per-launch gRPC token, and model file name checks.
- V2: hardened runtime on the 4 XPC services. #103 is merged into #102.
- V5: the 22 copy fixes.
- V6: the MCP loopback wording and the installer name.
- V7: the notices and the copyright line.
- V8: the 4 code fixes.
Still open, both needing a Mac: the Mac halves of V2 and V5. V4 and V9 have not been run yet.

**App Store release (claude/app-store, #106, stacked on #104)**: all of V3, plus V6's App Store install path.
- #106 has: the store setup asks for the home folder instead of the whole disk; a skippable Full Disk Access step with a warning; Mail and Messages grey out until Full Disk Access is on; locations resolve against the real home folder; the store screenshots test; the App Store docs.
- Still open: V3-B1 (the ingest service can't use the app's bookmarks), V3-B3 (MCP registration writes inside the container), and the Patreon link in the store build.
- Rick checked Mail and Messages on the M3 store build: choosing the Mail folder does nothing without Full Disk Access, and Messages was greyed out.

## Blockers
- **v2: #102 predates #103.** It still ships the 3 app profiles with Sustained Execution. Merge main into #102.
- **v2: 4 XPC services are signed without hardened runtime.** GarageXPCService, GarageEmbedXPCService, GarageMCPServerService and GarageIngestXPCService have no HARDENED_RUNTIME_CODESIGNOPTS, so the store config misses it.
- **v3-B1 (inferred): in the store build, the background services can't use a folder the user picked.** The app sends the ingest XPC service an app-scoped bookmark, and only the app that made a bookmark can resolve it. GarageXPCService (scan, add source) gets no bookmark at all.
- **v3-B2 (inferred): the template sources don't reach the user's folders in the store build.** Their roots are `~/...`, and inside the sandbox `~` means the app's own container.
- **v3-B3 (inferred): MCP registration from the store build doesn't reach the real Claude configs.** It reads and writes copies inside the container.

## Should fix (the ones that matter most)
- v1: `GarageIngestXPCService/main.swift:294` and `:396` log the database URL, which includes the Postgres password, and the LM Studio token, with `privacy: .public`. Both were already in v1.0.
- v1: the bug-report redactor misses Bearer tokens, PGPASSWORD and JSON "password" values.
- v1: the gRPC service on 50051 has no authentication. SetSetting and McpInstall write to any path the caller names.
- v1: a `download_file` from the catalog can contain `../` and write outside models/.
- v3: Mail and Messages are offered in the store build but can't work until B1 is fixed and the folder picked in an open panel is registered.
- v3: the store build asks for the whole disk ("Select Root Hard Drive…").
- v3: the Patreon link is visible in the store build.
- v3: git attribution needs the Command Line Tools.
- v5: wrong help texts, including "Full Disk Access OR folder" and "macOS will ask for Full Disk Access". The built-in engine and the Python backend each go by 5 names.
- v6: the privacy policy, guide and FAQ say MCP is loopback-only, but `--allow-remote` exists.
- v6: the site downloads GarageInstaller_arm64.pkg, which the release steps never build or upload.
- v7: the GPL-3.0 text is missing for psycopg (LGPL-3.0).
- v7: libiconv (LGPL-2.1) is statically linked in lxml with no notice.
- v7: the About panel's copyright reads just "MIT".
- v8: re-indexing drops fact chunks, and the stale-only "Glean Facts" never restores them.
- v8: pressing Skip setup during a reset relaunch fails the reset.
- v8: the client's 4 MiB gRPC receive limit breaks opening long Messages threads.
- v8: a stale postmaster.pid is trusted without checking the process, so after a reboot the app can SIGKILL an unrelated process.
