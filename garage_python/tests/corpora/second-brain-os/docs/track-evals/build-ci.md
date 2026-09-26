# Build: the Gate

A suite that runs only when someone remembers is a suite that stops running. This page wires `eval_suite.py` from [build the suite](build-suite.md) into GitHub Actions: a subset gates every PR, the full suite runs nightly, and the number lands in a scoreboard committed to the repo. The principles are in the CI section of [agent evals](agent-evals.md).

## The workflow

Save as `.github/workflows/evals.yml`. Add `ANTHROPIC_API_KEY` under repository secrets first.

```yaml
name: evals

on:
  pull_request:
  schedule:
    - cron: "30 2 * * *"

permissions:
  contents: write

concurrency:
  group: evals-${{ github.ref }}
  cancel-in-progress: true

env:
  ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}

jobs:
  pr-gate:
    if: github.event_name == 'pull_request'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: actions/setup-python@v6
        with:
          python-version: "3.12"
      - run: pip install anthropic
      - name: Run the smoke subset
        run: python eval_suite.py golden.jsonl --limit 20 --threshold 0.85

  nightly:
    if: github.event_name == 'schedule'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: actions/setup-python@v6
        with:
          python-version: "3.12"
      - run: pip install anthropic
      - name: Run the full suite
        run: python eval_suite.py golden.jsonl --threshold 0.85
      - name: Append to the scoreboard
        if: always()
        run: |
          rate=$(python -c "import json; print(f\"{json.load(open('results.json'))['pass_rate']:.0%}\")")
          echo "| $(date -u +%Y-%m-%d) | ${rate} | ${GITHUB_SHA::7} |" >> scoreboard.md
          git config user.name "eval-bot"
          git config user.email "actions@users.noreply.github.com"
          git add scoreboard.md
          git commit -m "scoreboard: nightly eval run"
          git push
```

## Choosing the threshold

Set the threshold below your current pass rate, not at it. Judged cases are stochastic: a suite sitting at 90% will occasionally print 87% with nothing changed, and a gate at 90% turns that noise into red builds nobody trusts. Run the full suite three times, take the worst number, and gate a couple of points under that. Raise the bar only after a real improvement holds for a week of nightlies. And pin your model IDs in the script — a model alias silently moving underneath you is a change, and it should arrive as a PR that faces the gate like any other.

## Cost control

The PR job runs the first twenty cases; keep those the cheapest and most diagnostic ones — code-graded cases from your biggest failure modes, since ordering `golden.jsonl` is free and judge calls are the expensive part. Twenty cases at two calls each is small money per PR; the full suite with every judge case runs once a night regardless of how busy the repo is. `cancel-in-progress` stops force-pushes from stacking duplicate runs. If nightly spend still stings, that is a sign the suite has grown past the afternoon version, and the sample-size guidance in [designing evals](designing-evals.md) tells you which cases are earning their place.

## The scoreboard

Seed `scoreboard.md` by hand:

```markdown
# Eval scoreboard

| date | pass rate | commit |
|---|---|---|
```

The nightly job appends one row and commits it, even on failing runs — a bad number in the log is a fact, a missing row is a mystery. The point of the scoreboard is not the ceremony; it is that the number becomes visible history in every clone of the repo. When it dips, `git log scoreboard.md` and the nightly logs say exactly which day and which commit. That loop — read traces, encode failures, gate, watch the number — is the flywheel from [why evals](why-evals.md), now running without you.
