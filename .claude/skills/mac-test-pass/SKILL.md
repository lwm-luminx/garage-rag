---
name: mac-test-pass
description: Run Garage's full test pass on one of Rick's Macs (Bazel suite, XCUITest, model UI tests, store pass) and report results. Use when asked for a "test cycle", "full pass" or to verify a branch on the M4.
---

# Full test pass on a Mac

Runs on the M4 (`rickmark-m4`, `~/Developer/garage`) unless Rick names another Mac. Check `hostname` first.

## Before

1. Work in a worktree for the commit under test, not Rick's main checkout:
   `git fetch origin && git worktree add ~/Developer/garage-<label> <sha-or-branch>`.
   The checkout must be a full clone (the build number is the commit count).
2. Make sure nothing else is testing: `pgrep -lf 'GarageApp|xctest|xcodebuild'`. Only one XCUITest run per Mac.
   Never kill processes by pattern; only PIDs this session started.
3. `garage quit` (quits any running Garage; a UI run refuses to share the Mac with one).
4. Turn off TestFlight auto-update, close Secretive Touch ID windows, and don't drive Chrome during the run.
5. Automation Mode must be on. If XCUITests fail with "Not authorized for performing UI testing actions", Rick runs
   `sudo automationmodetool enable-automationmode-without-authentication` once.
6. Before MCP registration tests, back up `~/.claude.json` and Claude Desktop's `claude_desktop_config.json`.

## Run

1. `aspect test //...` with the default config (`--config=developer_id`/`appstore` cannot run `aspect test`).
2. The UI suites: `GarageAppUITests`, then the model UI tests (`GarageAppModelUITests`, bundled `models.json`).
3. If asked for the store pass: build the store app and set `TEST_RUNNER_GARAGE_UITEST_STORE_APP`; xctrunner needs
   Full Disk Access and "access data from other apps" for the App Group folder.
4. If the run came back clean and Rick asked for it, a store validation (`upload_appstore ... --validate-only`, no upload).

Non-store UI test data folders live in `~/Library/Caches/GarageUITests`.

## After

- Restore the Claude configs if you backed them up.
- Report pass/fail counts per suite, the commit SHA, and each failure with its cause. Rerun a failure once
  before calling it real: notification banners and permission prompts make elements "not hittable".
- A stall with no visible dialog is usually a hidden TCC prompt: ask Rick to look at the screen.
