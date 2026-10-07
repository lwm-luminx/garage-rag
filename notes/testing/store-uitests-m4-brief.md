# M4 brief: store build Mail/Messages UI tests

From the "Store UI tests for Mail and Messages" thread. Rick asked for this to resume on the new M4. Queue it after the rebases already in progress.

Goal: run the App Store build's Mail/Messages UI tests. They check whether the sandboxed store build can register and index ~/Library/Mail and ~/Library/Messages.

1. Start on main (#77 merged, so the tests are there). For the Mail indexing test, also merge in the branch claude/store-mail-sms-uitests-if1dfo (PR #82, the .emlx extractor). For the Messages indexing test, merge in #79 as well if it hasn't merged yet. Don't push the merge; it is for the local test run only.
2. Run `aspect build //macapp:GarageStore.app`, then unzip the GarageApp.zip it produces to get Garage.app, for example at /tmp/garage-store/Garage.app.
3. Run `aspect run //:xcodeproj`, then run xcodebuild test on the UI test scheme with `-only-testing:GarageAppUITests/StoreMailMessagesUITests`. Pass `TEST_RUNNER_GARAGE_UITEST_STORE_APP=/tmp/garage-store/Garage.app` in the environment. The tests skip when that variable is unset, or when the bundle lacks the app-sandbox entitlement.
4. Also run the GarageAppGroupTests unit tests, which cover the UITests data-root guard.

Automation Mode is still off on the M4. If xcodebuild stops on the authentication prompt, say so and wait for Rick; don't try to work around it.

Report back with pass, fail or skip for each of these five tests, plus the failure message and screenshot path for any failure:
- testMessagesPresetRegistersTheRealMessagesFolder
- testMailPresetRegistersTheRealMailFolder
- testWithoutAFolderGrantMessagesAndMailNeedPermission
- testIndexesAMessagesDatabase
- testIndexesAMailFolder

What might fail: in the store build, the preset roots `~/Library/Messages` and `~/Library/Mail` may resolve to the sandbox container instead of the real home folder, both in Swift (expandingTildeInPath) and in Python (expanduser). If they do, the two "RegistersTheReal…" tests will show the container path.
