# Build: Read Your Traces

First of three build pages: this one gets you from "the bot sometimes messes up" to a golden set file on disk. [Build the suite](build-suite.md) makes it runnable; the gate page wires it into CI. An afternoon covers all three. Background, if you skipped it: [why evals](why-evals.md).

## Collect 30 traces

Pull thirty real transcripts from production — logs, a database export, whatever exists. Real inputs beat invented ones every time. No traffic yet? Generate a starter set against your own app: write thirty questions a plausible user would ask into `starter_inputs.txt` (vary persona, phrasing, length; include a couple that should be refused), then run them through your actual entry point:

```python
import json

from app import answer  # your product's entry point: str -> str

with open("starter_inputs.txt", encoding="utf-8") as f:
    inputs = [line.strip() for line in f if line.strip()]

with open("traces.jsonl", "w", encoding="utf-8") as out:
    for text in inputs:
        out.write(json.dumps({"input": text, "output": answer(text)}) + "\n")
```

## The error-analysis pass

Read every trace in order and write one line per trace in a plain text file. A format that works:

```
trace_id | verdict | one-sentence failure note | verbatim quote
014 | fail | invented an order number not present in context | "your order #88412 shipped"
015 | ok   |  |
016 | fail | apologised and asked a question instead of acting | "could you clarify which invoice"
```

Four rules: one sentence per failure; always quote the output; log successes as `ok` so you know the denominator; and fix nothing until all thirty are read. The hour this takes is the highest-leverage hour of the whole build.

## Cluster into a taxonomy

At thirty notes you can cluster by hand, but an LLM makes a decent first sorter. Paste your notes into this prompt:

```text
Below are failure notes from an error-analysis pass over one AI product,
one note per line, prefixed with a trace id.

Cluster them into 3 to 8 failure modes. For each mode give:
- a snake_case name
- a one-sentence definition
- the trace ids it covers

Every note must land in exactly one mode. Put genuine one-offs in a mode
called "other" rather than inventing a mode for a single note. Do not
propose fixes. Return a markdown list.

<notes>
PASTE YOUR NOTES HERE
</notes>
```

Treat the result as a draft: merge modes that are really one thing, rename anything vague, demote anything you disagree with. The model sorts; you own the taxonomy.

## Write the golden set

Turn the taxonomy into `golden.jsonl`, one case per line:

```json
{"id": "hallucinated_id_003", "failure_mode": "hallucinated_order_id", "input": "where is my order?", "checks": {"must_not_contain": ["#"]}, "judge_expectation": null, "source": "trace 014"}
{"id": "clarify_loop_001", "failure_mode": "clarify_instead_of_acting", "input": "cancel my March invoice", "checks": null, "judge_expectation": "The reply cancels or begins cancelling the invoice rather than asking a clarifying question.", "source": "trace 016"}
{"id": "happy_path_002", "failure_mode": "none", "input": "what is your refund window?", "checks": {"must_contain": ["30 days"]}, "judge_expectation": null, "source": "trace 015"}
```

Five fields. `id` is stable and greppable. `failure_mode` comes from the taxonomy (`none` for happy-path cases). `input` is what the product receives. Exactly one of `checks` (string assertions code can grade: `must_contain`, `must_not_contain`) or `judge_expectation` (a single sentence the judge verifies) is set — prefer `checks` wherever it can carry the case. `source` points back to the trace, because you will want the original when a case starts failing.

Every named failure mode gets a handful of cases, plus boring successes so you do not over-fit to pathology — the reasoning is in [designing evals](designing-evals.md). Commit the file next to your code and move on to the suite.
