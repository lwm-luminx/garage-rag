# What landed on 2026-09-24, checked against main

**Checked 2026-09-25 00:20 UTC: everything is on main, and every commit is signed.**

- origin/main is **7e7032a**. It was force-pushed over 00ff505 to re-sign the commits, and its file tree is identical to 00ff505's (`git diff 00ff505 origin/main` is empty).
- Every commit from b9e84fd~8 to main has a signature: 45 of 45.
- The 27 re-signed commits (after 2f69a41) are all signed by one key, ecdsa-sha2-nistp256 `SHA256:1biWLoagP+vfE0/M8dNqAy1UjXT8oW2lWTbJGUeVYTQ`, which is Secretive's key type. The earlier commits carry GitHub's merge signatures.
- The re-sign changed the SHAs of 4de3ee0 and everything after it. Checkouts made before 00:19 UTC need `git fetch && git reset --hard origin/main`.
- Branches based on the old main need rebasing onto the new SHAs (for example claude/project-thread-v9zhqg, launcher-helper-bundles, m4-maintenance-source-add). claude/project-thread-82ssh4 was also force-updated.
- GitHub still shows #69 as closed rather than merged, but its 9 commits are on main.

## On main
| PR | What | Commit on main |
|---|---|---|
| #39 | M3 validation notes (00:01 UTC) | 52409db |
| #13 | In-app bug report composer | 22d2487 |
| #41 | Restore splash update card + notices link | d52f97c |
| #42 | Fix main's build, notices test, xcarchive_open | c91d4e3 |
| #44 | Serve the site at garagerag.app | 2c3e63a |
| #45, #46 | Share //ext builds across signing configs; appstore_release | aa93100, 29c14dd |
| #43 | Tidy Sources/Status/Models/Database; grow the window; XCUITest suite | b9e84fd |
| #47 | garagerag.app intro/download page; support at /support/ | 48ae4c7 |
| #49 | Apache AGE as a bundled Postgres extension | 7d36b04 |
| #48 | Keep the DB password out of garage.json on import | c2e2862 |
| #52, #55 | Site says Apple Silicon only | 75e2c20, 37612be |
| #54, #56, #58 | Scans on their own runner; show gRPC errors | 64ad206, b6c8faa, 2f69a41 |
| #51, #57 | Preload AGE; ag_catalog on search_path | d702d77, 1f0295e |
| #50 | Build Postgres and CPython on a Windows runner | 4de3ee0, 6c89104, ebef454 |
| #53 | Framework-linked libpq/libtesseract; scan progress on Status; catalog + schema from the site | 5f26191, 37cd827, 172e565, 780775b, ade8935 |
| #62 | Store launchers sandboxed on their own; exit on SystemExit | a74bbbd, c5b3280 |
| #68 | One-command Sparkle appcast publish | b8fb5fe |
| #65 | App version 1.5 | c932f7b |
| #63 | AGE generated parser out of the Xcode build's way (+ stale-output fixup) | cbc9b40, 8c8dd73 |
| #66 | Store build ready for App Review privacy questions (+ encryption answer) | 6403104, 5bb0670, da5c8b2 |
| #71 | Scroll the Sources form into view in UI tests | f0aba74 |
| #69 (incl. #64, #70's port) | Launchers as helper bundles, App Group keychain, Keychain off the main thread, 6 provisioning profiles | fddabe9, 2fb484a, 7e08e7b, 26d2249, ad82ffa, e74eb1d, 5a5fbed, 959a759, 7e7032a |

#60 and #61 merged empty after #48 and need no commit.

## Not landed, on purpose
#67 (password file) and #70 (redundant with #69) were closed.
#59, #40 and #28 were closed unmerged and aren't part of this work.

## Missing
Nothing.
