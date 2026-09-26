# Build: the Suite

You have `golden.jsonl` from [read your traces](build-traces.md). This page turns it into a runnable suite: one plain Python file, no framework. Code assertions grade everything they can; one narrow judge handles the rest, per [llm as judge](llm-as-judge.md). The example target is a support assistant behind a single prompt — swap `run_target` for however your app is called.

## The script

Save as `eval_suite.py`. Needs `pip install anthropic` and `ANTHROPIC_API_KEY` set. The judge is a different model to the target, deliberately.

```python
import argparse
import json
import re
import sys

import anthropic

client = anthropic.Anthropic()

TARGET_MODEL = "claude-opus-5"
JUDGE_MODEL = "claude-sonnet-5"

SYSTEM_PROMPT = (
    "You are the support assistant for Acme Invoicing. Answer only from the "
    "provided account context. If the context does not contain the answer, say so."
)

JUDGE_PROMPT = """You are grading one output from an invoicing assistant.

Statement to verify:
{expectation}

Assistant output:
<output>
{output}
</output>

First write one or two sentences of reasoning. Then, on the final line, write
exactly VERDICT: pass if the statement is true of the output, or VERDICT: fail
if it is not. Do not reward length, politeness, or effort.
"""


def run_target(case: dict) -> str:
    response = client.messages.create(
        model=TARGET_MODEL,
        max_tokens=16000,
        system=SYSTEM_PROMPT,
        messages=[{"role": "user", "content": case["input"]}],
    )
    return "".join(b.text for b in response.content if b.type == "text")


def grade_code(output: str, checks: dict) -> tuple[bool, str]:
    for needle in checks.get("must_contain", []):
        if needle.lower() not in output.lower():
            return False, f"missing required text: {needle!r}"
    for needle in checks.get("must_not_contain", []):
        if needle.lower() in output.lower():
            return False, f"contains forbidden text: {needle!r}"
    return True, "code checks passed"


def grade_judge(output: str, expectation: str) -> tuple[bool, str]:
    response = client.messages.create(
        model=JUDGE_MODEL,
        max_tokens=1024,
        messages=[{
            "role": "user",
            "content": JUDGE_PROMPT.format(expectation=expectation, output=output),
        }],
    )
    text = "".join(b.text for b in response.content if b.type == "text")
    match = re.search(r"VERDICT:\s*(pass|fail)", text, re.IGNORECASE)
    passed = bool(match) and match.group(1).lower() == "pass"
    return passed, text.strip().splitlines()[0]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("golden", help="path to golden.jsonl")
    parser.add_argument("--limit", type=int, default=0, help="run only the first N cases")
    parser.add_argument("--threshold", type=float, default=0.0, help="exit 1 below this pass rate")
    args = parser.parse_args()

    with open(args.golden, encoding="utf-8") as f:
        cases = [json.loads(line) for line in f if line.strip()]
    if args.limit:
        cases = cases[: args.limit]

    results = []
    for case in cases:
        output = run_target(case)
        if case.get("checks"):
            passed, reason = grade_code(output, case["checks"])
        else:
            passed, reason = grade_judge(output, case["judge_expectation"])
        results.append({"id": case["id"], "passed": passed, "reason": reason})
        print(f"{'PASS' if passed else 'FAIL'}  {case['id']}  {reason}")

    rate = sum(r["passed"] for r in results) / len(results)
    print(f"\npass rate: {rate:.0%}")
    with open("results.json", "w", encoding="utf-8") as f:
        json.dump({"pass_rate": rate, "results": results}, f, indent=2)
    if args.threshold and rate < args.threshold:
        sys.exit(1)


if __name__ == "__main__":
    main()
```

Run it with `python eval_suite.py golden.jsonl`. It prints one line per case, writes `results.json`, and — with `--threshold` — exits non-zero on a bad run, which is all CI needs.

## Calibrate the judge before trusting it

Hand-label ten judged outputs first: `labels.jsonl`, one line per output with `id`, `output`, `expectation`, and your own `label` (true/false). Then check agreement:

```python
import json

from eval_suite import grade_judge

with open("labels.jsonl", encoding="utf-8") as f:
    labels = [json.loads(line) for line in f if line.strip()]

agree = 0
for row in labels:
    verdict, reason = grade_judge(row["output"], row["expectation"])
    agree += verdict == row["label"]
    if verdict != row["label"]:
        print(f"disagree on {row['id']}: judge={verdict} you={row['label']} - {reason}")
print(f"agreement: {agree}/{len(labels)}")
```

Read every disagreement; usually the expectation sentence was woolly, sometimes your label was. Ten labels is the afternoon version — the full 50–100 label procedure is in [llm as judge](llm-as-judge.md).

## When a framework earns its keep

This file is enough for one target, one judge, and a few hundred cases. Reach for promptfoo when you want to compare several prompts or models side by side without writing the matrix yourself, and for Inspect when you need sandboxed agent environments, solvers, and per-step scoring. Both are surveyed in [tooling](tooling.md); neither replaces the taxonomy work — they just run it at scale.
