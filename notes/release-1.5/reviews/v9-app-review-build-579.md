# Garage 1.5: App Review risk pass on build 579 (v9)

**Verdict: submittable after four fixes, two of them in the app.** The store build is sandboxed, hardened, Sparkle-free, has no temporary-exception entitlements, no analytics, no cloud AI client, and no code download. Those were the 1.5 blockers in the v3 pass and they are gone. What is left is the set of things App Review most often rejects a first submission for: a missing in-app privacy-policy link, an in-app purchase the reviewer cannot find, a Contacts prompt the reviewer cannot explain, and review notes that no longer describe the app.

Reviewed: `v1.5-beta` at `478533bd` (the tree build 579 came from), the listing draft (`app-store-listing/draft.md`), the review notes (`release/1.5-app-review-notes.md`), the 14 screenshots in `appstore-screenshots-1.5-beta/`, the IAP review screenshots in `appstore-iap-review-1.5/`, and Apple's App Review Guidelines as served on 2026-09-29. Read-only; nothing was built or run. "Inferred" means I read it in the code and did not see it on a Mac. The three code audits ran in parallel over entitlements and plists, payments and updater, and sandbox access and process lifecycle; every finding below was re-read at the cited line.

Severity: **Blocker** = a rejection I would expect; **Likely** = a common rejection reason that applies here; **Possible** = reviewers sometimes raise it; **Note** = passes, recorded so nobody re-checks it.

## Blockers

**B1 (5.1.1(i)). There is no privacy-policy link inside the app.**
- Apple: "All apps must include a link to their privacy policy in the App Store Connect metadata field **and within the app** in an easily accessible manner."
- `grep -ri "privacy policy\|privacy-policy" macapp/Sources` finds nothing. The Help menu has Troubleshooting Guide and Report a Bug only (`GarageApp.swift:31-39`); the About/splash footer has Acknowledgements only (`SplashView.swift:227-233`); the setup assistant has none.
- The only route is indirect: Help → Troubleshooting Guide opens garagerag.app, whose footer links the policy.
- Fix: a "Privacy Policy" item under Help and a link in the splash footer, both to `https://garagerag.app/support/privacy-policy.html`. One small PR.

**B2 (2.1(b), 3.1.1). The reviewer will not find the tip jar unless the notes say where it is.**
- Apple: in-app purchases must be "visible to the reviewer and functional. If any configured in-app purchase items cannot be found or reviewed in your app, explain the reason in your review notes."
- The tip jar lives only on the splash (`SplashView.swift:195-197`). On a fresh install the splash is **not** shown at launch, because the setup assistant takes the window (`ContentView.swift:244-254`, the `firstRun.isActive || shouldPresentAtLaunch` guard). The reviewer reaches it only through Garage → About Garage….
- If the five products are not attached to the 1.5 version, or are not "Ready to Submit", `Product.products(for:)` returns nothing, `phase` becomes `.unavailable` and the view renders `EmptyView()` (`TipJar.swift:55-61`, `TipJarView.swift:16-17`). The reviewer then sees the "Open source runs on people" card with no buttons and rejects for a missing IAP.
- Fix: attach all five consumables to the version; add to the notes: "The tip jar is under Garage → About Garage…. It is five consumable tips (Small to Ultra). Tips unlock nothing." Keep the IAP review screenshot (`iap-tip-jar.png` is fine: it shows the buttons in context).
- The wording passes 3.1.1: "leave a tip. It unlocks nothing; every feature is free" (`TipJarView.swift:31`), buttons read "Tip $4.99", storekit descriptions say "Unlocks nothing". No "donate", no charity wording, no restore button (correct for consumables). A `Transaction.updates` listener finishes interrupted purchases (`AppDelegate.swift:60-62`).

**B3 (5.1.1(ii)-(iv), 2.5.1). Contacts is requested on the first ingest of any source, with a purpose string about Messages and Mail.**
- `IngestService.swift:402` calls `ContactNamesService.namesForIngest()` before every ingest, whatever the source kind. With status `.notDetermined` that calls `CNContactStore().requestAccess` (`ContactNamesService.swift:25-33`). So the reviewer adds ~/Documents, clicks Update Everything, and macOS asks for their contacts, quoting "Garage uses your contacts to show names … in the messages and mail it indexes" (`Info.plist:31-32`) while no messages or mail are involved. Reviewers reject exactly this: a permission request the flow does not justify ("we were not able to determine why your app requests Contacts").
- It can also fire from the hourly maintenance run, which defaults on (`AppState.swift:217-226`), i.e. with no user action at all.
- The address book of every name, phone number and email is then passed to ingest (`IngestService.swift:403-413`) even for a folder of PDFs.
- Fix: request and read Contacts only when a `communication` source (Mail or Messages) is in the ingest set; and say in the notes that Contacts is optional and only asked for Mail/Messages. Declining already degrades gracefully (`:27-33`).

**B4 (2.3.1(a), 2.1). The review notes are out of date and describe things that no longer exist.**
- Apple: "All new features, functionality, and product changes must be described with specificity in the Notes for Review section … (generic descriptions will be rejected)."
- `release/1.5-app-review-notes.md` says Postgres "listens only on 127.0.0.1" and names "the local MCP server (127.0.0.1:8787)" as reasons for `network.server`. On 478533bd Postgres listens on a 0700 Unix socket in the App Group (`PostgresService.swift:474-489`; loopback TCP only as a long-path fallback, `:490-496`), the gRPC facade runs in-process on a Unix socket (`InProcessServiceHost.swift:18-43`), the MCP HTTP server is opt-in and off by default (`GarageMCPService.swift:120-144`), and assistants use stdio. A reviewer who checks `lsof` against the notes finds a mismatch.
- Step 6 ("registers Garage RAG with Claude Desktop or Claude Code") is a feature the reviewer cannot exercise without those apps; say so, and say what the write does (see L1).
- Nothing tells the reviewer about the tip jar (B2), Contacts (B3), Full Disk Access being optional (L2), or that Mail/Messages cards are shown greyed out until Full Disk Access is on.
- The header "Check before submitting: … B1 and B3 … (checklist item s9)" must not be pasted.
- A rewritten notes block is at the end of this file.

## Likely

**L1 (2.4.5(i), 2.5.2). The store build edits other apps' configuration files directly, under a home-folder grant.**
- Apple: Mac apps "should also only use the appropriate macOS APIs for modifying user data stored by other apps", and apps "may not read or write data outside the designated container area".
- Connect / Connect All / first-run page 4 write `~/Library/Application Support/Claude/claude_desktop_config.json`, `~/.claude.json`, `~/.cursor/mcp.json`, `~/.lmstudio/mcp.json`, Cline, Windsurf and Zed settings (`GarageMCPService.swift:243-337`, `install.py:60-145`), through McpInstall in the in-process gRPC host, using the home-folder or startup-disk grant (`GarageMCPService.swift:378-379` is the failure hint). Backups are made (`install.py:312-328`) and writes are atomic (`:331-352`), but there is no copy-a-JSON-snippet alternative; only the endpoint and the path can be copied (`MCPServerView.swift:148, 473`).
- The `Connect a Config File…` route (`MCPServerView.swift:623-635`) is the defensible one: a user-selected file, which is exactly what the sandbox is for. Reviewers have accepted "the user picked the file in an open panel"; they have rejected "the app rewrites another app's settings by itself".
- Mitigation for this submission: describe it precisely in the notes (the user picks the client, the app merges one `mcpServers` entry into that file, keeps a backup, and can remove it; the file is reachable only through the folder the user granted). Longer term: default to the per-file panel or a copyable snippet in the store build.
- Also note that what is written is `"command": "<Garage.app>/Contents/MacOS/garage-mcp"`, so the reviewer's Claude Desktop would launch a binary inside Garage.app. That is how every MCP server works and it is fine, but the notes should say it.

**L2 (5.1.1(iii), 2.4.5(i)). The app asks for the whole home folder or the startup disk, and for Full Disk Access.**
- First run's data page asks for the home folder first (good, `FirstRunView.swift:506-526`), but still offers "Select Startup Disk…" beside it, and the Full Disk Access step (`:540-555`) deep-links to Privacy & Security.
- After setup, the **Status** page row "Garage has no disk access yet — Choose Disk…" (`StatusPagePresentation.swift:252-256`) and the **Sources** page banner "Select your startup disk (Macintosh HD) once, and every source on it can be read — Select Disk…" (`SourcesPresentation.swift:340-349`) both go straight to `promptAndSelectRootVolume()` (`StatusView.swift:161-162`, `SourcesView.swift:137-139`). Neither offers the home folder. A reviewer who skips the assistant or lands on Status sees an app asking for `/`.
- Full Disk Access is detected by opening `~/Library/Application Support/com.apple.TCC/TCC.db` (`VolumeAccessService.swift:707-720`). It is a read of a protected system database that a sandbox-violation log would show, and it is undocumented behaviour. Reviewers rarely see it, but it is the kind of thing that draws a 2.5.1 question if they do.
- Data-minimisation reads: a folder-indexing app asking for the whole disk to "get around" per-folder grants. The v3 pass called this S2 and #106 fixed first run; the two later pages were missed.
- Fix: make "Select Home Folder…" the primary action on Status and Sources and keep the startup disk as the secondary; keep Full Disk Access optional and say so in the notes. Consider probing FDA through the Mail or Messages folder itself instead of TCC.db.

**L3 (2.3.1, 2.1). Mail and Messages are advertised in the app but need Full Disk Access to work.**
- The Sources page screenshot (`appstore-05-sources-light.png`) shows Messages and Apple Mail cards; the listing draft correctly leaves them out of "WHAT IT INDEXES". In the store build they show as selectable until a folder is granted (`FirstRunCoordinator.swift:683`, `SourcesView.swift:56`) and grey out afterwards without Full Disk Access. A reviewer who clicks Messages gets a "needs Full Disk Access" alert with "Open System Settings".
- That is workable if the notes say it up front (optional, off by default, needs Full Disk Access because macOS protects those folders even from a granted sandbox). Without that sentence it reads as a feature that does not work.
- Keep "Apple Mail and Messages" out of the description unless the store-build Mail/Messages path has passed on a Mac (checklist d1/A5 is still "Mac (store build)" in `v1.5-beta-validation.md`).

**L4 (2.3.1(a), 2.1). The listing copy makes two claims the store build only partly delivers.**
- "Git repositories, with authorship taken from the commit history" needs the Command Line Tools. `git.py:47-63` detects the stub without prompting and falls back quietly, so on a reviewer's Mac the sentence is simply not true. Say "when the Xcode Command Line Tools are installed" or "authorship from the commit history where git is available".
- "messages never leave your Mac" in PRIVATE BY DESIGN reads as Messages support (v3-N6, still in the draft). Say "communications" or drop it.
- The draft's header still says "Nothing has been changed in App Store Connect" while memory says the copy was applied on 2026-09-25; harmless, but check the live fields match the draft before submitting (subtitle, promotional text, keywords, URLs, copyright "2026 Rick Mark", contact first name).

## Possible

**P1 (2.4.5(iii)). The bundled `garage-mcp` launcher opens Garage.app hidden whenever an MCP client starts it.**
- `AppDatabase.prepare` → `launchHidden` (`GarageLauncher/AppDatabase.swift:44-94`) calls `openApplication` with `activates=false`, `hides=true`, `--background`. When Claude Desktop starts, Garage launches, stays in the menu bar with Postgres and the hourly maintenance timer, and keeps running after Claude Desktop quits.
- The user registered the client, so there is consent, and the app is visible in the menu bar, so this is not a background daemon. But `--background` is dropped for a sandboxed caller (`GaragePostgresEndpoint.swift:355-365`), so what actually happens on the store build is "hidden launch through the normal path" and has not been watched (inferred). Say it in the notes ("Assistants that were connected start Garage in the background when they need it; Garage → Quit stops it and every service").
- No login items, LaunchAgents or `SMAppService` anywhere. Good.

**P2 (2.4.5(i)). Entitlements the store build carries but does not use.**
- `GarageIngestXPCService` and `GarageXPCService` ship `files.user-selected.read-write`, `files.bookmarks.app-scope` and (the latter) `network.server`, but in the store build both run inside the app (`InProcessServiceHost.swift:4-43`); the embedded bundles never receive a grant. `network.server` on the app is justified by Postgres's fallback port and the in-process gRPC socket; `LlamaXPCService` and `GarageMCPServerService` use theirs.
- Reviewers seldom read nested-bundle entitlements, but the app-level `network.server` justification in the notes must be true (see B4).

**P3 (2.1). The Sources edit form's "Choose…" keeps no bookmark.**
- `chooseRoot()` copies `url.path` only (`SourcesView.swift:1103-1110`), so in the sandbox a folder picked there is readable only while that panel's implicit grant lasts, and only if the home/disk grant covers it. The first-run and "Add Folder…" paths do save bookmarks (`SourcesView.swift:1006-1022`). A reviewer using Custom Source… on a folder outside the granted tree would get a permission error on the next launch. Small fix: route it through `grantSourceAccess`.

**P4 (2.3.8, 2.3.10, 2.3.9). Screenshots and metadata.**
- All seven pages show the app in use with fictional sample data (Marrowgate Lighthouse, Tavish Glassworks) and no real person. Good.
- The MCP Server shot shows Claude Desktop, Claude Code, LM Studio and Cursor with their icons and file paths. 2.3.10 targets other *mobile platforms and marketplaces*, so this is fine, and naming Claude and Cursor in the description is fine; keep them out of keywords (the draft does).
- The Models shots list "gpt-oss 20B", "DeepSeek R1 Distill". Fine.
- The red bug button in every shot's corner is harmless.
- The About/tip screenshot shows "Version 1.5 (build 576)"; the IAP screenshot does not need to match the build number.
- Every shot is 2880×1800, an accepted Mac size.

**P5 (3.1.1, 2.3.10). The splash mixes the tip jar with self-promotion and shows at every launch.**
- "Available for hire … Get in touch" links to LinkedIn (`SplashView.swift:10, 201-216`) beside the tip buttons, and "Contributing to open source funds that unglamorous work" sits above them. None of it is a payment link, and 3.1.1 explicitly allows tips through IAP, but "Show this window at launch" defaults on, so the first thing a returning reviewer sees is an ask for money. Not a guideline violation. If you want to reduce friction, default the checkbox off in the store build.
- The Patreon URL is compiled into the store binary and hidden at runtime by the sandbox check (`SplashView.swift:9, 49-51, 179-193`). Never rendered, so 3.1.3 is met; a binary-strings scan could see "patreon.com". Low.

**P6 (2.4.5(iv)). The model downloader has no host or extension allow-list.**
- `ModelDownloaderEngine.swift:64-140` accepts any http(s) URL; the catalog (`https://garagerag.app/.data/models.json`, fetched at launch, `ModelCatalog.swift:15-54`) decides the Hugging Face repo and file. Everything the UI builds is `huggingface.co/…/resolve/main/*.gguf`, and llama.cpp loads GGUF as data, not code. v3-N2 stands: low risk, easy hardening.

**P7 (2.5.1). Two things a strict reviewer might call non-standard.**
- `stopAnyRunningInstances()` walks `proc_listpids` and signals processes by executable name (`XPCServiceManager.swift:833-874`). Same-user only; the sandbox likely refuses the non-child cases.
- `MainWindowSizing.swift:96-101` swizzles `NSWindow.constrainFrameRect(_:to:)` with the ObjC runtime, only under `--window-size` (UI tests), but the code ships. Public API; harmless.

**P8 (2.3.6, 5.1). Metadata questions to confirm in App Store Connect.**
- Age rating questionnaire (the 2025 version): the app hosts a local chat model ("Ask the Corpus", `rag_ask`). Answer the AI/unrestricted-content questions honestly; 4+ is defensible because the model only answers over the user's own indexed files.
- App Privacy stays "Data Not Collected": Contacts, Mail and Messages are read on-device and never transmitted; the policy (`privacy-policy.md` §3-5) says so. The privacy manifest declares no collected data types (`PrivacyInfo.xcprivacy`), consistent.
- Export compliance keys are present in the store Info.plist (`ExportCompliance.plist`, merged only for `is_store`): `ITSAppUsesNonExemptEncryption` true with Apple's code. Build 579 has them (verified in memory for 579; build 570 did not).

## Notes (passes)

- **Sandbox and hardened runtime (2.4.5(i)):** every bundle sandboxed; no `temporary-exception`, no `disable-library-validation`, no JIT or dyld-env entitlements anywhere; Postgres binaries `sandbox` + `inherit`.
- **Updates (2.4.5(vii)):** Sparkle is compiled out under `is_store` (`GarageUpdater/BUILD.bazel:12-21`); no `SUFeedURL` in the store plist; "Check for Updates…" renders nothing when the updater is unavailable.
- **Self-contained (2.4.5(ii), 2.5.2):** Python, site-packages, Postgres, llama.cpp, Tesseract all in the bundle; no pip, no `eval`/`exec`, no plugin loading; `subprocess` runs only the system `git` and `xcode-select -p`; Swift `Process` runs only bundled Postgres tools.
- **Network (2.5.x, privacy):** every listener is a Unix socket or 127.0.0.1; no `0.0.0.0`; MCP HTTP opt-in; the sandboxed helpers lack `network.server`, so `--allow-remote` cannot bind from them.
- **No analytics or crash SDK;** bug reports go to the pasteboard, a save panel or a pre-filled GitHub issue URL, all user-initiated.
- **No login items, no auto-launch at login, no Dock/desktop shortcuts.**
- **Copyright and licences:** `NSHumanReadableCopyright` "Copyright © 2026 Rick Mark-Penwell. MIT License."; `THIRD_PARTY_NOTICES.txt` behind Acknowledgements.
- **Minimum OS** 14.0 from `minimum_os_version` in Bazel; runs on the current OS.
- **Privacy policy content (5.1.1(i)):** identifies what is collected (nothing), the three network requests, Contacts use, retention (local, delete via Reset Database is implicit; worth one sentence), contact addresses. The site itself was not reachable from this session (egress blocked); open each listing URL once before submitting.

## What to do before submitting, in order

1. Fix B1 (privacy link) and B3 (Contacts only for communication sources) in the app; both are small. Rebuild, or accept that build 579 goes in without them and expect a metadata-rejection round on B1 at least.
2. Attach the five tip products to version 1.5 and check each is "Ready to Submit" (B2).
3. Replace the review notes with the block below (B4, L1, L2, L3, P1).
4. Apply L4's two wording changes to the description.
5. Optional in this build, worth a follow-up PR: L2 (Status/Sources buttons go to the home folder first), P3 (Choose… saves a bookmark), P6 (host allow-list).

## Proposed App Review notes (replace the current text)

> Garage RAG needs no account or sign-in and no other software.
>
> Everything runs on the Mac. On first launch the app starts its own PostgreSQL database inside its App Group container, listening on a Unix socket only. The built-in inference engine and the optional MCP HTTP server (off by default; 127.0.0.1:8787 when the user turns it on) are why the app and two of its helper services have the network server entitlement. Nothing accepts connections from other computers. The only network requests the app makes on its own are the model download the user chooses (from huggingface.co) and a small model catalog from garagerag.app.
>
> To try it:
> 1. Launch the app and follow the setup assistant. It waits for the local services to start.
> 2. When asked, select your home folder in the open panel. That one grant covers the starter locations (Documents, Desktop, Downloads and so on). You can pick a different folder instead.
> 3. Setup then offers Full Disk Access. It is optional: choose Skip. Full Disk Access is needed only for the optional Apple Mail and Messages sources, which macOS keeps behind it even for a granted sandbox; without it those two cards stay greyed out and everything else works.
> 4. Pick an embedding model. It downloads once and runs on the built-in engine.
> 5. On the Sources page, choose Update Everything, then search on the Search page.
> 6. Optional: the MCP Server page lists AI assistants installed on the Mac (Claude Desktop, Claude Code, Cursor, LM Studio and others). Connect adds one "garage" entry to that assistant's own MCP settings file, keeps a backup of the file, and Disconnect removes the entry. The file is written only inside the folder you granted, or one you pick with Connect a Config File…. A connected assistant starts Garage in the background when it needs it; Garage → Quit stops it and all its services.
>
> Contacts: when Mail or Messages are indexed, Garage can show contact names instead of phone numbers and addresses. macOS asks once; declining changes nothing else. Names stay on the Mac.
>
> In-app purchases: Garage → About Garage… shows a tip jar with five consumable tips (Small, Medium, Large, Max, Ultra). Tips unlock nothing; every feature is free.
>
> The App Store version has no updater of its own and writes only inside its container and the folders you grant. Indexed content never leaves the Mac.

(If B3 is not fixed before submission, change the Contacts paragraph to: "The first time Garage indexes anything it asks for Contacts access, which it uses only to show names for Mail and Messages. Declining changes nothing else.")
