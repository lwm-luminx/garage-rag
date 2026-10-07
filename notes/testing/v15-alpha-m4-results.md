# v1.5-alpha on the M4 (1b4adf8 plus the ModelsView AnyView fix, now PR #111)

- `aspect build //:macapp`: builds.
- `aspect test //...`: 50/50 pass.
- GarageAppUITests (Developer ID, store tests skipped): 53 run, 46 passed, 7 failed (8 failure lines: the reset test fails twice), 47.1 min (17:46 to 18:34).
- GarageAppModelUITests: 3 run, 1 passed, 2 failed, 4.8 min.
- Nothing was left running afterwards: no Garage, and port 14824 is free.

## GarageAppUITests failures

| Test | Where | First error line |
|---|---|---|
| DatabaseResetUITests.testResetHandsOverToTheRelaunchedInstance | DatabaseResetUITests.swift:98 | finishDatabaseReset did not report a new database |
| LogsUITests.testIngestFillsTheIngestSource | LogsUITests.swift:146 | no line under Ingest names the source uitest-logs-b314337f (visible: 15, total: 2735) |
| LogsUITests.testTableFillsAndTheTextFilterNarrowsIt | LogsUITests.swift:75 | XCTUnwrap failed: the table shows no rows. The 30s main-thread hang is gone. |
| SetupAssistantUITests.testSkipOpensTheMainWindow | SetupAssistantUITests.swift:113 | no main window after the assistant |
| SetupAssistantUITests.testWalkingEveryPageToFinishOpensTheMainWindow | SetupAssistantUITests.swift:72 | the assistant did not move on to the models page |
| SourcesUITests.testAddingASourceEnablesTheToolbarAndMarksItsCard | SourcesUITests.swift:215 | the Documents card does not say it is added (no card) |
| SourcesUITests.testStopEndsARunningScanAndIngest | GarageUITestCase.swift:225 | no element "sources.cancelAll" |

## Setup assistant: the likely cause

The UI tree captured at the failure (setup-walk-hierarchy.txt and setup-skip-hierarchy.txt) shows the setup assistant's footer drawn outside its own window:

- Window (Main) 'garage.main-AppWindow-1': frame {{58, 91}, {900, 572}}, so its bottom edge is at y = 663.
- The firstRun.root group is {{48, 68}, {920, 650}}. It is larger than the window and bottoms out at y = 718.
- The footer controls sit below the window's bottom edge:
  - firstRun.skipSetup is at y = 679.5.
  - firstRun.decideLater and firstRun.next ("Add 1 source & Next") are at y = 674.

So Next and Skip are clipped and can't be clicked. That matches both failures: the walk never reaches the models page, and Skip never opens the main window. The window is also reported Disabled. The setup assistant's content wants 920×650, but the window is 900×572.

The failure recordings show only the desktop (IntelliJ in front), so they add nothing. The UI trees are the evidence.

## GarageAppModelUITests failures (possibly a #107 regression)

| Test | Where | First error line |
|---|---|---|
| ModelUITests.testEmbedAllThenSearchFindsEachFileByItsToken | ModelUITests.swift:152 | the provider picker offers no Llama XPC |
| ModelUITests.testTryItAnswersFromTheCorpus | ModelUITests.swift:275 | the provider picker offers no Llama XPC |

Both passed their provider step on 8261b7e, before #107's llama endpoint broker. On v1.5-alpha the Models provider picker no longer lists Llama XPC. The broker change is the prime suspect. Glean Facts passed.
