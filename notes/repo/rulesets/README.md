# Branch rulesets for rickmark/garage-rag (proposal, not applied)

Two rulesets, identical except for merge methods:

| Ruleset | Branches | Merge methods |
|---|---|---|
| main-next.json | main, next | merge commit, squash |
| release-lines.json | v1.5-alpha, v1.5-beta | merge commit only |

Both: block deletion and force-push, require a PR (0 approvals, since Rick
can't approve his own PRs), and require these CI checks (GitHub Actions app,
integration 15368) to pass on the PR head:

python, swiftcheck, format, gazelle, buildifier, lint

- Not "up to date with base" (strict off): with several threads merging in
  parallel, strict forces a base merge and a fresh CI run after every merge.
- Repository admins (Rick) bypass always, so direct pushes of signed merges
  and emergency merges still work. Change bypass_mode to "pull_request" to
  allow bypass only when merging a PR.

Not required, and why:

- macOS build (`test`): path-filtered, so a PR that doesn't touch build inputs
  never reports and a required check would block it forever. It takes 10 to
  20 minutes warm and hours cold, queues without cancelling, and main's last
  push run failed. The M4's notarize_all build stays the release gate.
- Windows build: path-filtered for the same reason.
- python-freethreaded (on some PR branches): 20 minutes, mostly building the venv.
- Known answers: push-only, path-filtered.

To make the macOS build required later, add an always-running gate job that
reports success when the path filter would skip it.

## Apply (after Rick says yes)

    gh api -X POST repos/rickmark/garage-rag/rulesets --input main-next.json
    gh api -X POST repos/rickmark/garage-rag/rulesets --input release-lines.json

Check: gh api repos/rickmark/garage-rag/rulesets
