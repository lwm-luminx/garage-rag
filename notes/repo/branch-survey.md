# garage-rag branch survey (2026-09-25, against origin/main 2d2818c9)

I checked each branch three ways: `git cherry` (does main already have a patch-equal commit), a subject match against main's log, and the branch's PR on GitHub. Branch-merge conflicts were not used as evidence. Main's history was rewritten when commits were re-signed, so even fully merged branches show conflicts.

## Open PRs

| PR | Branch | Behind main | Rebase? |
|---|---|---|---|
| #88 Location card badges | claude/location-cards-layout-02fswj | 0 | No |
| #81 Menu bar redesign | claude/toolbar-ui-9ttr4f | 0 | No (the M4's local copy is 5 commits behind the remote) |
| #80 No document for empty files | claude/project-thread-0knonc | 0 | No |
| #82 Index Apple Mail | claude/store-mail-sms-uitests-if1dfo | 2 | Optional, merges cleanly |
| #87 Load llama_xpc models on demand | claude/llama-load-on-demand | 8 | **Yes, 3 conflicts** |

## Remote branches with no PR (unmerged work)

| Branch | State | Suggestion |
|---|---|---|
| origin/claude/first-run-window-size | 2 commits, applies cleanly to main | Open a PR, or drop it |
| origin/claude/first-run-no-flash | Its one commit is also the first commit of first-run-window-size | Delete (superseded) |
| origin/claude/ingest-no-text-git-sms | Its commit is also the first commit of #80 | Delete (superseded by #80) |
| origin/claude/langextract-prompts | 2 commits (configurable fact prompts, migration 012), conflicts | Your call: rebase and open a PR, or drop it |
| origin/claude/sms-ingestion | 2 commits, conflicts. Looks like the earlier attempt that #79 replaced, but "Keep unchanged chunks and their vectors when a document is replaced" is not on main | Your call |

## Local branches already on main (safe to delete)

- `main`: all 8 commits are on origin/main under new hashes; the tree is identical to ade8935d. Reset it with `git checkout -B main origin/main`.
- alpha ("App store fixes", both commits on main)
- claude/adoring-ritchie-c084cj (#15), claude/app-group-data (landed in #15 and later work), claude/reset-xcuitest (#38)
- claude/bundle-hygiene (its OpenSSL commit landed in #43), claude/ui-sources-window (#43)
- claude/eager-davinci-tjf4st (#5), claude/festive-fermi-d9gujl (#6), claude/jolly-gates-nu3gjl (#2), claude/intelligent-gauss-7wk7mc (#4)
- claude/fix-main-after-13 (#41), claude/m4-maintenance-source-add (#71), claude/nonblocking-scan (#54/#56/#58)
- claude/project-thread-82ssh4 (#73), claude/facts-browser-nlgqoq, claude/store-sandbox-python (#37), store-sandbox-check
- claude/serene-meitner-s8pl0z (#12). Its one extra commit, "Update GarageStore App Store provisioning profile", has been superseded by the later profile work.
- claude/sleepy-knuth-wuzdfo (#7, then replaced by #12)
- claude/store-mail-sms-uitests-if1dfo (local copy is contained in main; the remote carries open PR #82)

## Local branches with work that never landed

- **claude/m4-validation-notes**: 17 commits of M4 validation reports (about 2,500 lines of docs). PR #40 was closed without merging. Keep them if you want the notes, otherwise delete.
- **xpc_ingest**: from 2026-09-07, five "remove cli" commits. Superseded by the launcher helpers and the ingest XPC service. Delete.

## Worktrees on the M4

garage-hygiene (bundle-hygiene), garage-m4-notes (m4-validation-notes), garage-reset-uitest (reset-xcuitest), garage-toolbar-ui (toolbar-ui), and three detached ones: garage-merge-check, garage-sandbox, garage-validate. garage-validate is marked prunable because its folder is gone. Remove a branch's worktree before deleting the branch.
