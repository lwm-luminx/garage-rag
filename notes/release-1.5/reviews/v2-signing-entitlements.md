# 1.5 review: signing and entitlements (repo half)

**Verdict: not ready as checked out. Two blockers: the RC predates #103, so it ships the old app profiles, and four XPC services are signed without hardened runtime in the store config. Everything else is clean or cosmetic.**

Tree: `review-tree` at 0a35384 (#102 head), a shallow clone. Its merge base with origin/main is 6bc04af, so #103 (82a424a, now on origin/main) is **not** in it. Baseline: tag v1.0 and `/mnt/project-files/release-review/entitlements-audit.md`. The audit's commit a3e7081 no longer exists after the re-sign, so I compared against the audit's tables rather than a diff. Nothing was built. Every profile decoded with `openssl smime -verify -noverify` ("Verification successful" for all 10).

## Findings

**Blocker: the RC carries the pre-#103 app profiles, which still grant Sustained Execution.**
- `macapp/GarageMacAppConnect.provisionprofile`, `GarageRAGDeveloperID.provisionprofile` and `GarageRAGDevelopmentApp.provisionprofile` at 0a35384 all carry `com.apple.developer.sustained-execution = true`.
- On origin/main, 82a424a regenerated all three without it. The new ones were created 2026-09-25 about 20:00 and are otherwise identical: same App ID, same groups, same keychain groups, 2 devices on the development profile.
- Turning the capability off on the App ID most likely marks the old profiles Invalid in the portal (inferred). That matters most for GarageMacAppConnect, which Organizer uses at upload.
- Fix: rebase #102 onto origin/main, or cherry-pick 82a424a, before tagging.

**Blocker: four XPC services get no `--options=runtime` in the store and Developer ID configs.**
- These `macos_xpc_service` targets have no `codesignopts = HARDENED_RUNTIME_CODESIGNOPTS`, and never had one (v1.0 didn't either):
  - `macapp/Sources/GarageXPCService/BUILD.bazel:19`
  - `macapp/Sources/GarageEmbedXPCService/BUILD.bazel:18`
  - `macapp/Sources/GarageMCPServerService/BUILD.bazel:17`
  - `macapp/Sources/GarageIngestXPCService/BUILD.bazel:17`
- These do have it: LlamaXPCService (`BUILD.bazel:29`), ModelDownloadXPCService, the app (`GarageApp/BUILD.bazel:76`), both helpers (`bazel/launcher_app.bzl:110`), Postgres (`externals/BUILD.bazel:45`) and Python.framework (the codesign rule's default is `["runtime"]`).
- **Developer ID impact:** the release path `//macapp/package:GarageApp` re-signs every Mach-O with `--options=runtime` (`bazel/lipo.bzl:174,272-273`), so the notarized build is covered. The direct `//macapp:Garage.app` build is not.
- **Store impact:** nothing re-adds the flag before Xcode's upload re-sign. The Mac App Store doesn't require hardened runtime, so Apple would probably accept the build (inferred), but it fails this release's rule.
- Fix: add one line to each of the four BUILD files.

**Should fix: no codesign_test covers the assembled app or its XPC services.**
- `codesign_test` exists only for the two helpers (`bazel/launcher_app.bzl:153`) and Python.framework (`ext/python/BUILD.bazel:140`).
- A test over the app archive, with `hardened_runtime = HARDENED_RUNTIME_EXPECTED`, would have caught the blocker above.

**Note: status of the earlier audit's recommendations.**
- **Landed, and went further than the audit:** `disable-library-validation` is gone from every entitlements file (the app, all six XPC services and the helpers). The v1.0 XPC files had it, plus `inherit` mixed with other keys. The rationale is in `bazel/codesign.bzl:20-25`: everything is signed with one Team ID. The audit had said keep it. Only a run can confirm it is safe (see the Mac list).
- **Landed:** the unused Contacts/Calendars/Reminders/AppleEvents usage strings are gone, and `ITSAppUsesNonExemptEncryption` was added (`GarageApp/Info.plist:31`).
- **Changed design:** the Keychain went with the audit's option 2 (data-protection keychain, access group = App Group), not its recommended option 1 (a 0600 password file).
  - The app and both launchers became profile-backed: they carry `com.apple.application-identifier`, `team-identifier` and `keychain-access-groups`, in `Garage.entitlements`, `GarageDeveloperID.entitlements`, and `GarageCLI`/`GarageMCPCLI` `.entitlements` / `.developer_id.entitlements`.
  - The launchers are now helper bundles, and `GarageLauncher.entitlements` is gone.
  - Six new helper profiles were added: dev, Developer ID and App Store, for each of the two helpers.
  - XPC services never read the password (only `PostgresService` and `GarageLauncher/AppDatabase.swift:63` do), so they correctly have no application identifier.
- **Not landed: the redundant `files.user-selected.read-only` (known leftover).** It is in **8** files at 0a35384, not 9; the ninth was probably the deleted `GarageLauncher.entitlements` (inferred):
  - `GarageApp/Garage.entitlements:15`
  - `GarageXPCService…:13`, `LlamaXPCService…:13`, `GarageMCPServerService…:13`
  - `GarageEmbedXPCService…:11`, `GarageIngestXPCService…:11`, `ModelDownloadXPCService…:11`
  - `externals/Garage.entitlements:9`
- **Not landed:** `macapp/externals/Garage.entitlements` is still in the tree and nothing references it. Delete it.
- **Not landed:** `user-selected.*` and `bookmarks.app-scope` are still on the Embed, MCPServer, Llama, ModelDownload and GarageXPC services. The audit found no use for them (only Ingest resolves bookmarks). It said to trim them after a store scan run, and that run hasn't happened.
- **Not landed:** LlamaXPCService still has `network.client` (`LlamaXPCService.entitlements:7`). The audit listed server only.

**Note: the store build carries no forbidden entitlement.**
- No entitlements file, and no BUILD or bzl file, contains `disable-library-validation`, `get-task-allow`, any `temporary-exception`, `allow-jit` or `allow-unsigned-executable-memory`.
- No decoded profile grants `get-task-allow`.
- Postgres keeps sandbox + inherit (`externals/GarageServer.entitlements`), store only (`externals/BUILD.bazel:41-44`).

**Note: the Team ID and App Group are consistent.**
- Every team-prefixed string is `DWVXMLB45Y`: 22 × `DWVXMLB45Y.group.me.rickmark.garage-rag`, plus the three app IDs. The code constant is the same (`PythonXPCService/GarageAppGroup.swift:14`).
- Every profile has `TeamIdentifier = DWVXMLB45Y`, and every signing certificate in them has OU `DWVXMLB45Y`.
- The profiles authorize `group.me.rickmark.garage-rag` and `DWVXMLB45Y.*`. The entitlements' team-prefixed group matches through the wildcard.
- `macapp/README.md:261-263` says the portal writes the team-prefixed group into the profile. It actually writes the wildcard. The wording is slightly off, and nothing breaks.

**Note: XPC services have no provisioning profiles.**
- This brief expected profiles for the six XPC services. None exist, and no config selects one: only the app and the two helpers embed one (`GarageApp/BUILD.bazel:102-106`, `launcher_app.bzl:134-138`).
- By design they claim only unrestricted entitlements: sandbox, network, and the team-prefixed group. So no profile should be needed for the store or Developer ID (inferred).

**Note: profile inventory, expiry and certificates.**

| Profile | App ID suffix | Type | Expires | Sustained Exec. |
|---|---|---|---|---|
| GarageRAGDevelopmentApp | (app) | Dev, 2 devices | 2027-09-23 | yes (fixed in #103) |
| GarageRAGDeveloperID | (app) | Developer ID | 2044-09-19 | yes (fixed in #103) |
| GarageMacAppConnect | (app) | App Store | 2027-09-02 | yes (fixed in #103) |
| GarageRAGDevelopmentCLI / MCP | .garage-cli / .mcp-server-cli | Dev, 2 devices | 2027-09-24 | no |
| GarageRAGDevIDCLI / MCP | same | Developer ID | 2044-09-19 | no |
| GarageRAGAppStoreCLI / MCP | same | App Store | 2027-09-02 | no |
| TeamSplatDevelopment | `DWVXMLB45Y.*` wildcard | Dev | 2027-09-23 | no; referenced nowhere, delete or document |

- The Developer ID certificate inside all three Developer ID profiles expires **2027-02-01**. Profiles must be regenerated with the next certificate, despite the 2044 date.
- The development profiles each list two certificates with the same CN, `Apple Development: Rick Penwell (23E5F7Z5L7)`, expiring 2027-02-05 and 2027-09-02. If both are in one keychain, `codesign -s "<name>"` may fail as ambiguous (inferred).

**Note: Sparkle is kept out of the store build.**
- `GarageUpdater/BUILD.bazel:12-21` picks the inert backend and drops `//ext/sparkle:Sparkle` under `is_store`.
- `GarageApp/BUILD.bazel:90-93` drops `Sparkle.plist` from the store build.
- Nothing else depends on `//ext/sparkle` or the `//ext:Sparkle` alias, except the manual `package:publish_appcast` tools.

**Note: the Info.plist privacy keys and the privacy manifest match the code.**
- The usage strings cover exactly Documents, Downloads and Desktop (`GarageApp/Info.plist:25-30`), the folders `VolumeAccessService` asks for.
- Messages and Mail go through Full Disk Access, which has no Info.plist key.
- There is no string for removable or network volumes, though a source can be a whole volume. A Developer ID build would get the generic TCC prompt text (inferred; low priority).
- `PrivacyInfo.xcprivacy` declares UserDefaults CA92.1, FileTimestamp C617.1 + 3B52.1, SystemBootTime 35F9.1 and DiskSpace E174.1. All match the stated uses, and there is no `UserDefaults(suiteName:)` that would need 1C8F.1. It is copied to Resources (`GarageApp/BUILD.bazel:71`).
- `ITSAppUsesNonExemptEncryption = false` while the bundle carries OpenSSL and BoringSSL (see `openssl-audit.md`). This is the owner's call; App Store Connect may still ask about France.

**Note: a stale comment.** `GarageCLI/GarageCLI.entitlements:11-12` describes a library-validation exemption that the file no longer contains.

## Only the Mac check of the built app can confirm
- `codesign -dvvv` shows `flags=…runtime` on every Mach-O in the store archive and the Developer ID zip, the four XPC services in particular. Also whether Xcode's upload re-sign keeps or adds the flag.
- `codesign -d --entitlements - --xml` on each bundle matches the files above. Check that no `get-task-allow` is injected into the Apple Development-signed store build.
- With DLV gone, Python extension modules, libpq, Tesseract and the pgvector/AGE dylibs all load under library validation (`tools/macos/trace_loaded_images.sh`). Check both the store build and the Developer ID build.
- A Developer ID launch on macOS 15+ shows no "access data from other apps" prompt for the group container from the profile-less XPC services.
- Organizer's Validate App accepts the archive. Check the helper bundles, the `/bin/sh` forwarders symlinked from `Contents/MacOS`, and any `Python.framework/Resources/Python.app`, which `ext/python/BUILD.bazel:81-101` doesn't prune (inferred).
- The launchers read the Postgres password from the App Group keychain without a prompt in both signed configs.
- Whether the pre-#103 profiles now show as Invalid in the portal.
