# Python 3.14 beta (PR #137, head ee6c8f5) on the M4

**Result: pass.** Nothing to fix from this machine.

## MODULE.bazel.lock
`bazel mod deps --lockfile_mode=update` exited 0 and left `MODULE.bazel.lock` unchanged. The
full `aspect test //...` and `aspect build //:macapp` below didn't change it either, so there is
no lockfile patch to commit. The only notable output was a warning that already applies on
v1.5-alpha: the root module asks for rules_swift 3.6.1 and resolves 4.0.1.

## aspect test //...
Exit 0. Executed 50 of 52 tests (2 cached): **52 of 52 pass.**

## Python.framework
In the `aspect build //:macapp` output,
`Garage.app/Contents/Frameworks/Python.framework/Versions/` holds only `3.14`, and `Current` points
to `3.14`. The `Python` binary identifies itself as `3.14.7`.

## Launch, ingest and search
These ran as the app's own UI tests against the app built from this branch, each launching Garage
on a scratch data folder:
- `SourcesUITests/testScanAndIngestIndexesTheFolder`: passed. It adds a folder, scans it and ingests it.
- `DocumentsUITests/testListShowsTheIngestedCorpus`: passed. The Documents list shows the ingested corpus.
- `GarageAppModelUITests/ModelUITests/testEmbedAllThenSearchFindsEachFileByItsToken`: passed. It
  embeds everything, then searches and finds every file by its token.
