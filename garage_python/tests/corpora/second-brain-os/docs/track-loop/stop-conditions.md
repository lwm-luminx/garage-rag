# Stop Conditions

The hardest design problem in a loop is not making the agent go; it is making it stop. An agent will happily report success it has not earned, and a loop with no exit is a bill with no ceiling. Every serious loop carries several independent brakes, any one of which ends the run.

## Goal tests

The primary stop is an executable definition of done: a script that exits 0 when the work is acceptable — tests pass, lint is clean, the build compiles. If the goal cannot be written as a script, you do not have a loopable task; you have an interactive session, and that is fine, but stop pretending otherwise. "Improve the code" cannot terminate. "All tests under `tests/` pass and `ruff check .` reports nothing" can. The [goal test build page](build-goal-test.md) turns this into forty lines of bash.

Note what is absent: the agent's own opinion. "The agent said it's done" is never a stop condition — it is the claim the goal test exists to check, a point [critics and verification](critics-and-verification.md) expands.

## Budgets

Goal tests stop successful runs. Budgets stop everything else, and you want at least three, because they fail differently:

- **Iterations** — a hard cap on attempts. Start small; five attempts finds most tractable problems, and problem twenty attempts can solve but five cannot is rare.
- **Tokens or money** — a spend ceiling per run. Headless CLIs report cost per invocation (`--output-format json` includes `total_cost_usd` in Claude Code), so the wrapper can add it up and quit.
- **Wallclock** — a timeout on the whole run and on each attempt. An agent stuck waiting on a hung command burns hours, not tokens.

Budgets are cheap insurance; the only mistake is setting them generously "to give it room". Generous budgets convert bugs into invoices.

## Ratchets

A budget allows ten iterations of slow degradation. A ratchet does not: it requires each iteration to beat the best previous state on a measurable score — tests passing, items ticked off, errors remaining — or the loop resets the attempt and stops. Progress must be monotonic; sideways is failure. This is the backbone of unattended runs, built concretely in [the overnight loop](build-overnight.md).

## Detecting spin

Some failures are loud. Spin is quiet: the agent repeats the same search, produces an empty diff, or hits the same failing test with the same message, attempt after attempt. Detect it by fingerprinting state between iterations — the set of failing test names, a hash of the diff, the last tool commands issued. Two identical fingerprints in a row mean the loop is not converging, and more attempts will only spend the budget. Stop early and say why.

## Handing back to the human

Every exit that is not goal-test-green should end in a report addressed to a person: what was attempted, what state the working tree is in, which brake fired, and the loop's best evidence for why. Escalation is a feature. A loop that fails legibly at attempt three is worth more than one that flails to attempt fifty, because the report tells you whether to fix the goal test, raise the budget, or take the task back into your own hands. The [patterns page](patterns.md) shows how the unattended variants formalise this into a morning report.
