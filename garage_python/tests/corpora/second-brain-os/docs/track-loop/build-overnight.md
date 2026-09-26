# Build: the Overnight Loop

The final build runs unattended. Everything from [parts one and two](build-goal-test.md) still applies; what changes is that nobody is watching, so the rails must make the worst case boring: a budget on iterations, a ratchet that stops the run the moment progress stalls, a morning report in markdown, and git as the safety net — own branch, hard reset on regression, and nothing is ever pushed.

The ratchet is the heart. Each iteration must beat the best previous score — here, tests passing — or the loop resets the attempt and stops. Monotonic or nothing; a loop allowed to move sideways all night will. The reasoning is in [stop conditions](stop-conditions.md).

## The code

```python
#!/usr/bin/env python3
"""overnight.py — unattended agent loop: budgeted, ratcheted, reported."""
import datetime
import json
import pathlib
import re
import subprocess

TASK = ("Open TODO.md. Implement the top unchecked item, add tests for it, "
        "and tick the item off. Do not delete, skip or weaken any existing test.")
MAX_ITERATIONS = 10
RATCHET = pathlib.Path("ratchet.json")
REPORT = pathlib.Path("MORNING-REPORT.md")


def sh(cmd, timeout=2400):
    return subprocess.run(cmd, shell=True, capture_output=True, text=True,
                          timeout=timeout)


def score():
    """Progress metric: tests passing. Higher is better; it must never fall."""
    out = sh("python -m pytest -q --tb=no").stdout
    m = re.search(r"(\d+) passed", out)
    return int(m.group(1)) if m else 0


def main():
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M")
    sh(f"git checkout -b overnight/{stamp}")  # rail 1: own branch, never pushed
    best = score()
    RATCHET.write_text(json.dumps({"best": best}))
    lines = [f"# Overnight report {stamp}", "",
             f"Baseline: {best} tests passing.", ""]

    for i in range(1, MAX_ITERATIONS + 1):
        sh('claude -p "{}" '
           '--allowedTools "Read,Edit,Bash(python -m pytest *)" '
           '--permission-mode acceptEdits '
           '--permission-prompts none'.format(TASK))
        now = score()
        if now > best:
            best = now
            RATCHET.write_text(json.dumps({"best": best}))
            sh(f'git add -A && git commit -m "overnight {i}: {now} passing"')
            lines.append(f"- iteration {i}: improved to {now} passing, committed")
        else:
            sh("git reset --hard")            # rail 2: a bad attempt never survives
            lines.append(f"- iteration {i}: {now} passing, no improvement; stopped")
            break
    else:
        lines.append(f"- iteration budget of {MAX_ITERATIONS} spent")

    lines += ["", f"Final: {best} passing on branch overnight/{stamp}. "
                  "Nothing was pushed; review and merge by hand."]
    REPORT.write_text("\n".join(lines) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
```

Run `python overnight.py` before bed; read `MORNING-REPORT.md` with coffee.

## The rails, spelled out

**Branch, commit, never push.** Every improvement is committed on `overnight/<stamp>`, so the morning decision is a normal code review of a normal branch. The script contains no push and the agent has no git permissions at all — its `--allowedTools` covers reading, editing and pytest, nothing else. `--permission-prompts none` tells the harness nobody is available: anything that would prompt is denied rather than left hanging until dawn.

**Reset on regression.** When the score fails to improve, `git reset --hard` discards the attempt before stopping. Combined with the ratchet, the invariant is strong: the branch only ever contains states measurably better than the last, which is what lets you trust the report without rereading every diff.

**The report is the mailbox.** Unattended loops make unattended mistakes; the report is where they surface, per iteration, with the brake that fired. Between iterations, only `TODO.md` and the ratchet file persist — deliberately, per [context hygiene](context-hygiene.md). Each session wakes up cold, reads the todo, and does one bounded thing.
