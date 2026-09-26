# Build: the Goal Test

Three build pages assemble a working loop around a headless coding agent. This one delivers the skeleton: define done as a script, run the agent, run the goal test, feed failures back, cap the attempts. The examples drive Claude Code's non-interactive mode (`claude -p`), the reference harness from [the harness track](../track-harness/claude-code-as-harness.md), but any CLI agent that takes a prompt and edits files will slot in.

You need `claude` and `jq` on your path, and a repo with a test suite. The flags below are current as of September 2026: `-p` runs one non-interactive session, `--allowedTools` pre-approves tools using permission rule syntax (the trailing ` *` is prefix matching), `--permission-mode acceptEdits` lets it write files without prompting, and `--output-format json` returns the result with metadata including `total_cost_usd`.

## Done as a script

The goal test is the whole design. It must be executable, binary, and outside the agent's control — here, tests plus lint:

```bash
#!/usr/bin/env bash
# goal-loop.sh — run a coding agent until the goal test passes or attempts run out.
set -u

TASK="Make every test under tests/ pass. Do not delete, skip or weaken any test."
MAX_ATTEMPTS=5

goal_test() {
    python -m pytest -q --tb=short && ruff check .
}

feedback=""
attempt=1
while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    echo "=== attempt $attempt of $MAX_ATTEMPTS ==="

    prompt="$TASK"
    if [ -n "$feedback" ]; then
        prompt="$TASK

The previous attempt failed the goal test with this output:
$feedback

Fix these specific failures."
    fi

    claude -p "$prompt" \
        --allowedTools "Read,Edit,Bash(python -m pytest *),Bash(ruff *)" \
        --permission-mode acceptEdits \
        --output-format json | jq -r '.total_cost_usd as $c | "agent done (cost $\($c))"'

    if feedback=$(goal_test 2>&1); then
        echo "PASS: goal test green on attempt $attempt"
        exit 0
    fi
    echo "FAIL: goal test still red"
    attempt=$((attempt + 1))
done

echo "STOP: $MAX_ATTEMPTS attempts spent; handing back to the human"
exit 1
```

Save it, `chmod +x goal-loop.sh`, run it in a repo with failing tests, and watch it converge or stop.

## Why each piece is there

**The goal test runs in the wrapper, not the agent.** The agent also runs pytest while working — that is fine, that is how it navigates. But the verdict that ends the loop comes from your shell, in a process the model never touches. This is the "checks, never asks" rule from [critics and verification](critics-and-verification.md) in its smallest form.

**Failure output is the only thing carried forward.** Each attempt is a fresh `claude -p` session: clean context, the task, and the distilled evidence of what is still wrong. No transcript of the previous attempt's confusion travels with it — the fresh-context-per-attempt argument from [context hygiene](context-hygiene.md).

**The cap is small and the exit codes are honest.** Five attempts, then exit 1 with a plain statement. That makes the script composable: CI can gate on it, cron can alert on it, and the next two build pages can wrap it.

## What it is not, yet

This loop accepts anything green. An agent that passes the tests by ugly means — dead code, swallowed errors, a sneaky change just outside the tests' reach — sails through. Part two adds a judge for exactly that: [Build: the critic](build-critic.md).
