# Releasing Garage

The macOS app's releases, Developer ID (notarized, Sparkle) and App Store, are cut from
[garage-enterprise](https://github.com/lwm-luminx/garage-enterprise), which carries this repository as a
submodule and holds the signing identities, the provisioning profiles and the release targets
(`docs/RELEASING.md` there). This repository builds the app ad hoc or with a local identity only; the
seam the signed builds plug into is `bazel/platforms.bzl`.

What a release still needs from here, before the cut:

- [ ] Everything meant for the release is merged into `main`, and CI is green there, including
      `.github/workflows/macos.yaml` (`aspect test //...` on macOS).
- [ ] Bump `short_version_string` in `macapp/Sources/GarageApp/BUILD.bazel` and `VERSION` in
      `rust/garage-service/src/service.rs` (the version `garage version`, the backend and the Windows
      installers report).
- [ ] Regenerate `data/notices/THIRD_PARTY_NOTICES.txt` (`python3 tools/third_party_notices.py`) if dependencies or anything under `ext/` changed.
- [ ] After a Developer ID release, commit the entry garage-enterprise's appcast step wrote to `docs/appcast.xml`
      (the feed is served from this repository's site).

## The Python package

`garage-rag` on PyPI was reserved for the Python package but never published, and the package is
gone (`docs/plans/python-removal.md`): the command line is `rust/garage-cli`, shipped in the Mac
app and the Windows installers. A thin Python wrapper with the same `garage` commands may come back
later under that name.
