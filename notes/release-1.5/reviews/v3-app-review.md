# Garage 1.5: App Review readiness (v3)

**Verdict: not ready to submit.** In the sandboxed store build, the source and MCP-registration paths that the Review notes send the reviewer through most likely do not work (inferred; no store build was run). Test them on a store-signed build first. Sparkle exclusion, container discipline, login items and the privacy policy are in order.

Reviewed tree: `0a35384` (#102 head). Listing: `/mnt/project-files/app-store-listing/draft.md`. Read-only review, and nothing was built or run. "Inferred" means I read it from the code and did not see it on a device.

## Findings

**B1. Blocker (2.1): the sandboxed services probably can't read any folder the user picks (inferred).**
- The user picks a folder in `GarageApp`, which makes an app-scoped bookmark from it (`VolumeAccessService.swift:678-691`). The bookmark's bytes go over XPC to the ingest service (`:692-697`, `GarageIngestXPCService/main.swift:201-205`).
- The ingest service resolves those bytes as its own bookmark (`IngestEngine.swift:106-121`). An app-scoped bookmark resolves only in the app that made it, and the ingest service is a separately signed bundle with its own container. The catch falls back to `options: []`, which gives back a bare path with no sandbox extension, and `startAccessing…`'s result is ignored (`:130`). The UI can therefore report "Resolved source bookmark" while every read fails.
- Scan (`AppState.swift:894`), `AddSource`'s existence check (`ops/sources.py:62-64`) and `McpInstall` all run in `GarageXPCService`, the gRPC host (`GarageXPCService/main.swift:10`). That service never receives a bookmark at all.
- `entitlements-audit.md:27` already flagged the handoff as unverified.
- Fix: send the `URL` itself over NSXPC, which carries a sandbox extension, to every service that touches user files: ingest and the gRPC host. Each service then calls `startAccessingSecurityScopedResource` and keeps its own bookmark. Test Documents, a custom folder and a git repo on a store-signed build.

**B2. Blocker (2.1): template roots resolve inside the sandbox container (inferred).**
- Presets and first-run templates store roots as `~/…` (`SourcePresets.swift:22-42`, `FirstRunCoordinator.swift:213-223, 266-275`).
- In the sandbox, `homeDirectoryForCurrentUser`, and the `HOME` that Python's `expanduser` reads, point at each process's own container. No code overrides `HOME`: the only real-home lookup is `GarageAppGroup.swift:150`.
- As a result, the templates show as unavailable, or `AddSource` either fails with "does not exist" or registers an empty container folder. That is Review-notes step 2, "Pick a starter source", and the Status page's quick-add of Documents and Messages (`SourcePresets.swift:50-56`).
- Fix: resolve `~` against `getpwuid` on both the Swift and Python sides. Better, have the store build open an open panel for each template and register the absolute path the user picks.

**B3. Blocker (2.1; 2.4.5 is fine): "Register with Claude Desktop / Claude Code" writes inside the container (inferred).**
- Detection reads `homeDirectoryForCurrentUser/Library/Application Support/Claude/claude_desktop_config.json` and `~/.claude.json` (`GarageMCPService.swift:196-218`).
- The write goes through `McpInstall` in `GarageXPCService`, where Python's `Path.home()` (`mcp_server/install.py:60-81`) is that service's container.
- So nothing escapes the container, and 2.4.5(ii) holds. But the real Claude configs are never found or changed, and Review-notes step 5 fails. The custom-file option (`MCPServerView.swift:619`) hands only a path to a process that has no extension for it.
- Do not fix this with a `temporary-exception.files.home-relative-path` entitlement: Review routinely rejects those.
- Fix, for the store build: have the user pick the config file in an open panel (as in V3-B1), or show a copy-able JSON snippet plus the `http://127.0.0.1:8787/mcp` URL. Also drop step 5 from the notes, or reword it.

**S1. Should fix (2.1 / 2.3.1): Mail and Messages are offered but can't work in the store build.**
- The listing correctly leaves them out. But the store UI still offers them: the Messages and Mail templates, and Messages in quick-add (`SourcePresets.swift:51`).
- The site advertises them: `docs/index.md:4,10,24` and `support/guide.md:56,126-128`.
- The UI says "macOS will ask for Full Disk Access" (`FirstRunView.swift:454`). macOS never asks for that. The user has to turn it on in System Settings.
- The "Select Folder Directly…" route bookmarks `~/Library/…` as the sandbox resolves it, which is the container (`VolumeAccessService.swift:636-641, 672-674`).
- The first-run "Add custom folder…" path registers any folder as `filesystem`/`document`/`authored` (`SourcesView.swift:1003`). That means `chat.db` would never go through the `sqlite` conversations path.
- The Sources form's "Choose…" keeps no bookmark at all (`SourcesView.swift:1110-1117`), so access ends when the app quits.
- Hide Mail and Messages in the store build until checklist d1 passes on a store build. What working support would take is below the findings.

**S2. Should fix (5.1.1(iii) data minimisation, 2.4.5(i)): asking for the whole startup disk.**
- First run asks the user to "Select Root Hard Drive…" so that Garage "can read the folders you choose below" (`FirstRunView.swift:462-483`, `VolumeAccessService.swift:604-633`).
- Reviewers commonly reject a whole-disk Powerbox grant used to get around the sandbox. Ask for each source folder instead.

**S3. Should fix (3.1.1): Patreon button in the store build.**
- "Support Rick on Patreon" (`SplashView.swift:8, 150-159`) links to an outside payment for a digital tip. That is accepted only on the US storefront. Put it behind `//bazel:is_store`, as `GarageUpdater` does.

**S4. Should fix (2.3.1 / 2.1): git authorship depends on developer tools the reviewer probably lacks.**
- `attribute/git.py:60-71` and `ingest/scanner.py:269-277` run `git` from `PATH`. In an XPC service that is `/usr/bin/git`, the stub that asks to install the Command Line Tools.
- A reviewer's Mac probably has no Command Line Tools. Attribution then falls back quietly, so the listing line "authorship taken from the commit history" (draft.md:39) is not true for most users.
- Say "when the Xcode Command Line Tools are installed", or read `.git` without the binary.

**S5. Should fix (2.4.5(i)): entitlements the store build does not need.**
- `user-selected.read-only` sits beside `read-write` in every service.
- `user-selected` and `bookmarks.app-scope` are on the Embed, MCPServer, Llama and ModelDownload services (`*/…XPCService.entitlements`), which have no bookmark code.
- `network.client` is on `LlamaXPCService`.
- Also, the `network.server` justification in draft.md:88 leaves out the gRPC listener between the app and `GarageXPCService`, on a random 127.0.0.1 port (`GarageGRPCService.swift:240`).

**N1. Note (2.4.5): passes.**
- Every service is sandboxed (`Garage.entitlements`, each `*XPCService.entitlements`). Postgres runs with `sandbox` plus `inherit` (`externals/GarageServer.entitlements`).
- Sparkle is compiled out of the store build: `GarageUpdater/BUILD.bazel:13-20`, and the Sparkle plist only when not store (`GarageApp/BUILD.bazel:90-93`).
- No login items or `SMAppService`. Helpers live in `Contents/Helpers` and `Resources/launchers` (`GarageApp/BUILD.bazel:60-63`).
- `~/.garage.json` is only read as a candidate (`GarageConfigLoader.swift:255`). Writes go to the App Group folder.
- The legacy symlink is made only when unsandboxed (`GarageDataMigration.swift:44`).
- No sustained-execution entitlement is in the tree. After #103, clear the Review justification field.

**N2. Note (2.5.2 / 2.4.5(iv)): model downloads are data, not code.**
- GGUF weights come from Hugging Face on request (`ModelDownloadModels.swift:227-353`), and llama.cpp loads them as data.
- `models.json` (`ModelCatalog.swift:15`) is a list of choices, not code.
- No code is downloaded: no pip, and Python and site-packages ship in the bundle.
- The downloader accepts any host and `.bin`/`.pt`/`.onnx` extensions (`ModelDownloaderEngine.swift:216`). Consider limiting it to `huggingface.co` and `.gguf`.

**N3. Note (5.1.1/5.1.2): privacy.**
- "Data Not Collected" matches the code. The models.json fetch sends no identifiers, and the Hugging Face and GitHub Pages IP logs are disclosed (`support/privacy-policy.md:63-71`).
- Report a Bug copies to the pasteboard for the user to post, which counts as optional user-initiated feedback.
- Wording fix: privacy-policy.md:79 says access requires authorisation "under System Settings". In the sandbox it is the open panel.
- The purpose strings (`Info.plist`: Documents, Downloads, Desktop) are fine but have no effect under the sandbox. There is no string for Mail, Messages or Full Disk Access, and none exists to add.

**N4. Note (5.1.2 privacy manifest).**
- `PrivacyInfo.xcprivacy` declares UserDefaults CA92.1, FileTimestamp C617.1/3B52.1, SystemBootTime 35F9.1 and DiskSpace E174.1. These match the uses I found.
- No suite (App Group) UserDefaults are used, so 1C8F.1 isn't needed.
- The manifest sits only at the app level. I could not verify whether upload validation also wants one in `PythonXPCService.framework`, which carries CPython, libpq and Tesseract. Inferred low risk.

**N5. Note (export compliance): check `ITSAppUsesNonExemptEncryption=false`.**
- `Info.plist` sets it to false, but the bundle ships OpenSSL (CPython `ssl`, libpq). Standard algorithms outside the OS may call for the "standard encryption" answer and the France declaration. Inferred.

**N6. Note (2.3): listing copy.**
- "messages never leave your Mac" (draft.md:52) reads as Messages support. Say "communications" or drop it.
- Review-notes step 2 says "when macOS asks for access". In the sandbox, the user picks the folder in an open panel.
- The draft's header says "Nothing has been changed in App Store Connect" (draft.md:3). The brief says it has been applied. Confirm which is true.
- Mentioning third-party names (Claude, Cursor) in the description is fine. They are correctly kept out of the keywords.

## Mail and Messages in the store build

What the code does now:
- Mail and Messages are presets with `~` roots. The app shows a Full Disk Access / "Select Folder Directly" alert.
- It saves app-scoped bookmarks in `GarageApp`'s defaults and hands their bytes to the ingest service.

What working support would take (inferred):
1. **The folder picked in an open panel.** This is what lifts the sandbox for `~/Library/Mail` and `~/Library/Messages`. Full Disk Access does not lift the sandbox.
2. **Full Disk Access as well.** Both folders are TCC-protected apart from the sandbox. Probably both are needed: the panel for the sandbox, Full Disk Access for TCC. XPC services should inherit the app's TCC grant as their responsible process.
3. **V3-B1's URL handoff**, so the ingest service and the gRPC host actually hold the extension.
4. **Registration** as `sqlite`/`maildir` with the absolute path the user picked.

Without all four, ship them as Developer ID only.

## Proposed App Review note (Mail and Messages)

> Indexing Apple Mail and Messages is optional and off by default. Garage reads them only after the user takes two steps: selects the ~/Library/Mail or ~/Library/Messages folder in a standard open panel, and turns on Full Disk Access for Garage in System Settings, because macOS protects those folders even from sandboxed apps that the user has granted access to. Garage stores them on the Mac as "communications", and its network layer refuses to send them to any address that is not on the Mac itself. Nothing is indexed without these steps, and the app is fully usable without them.

(Use this only once V3-S1 is fixed and verified on a store build. Until then, hide the feature in the store build and leave this paragraph out.)
