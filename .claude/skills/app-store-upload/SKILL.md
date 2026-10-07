---
name: app-store-upload
description: Build, validate and upload Garage to App Store Connect / TestFlight and prepare the submission. Use when asked for a store build, a TestFlight upload, What to Test notes, screenshots or an App Review submission.
---

# App Store build and upload

Runs on the M4, which has the App Store Connect API key and the store profiles. `RELEASING.md` section 3 is the
procedure; this adds what 1.5 taught.

1. Build from the signed release tag, not `main` (the appcast commit moves `main` and the build number is the
   commit count): `git checkout v<ver>`.
2. `aspect run //macapp/package:upload_appstore --bazel-flag=--config=appstore_release -- --validate-only`, then
   the same without `--validate-only`. The store build carries `ExportCompliance.plist`
   (`ITSEncryptionExportComplianceCode`); a build without it must not be attached.
3. In App Store Connect (Claude in Chrome on the M4): add the build to the TestFlight group with "What to Test"
   notes (`notes/release-1.5/1.5-testflight-what-to-test-572.md` is the model). Upload files one at a time;
   multi-file uploads drop.
4. Screenshots come from `StoreScreenshotsUITests` (2880 x 1800, light and dark, sample data).
5. For a submission: attach the build and all tip in-app purchases, update What's New, check App Privacy against
   `docs/support/privacy-policy.md`, and paste the review notes (`notes/release-1.5/1.5-app-review-notes.md`;
   tell Review the tip jar is under Garage > About Garage). Rick submits.
6. When the store version goes live, set `app_store_live: true` in `docs/_config.yml` (a PR to `main`).

Tip product IDs use `garage_rag` (no hyphens allowed): `me.rickmark.garage_rag.tip.*`.
