# Releasing Garage

The App Store release, and the Developer ID release's Sparkle feed, are cut from
[garage-enterprise](https://github.com/lwm-luminx/garage-enterprise), which carries this repository as a
submodule (`docs/RELEASING.md` there). A notarized Developer ID build for a GitHub release can also be
made from a checkout of this repository ("GitHub release" below). Everyday builds here sign with the
best identity the keychain has (`macapp/README.md`, "Which identity a local build signs with").

What a release still needs from here, before the cut:

- [ ] Everything meant for the release is merged into `main`, and CI is green there, including
      `.github/workflows/macos.yaml` (`aspect test //...` on macOS).
- [ ] Bump `short_version_string` in `macapp/Sources/GarageApp/BUILD.bazel` and `VERSION` in
      `rust/garage-service/src/service.rs` (the version `garage version`, the backend and the Windows
      installers report).
- [ ] Regenerate `data/notices/THIRD_PARTY_NOTICES.txt` (`python3 tools/third_party_notices.py`) if dependencies or anything under `ext/` changed.
- [ ] After a Developer ID release, commit the entry garage-enterprise's appcast step wrote to `docs/appcast.xml`
      (the feed is served from this repository's site).

## GitHub release (Developer ID)

`//macapp/package` builds the Developer ID distribution with what the Mac it runs on holds, so
nothing secret or team-specific is checked in (`bazel/signing_identity.bzl` finds it):

- the **Developer ID Application** and **Developer ID Installer** certificates, with their keys, in
  the keychain (`security find-identity -v` lists them);
- the three **Developer ID provisioning profiles**, for `<team>.me.rickmark.garage-rag`,
  `.garage-cli` and `.mcp-server-cli`, installed for Xcode (double-click each, or Xcode, Settings,
  Accounts, Download Manual Profiles), or in a folder named by
  the `GARAGE_PROVISIONING_PROFILES=<dir>[:<dir>...]` environment variable (`aspect` takes no
  `--repo_env`; with plain `bazel`, `--repo_env` works too; garage-enterprise's `macapp/` holds them);
- a notarytool keychain profile, `Primary` unless you pass another
  (`xcrun notarytool store-credentials Primary`).

The entitlements name the `DWVXMLB45Y` team's App Group and application identifiers, so this signs
a working app only with that team's certificates and profiles.

```bash
aspect build //macapp/package:GarageApp           # signs with Developer ID, hardened runtime
aspect run //macapp/package:notarize_all          # -- --keychain-profile <name> for another profile
```

`notarize_all` notarizes and staples the app, builds and signs the installer from it, notarizes and
staples that, and leaves `dist/Garage-<version>.zip` and `dist/GarageInstaller_arm64.pkg`. Attach
both to the GitHub release for the signed tag (`gh release create v<ver> dist/Garage-<ver>.zip
dist/GarageInstaller_arm64.pkg`). A missing certificate or profile fails the build with a message
naming it. The appcast is not touched: Sparkle updates come from garage-enterprise's
`publish_appcast`.

## The Python package

`garage-rag` on PyPI was reserved for the Python package but never published, and the package is
gone (`docs/plans/python-removal.md`): the command line is `rust/garage-cli`, shipped in the Mac
app and the Windows installers. A thin Python wrapper with the same `garage` commands may come back
later under that name.
