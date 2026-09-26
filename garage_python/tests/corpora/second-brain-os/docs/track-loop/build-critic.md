# Build: the Critic

[Part one](build-goal-test.md) stops on green. This part adds the second judgement: green and clean. A separate critic pass reviews the diff against a narrow rubric, and its defects — not vague advice — feed the next attempt. The theory is in [critics and verification](critics-and-verification.md); this is the forty extra lines.

Two design rules carry the whole thing. The critic is a **separate session**: a fresh `claude -p` call that sees only the diff and the rubric, never the working transcript, so it cannot inherit the maker's rationalisations. And the rubric is **narrow and checkable**: four rules, a demanded verdict format, and an explicit ban on commenting about anything else.

## The code

```bash
#!/usr/bin/env bash
# critic-loop.sh — the goal test decides correct; a critic pass decides acceptable.
set -u

TASK="Make every test under tests/ pass. Do not delete, skip or weaken any test."
MAX_ATTEMPTS=5
BASE_REF=$(git rev-parse HEAD)

goal_test() {
    python -m pytest -q --tb=short && ruff check .
}

critic() {
    git diff "$BASE_REF" | claude -p \
"You are a code reviewer. Judge this diff against exactly four rules:
1. No test was deleted, skipped or weakened.
2. No debug prints, dead code or commented-out blocks were added.
3. Errors are handled, not silently swallowed.
4. The change stays inside the task; no drive-by refactoring.
If all four hold, reply with the single word PASS.
Otherwise list each violation as: file, the problem, the one-line fix.
Judge only these rules. Never comment on style or architecture." \
        --output-format json | jq -r '.result'
}

feedback=""
for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
    echo "=== attempt $attempt of $MAX_ATTEMPTS ==="

    prompt="$TASK"
    if [ -n "$feedback" ]; then
        prompt="$TASK

The previous attempt was rejected:
$feedback

Fix exactly these points, nothing else."
    fi

    claude -p "$prompt" \
        --allowedTools "Read,Edit,Bash(python -m pytest *),Bash(ruff *)" \
        --permission-mode acceptEdits > /dev/null

    if ! feedback=$(goal_test 2>&1); then
        echo "goal test red; retrying with failures"
        continue
    fi

    verdict=$(critic)
    case "$verdict" in
        PASS*)
            echo "green and clean on attempt $attempt"
            exit 0
            ;;
        *)
            feedback="The goal test passes, but the reviewer found defects:
$verdict"
            echo "critic rejected; retrying with defects"
            ;;
    esac
done

echo "STOP: $MAX_ATTEMPTS attempts spent; handing back to the human"
exit 1
```

## How the pieces fit

The order matters: goal test first, critic second. There is no point paying for a review of code that does not work, so the deterministic critic screens for the LLM critic — cheap judges before expensive ones. The diff is taken against `BASE_REF`, pinned before the loop starts, so the critic always reviews the total change rather than the last increment.

Notice what the critic's output becomes: the next attempt's `feedback`, phrased as "fix exactly these points, nothing else". Actionable defects with locations convert directly into a bounded task. That is why the rubric bans style commentary — a critic that says "consider a more functional approach" sends the next attempt on a refactoring holiday, and your five attempts evaporate into churn.

The critic still shares failure modes with any LLM judge — leniency, self-preference when maker and checker share a model. Rule one of the rubric is also enforced by nothing but the critic here; a stricter build would deny the agent write access to `tests/` outright. Both rails, plus running the whole thing unattended, are [part three](build-overnight.md).
