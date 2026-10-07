---
name: release-developer-id
description: Cut a Developer ID (notarized, Sparkle) release or pre-release of Garage across Rick's Macs. Use when asked to build, notarize, tag or publish a Garage release, alpha or beta.
---

# Developer ID release

`RELEASING.md` is the order and the checks; `macapp/README.md` explains each command. This skill adds who does
what. Never repeat secrets (notary passwords, keys) in any message or file.

1. **Merge and verify.** Everything for the release is on `main`; run a full pass from the exact commit
   (`.claude/skills/mac-test-pass`). Release from head and re-test on the same head.
2. **Build on the M4** from a full clone: `aspect build //macapp/package:GarageApp`, then
   `aspect run //macapp/package:notarize_all` (notary keychain profile `Primary`; if missing, Rick runs
   `xcrun notarytool store-credentials Primary`). Ask before running notarytool outside the tool sandbox.
   It leaves `dist/Garage-<ver>.zip` and `dist/GarageInstaller_arm64.pkg`; record both submission IDs.
3. **Check the bundle** (RELEASING.md step 4): arm64 only, `codesign --verify --deep --strict`, `spctl -a -vv`,
   `stapler validate`, no `get-task-allow`. Rick smoke-tests the installer (it needs his admin password).
4. **Tag only now**, on the commit that was built: `v<ver>` for a release, `v<ver>-alpha.N`/`-beta.N` for a
   pre-release. Rick signs it (`git tag -s`) on the M4/M3, or Phobos signs it while he is away.
5. **Appcast** (releases and betas, not alphas): copy `dist/Garage-<ver>.zip` to Phobos, which holds the Sparkle
   key, and run `aspect run //macapp/package:sign_appcast -- v<ver> --from Garage-<ver>.zip --notes notes.md`
   there. Ask Rick before using `--channel beta`.
6. **Publish in order:** GitHub release from the tag with the zip and pkg under those exact names
   (`gh release create v<ver> ... [--prerelease] --verify-tag`; cloud sessions have no release tool, so a Mac
   or Rick does it), then commit and push `docs/appcast.xml` (signed), then
   `aspect run //macapp/package:publish_appcast -- --check-live` once Pages deploys.
7. Check garagerag.app's download button in light and dark, and update the project memory with the build number.
