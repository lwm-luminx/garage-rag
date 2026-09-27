# Releasing Garage

This is the order the 1.5 release follows. Reuse it for every later release. The commands themselves are explained in [`macapp/README.md`](macapp/README.md): see "Cutting a release", "App Store configuration" and "Provisioning profiles". This file only says what comes when, and what has to be checked before each step.

Garage ships two ways:
- **Developer ID**: notarized, updates itself through Sparkle, and is downloaded from garagerag.app and GitHub Releases.
- **App Store**: sandboxed, with no updater, and goes through App Review.

Both are built from the same commit and share one data folder and one Keychain item.

## 1. Before the cut

- [ ] Everything meant for the release is merged into `main`, and CI is green there, including `.github/workflows/macos.yaml` (`aspect test //...` on macOS).
- [ ] Run the full UI suite on a Mac (`GarageAppUITests` and the model UI tests), plus the store pass with `TEST_RUNNER_GARAGE_UITEST_STORE_APP`. Run `garage quit` first: a UI test run refuses to share the Mac with a running Garage.
- [ ] Bump `short_version_string` in `macapp/Sources/GarageApp/BUILD.bazel`, and the Python package version if it changed.
- [ ] Regenerate `data/notices/THIRD_PARTY_NOTICES.txt` (`python3 tools/third_party_notices.py`) if dependencies or anything under `ext/` changed.
- [ ] Write the release notes as a Markdown file. They're used for Sparkle's update window, the GitHub release and the App Store's What's New.

## 2. Developer ID

1. **Freeze `main` and build from a full clone.** `CFBundleVersion` is the commit count of `HEAD` (`bazel/workspace_status.sh`). A shallow clone or a stale branch produces a lower number, and Sparkle won't offer it.
2. **Tag.** Push a signed tag `v<version>` (for example `v1.5`). Commits and tags are signed with Secretive.
3. **Build, notarize and staple:**
   ```bash
   aspect build //macapp/package:GarageApp
   aspect run //macapp/package:notarize_all
   ```
   `notarize_all` notarizes the app, staples it, builds the installer from the stapled app, then notarizes and staples the installer. It leaves `dist/Garage-<version>.zip` and `dist/GarageInstaller_arm64.pkg`. Record both notary submission IDs it prints.
4. **Check the bundle on the Mac that built it:**
   - `lipo -archs` over the app and the site-packages `.so` files should say `arm64` only. Garage is Apple Silicon only.
   - `codesign --verify --deep --strict` and `spctl -a -vv` should pass on the app and the `.pkg` in `dist/`.
   - `xcrun stapler validate` should pass on the app unpacked from the zip and on the `.pkg`.
   - No release entitlement may carry `get-task-allow`.
5. **Add the release to the feed:**
   ```bash
   aspect run //macapp/package:publish_appcast -- v<version> --notes notes.md
   ```
6. **Publish, in this order**, so the feed never names a download that isn't up yet:
   1. Create the GitHub release from the signed tag with `dist/Garage-<version>.zip` and `dist/GarageInstaller_arm64.pkg`. Those exact names matter: the appcast signature covers the zip, and the site's download buttons look for the `.pkg` name.
   2. Commit and push `docs/appcast.xml`, signed.
   3. Once Pages has deployed, run `aspect run //macapp/package:publish_appcast -- --check-live`.
7. **Check the site.** garagerag.app's download button should fetch the new `.pkg`. Look at the page in light and dark.
8. **Rehearse the update from the previous release** at least once per major change to the updater. Install the previous version, then let it update to this one and relaunch.

## 3. App Store

1. Make sure App Review has answered on the previous submission, then create the new version in App Store Connect.
2. Build the archive from the signed release tag and open it in Organizer:
   ```bash
   git checkout v<version>
   aspect run //macapp:xcarchive_open --bazel-flag=--config=appstore_release
   ```
   Build it from the tag, not from `main`. The appcast commit from Developer ID step 6 moves `main` one commit ahead, and `CFBundleVersion` is the commit count, so building from `main` would give the two distributions different build numbers.
3. In Organizer, run **Validate App** first, then **Distribute App**. It re-signs the app with Apple Distribution and three store profiles:
   - `GarageMacAppConnect` for the app;
   - `GarageRAGAppStoreCLI` for `garage.app`;
   - `GarageRAGAppStoreMCP` for `garage-mcp.app`.
4. Install the build through TestFlight on a Mac that didn't build it. Check the first-run assistant, the home folder grant, one source ingested and found by search, and MCP registration.
5. Update the listing:
   - What's New, and the screenshots (`StoreScreenshotsUITests`, 2880 × 1800, light and dark);
   - the App Privacy answers, which must match `docs/support/privacy-policy.md`;
   - the Notes for App Review.
6. Submit for review.

## 4. After the release

- [ ] Install the release over the previous one from the website, on a clean user account.
- [ ] Watch in-app bug reports and GitHub issues for the first few days. Collect what they turn up into the next point release.
- [ ] Update this file with anything that went differently.
