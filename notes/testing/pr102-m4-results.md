# PR #102 on the M4 (store half)

Heads tested: 5736451 (build), 89265907 (Bazel tests and the full UI suite), 8ca3fe60 (the Database test rerun).

- `aspect build //:macapp --config=appstore` on 5736451 built with no compile errors.
- `aspect test //...` on 89265907: 48/48 pass, and the known_answers error is gone.
- GarageAppUITests on 89265907, full suite, with TEST_RUNNER_GARAGE_UITEST_STORE_APP set (took 36 min): 42 run, 22 passed, 15 failed, and 5 store tests failed in setup.

## Failures (file:line, first line of the error)

| Test | Where | Error |
|---|---|---|
| DatabaseUITests.testPageShowsItsSectionsAndHidesThePassword | DatabaseUITests.swift:71 | Database does not show "Contents". **Fixed on 8ca3fe60 (passes on rerun).** |
| DatabaseResetUITests.testResetHandsOverToTheRelaunchedInstance | DatabaseResetUITests.swift:98 | finishDatabaseReset did not report a new database (then :99 no matching snapshot) |
| StatusUITests.testHealthListsWhatIsMissingAndOpensItsPage | GarageUITestCase.swift:188 | Failed to get matching snapshot: No matches found for first query match sequence |
| StatusUITests.testHelperServicesToolbar | StatusUITests.swift:127 | Helper Services has no status.services.testAll |
| StatusUITests.testIndexingCountsAnEmptyCorpus | StatusUITests.swift:17 | the chunks figure is not 0 on an empty corpus () |
| StatusUITests.testASourceTurnsAddASourceIntoUpdateEverything | StatusUITests.swift:89 | the Sources figure did not count the source |
| ModelsUITests.testOverallShowsEachKindOfModel | ModelsUITests.swift:25 | no facts model does not say so |
| NavigationUITests.testSidebarOpensEveryPage | NavigationUITests.swift:27 | the status page did not show "Helper Services" |
| NavigationUITests.testMainWindowOpensOnStatusWithoutSplashOrSetup | NavigationUITests.swift:74 | the window did not open on Status |
| PagesUITests.testStatusShowsOverviewAndServiceControls | PagesUITests.swift:13 | Status does not show "Helper Services" |
| SourcesUITests.testToolbarOffersCombinedActions | SourcesUITests.swift:43 | no Scan & Ingest All button |
| SourcesUITests.testSyncKeepsConfigAndDatabaseInStep | SourcesUITests.swift:95 | the sync button stayed disabled |
| SourcesUITests.testScanAndIngestIndexesTheFolder | SourcesUITests.swift:125 | the Status page never counted both notes |
| SourcesUITests.testAddingASourceEnablesTheToolbarAndMarksItsCard | SourcesUITests.swift:215 | Update Everything stayed disabled with a source |

Many of these look like tests written against Status and Sources labels that the current page doesn't use: "Helper Services", "Scan & Ingest All", "Update Everything", status.services.testAll. That is an inference; I didn't check the views.

## Store Mail/Messages (5, all failing in setup)

testIndexesAMailFolder, testIndexesAMessagesDatabase, testMailPresetRegistersTheRealMailFolder, testMessagesPresetRegistersTheRealMessagesFolder, testWithoutAFolderGrantMessagesAndMailNeedPermission all fail at GarageUITestCase.swift:0 with NSCocoaErrorDomain 513 "You don't have permission to save the file ... in the folder UITests" (the App Group container, POSIX EPERM). The xctrunner is missing the "access data from other apps" permission. Rick has to grant it at the Mac.

Logs: pr102-ui2.log and pr102-ui2.xcresult in this session's scratchpad on the M4.
