# Build: a Typed Decision Endpoint

Jev is waitlisted, so most readers cannot call it yet — access status in [getting started](getting-started.md). What you can build today is the shape it fits into: a function that takes a schema and some state and returns a typed decision with a confidence score. Build that seam now with an ordinary LLM, and the [System One model](system-one-models.md) becomes a drop-in later. This page builds the endpoint; the next wires it into a router.

## The contract

One function, `decide(schema, question, state)`, returning `{"value": ..., "confidence": ...}` where `value` conforms to the schema and `confidence` is between 0 and 1. That mirrors what Jev's primitives give you — a typed answer plus a probability — without pretending to match how it produces them.

## Why self-consistency, not logprobs

Two honest routes to a confidence number from an LLM. Token logprobs would be the direct one, but it is closed today: the Claude API does not expose logprobs at all, and on OpenAI's current models developers report the logprobs array coming back empty whenever structured outputs (`json_schema`) are enabled — the one mode this pattern depends on. The route that works is self-consistency: sample the same question several times, take the majority answer, and use the agreement fraction as confidence. Cruder, but it measures something real — how stable the model's judgement is on your input.

## The code

Constrained output via the Claude API's structured outputs (`output_config`, generally available, no beta header), five parallel samples on the small fast model. Needs `pip install anthropic` and an `ANTHROPIC_API_KEY`.

```python
# decision.py
import json
from collections import Counter
from concurrent.futures import ThreadPoolExecutor

import anthropic  # pip install anthropic

client = anthropic.Anthropic()  # reads ANTHROPIC_API_KEY
MODEL = "claude-haiku-4-5"      # small and fast: this seat is System One work
SAMPLES = 5

def _ask_once(schema: dict, question: str, state: str) -> str:
    response = client.messages.create(
        model=MODEL,
        max_tokens=256,
        temperature=1.0,  # the default, stated on purpose: samples must vary
        messages=[{"role": "user", "content": f"{question}\n\nState:\n{state}"}],
        output_config={
            "format": {
                "type": "json_schema",
                "schema": {
                    "type": "object",
                    "properties": {"value": schema},
                    "required": ["value"],
                    "additionalProperties": False,
                },
            }
        },
    )
    text = next(b.text for b in response.content if b.type == "text")
    return json.dumps(json.loads(text)["value"], sort_keys=True)  # normalise for voting

def decide(schema: dict, question: str, state: str) -> dict:
    with ThreadPoolExecutor(max_workers=SAMPLES) as pool:
        futures = [pool.submit(_ask_once, schema, question, state) for _ in range(SAMPLES)]
        answers = [f.result() for f in futures]
    winner, votes = Counter(answers).most_common(1)[0]
    return {"value": json.loads(winner), "confidence": votes / SAMPLES}

if __name__ == "__main__":
    print(decide(
        schema={"type": "string", "enum": ["billing", "technical", "account", "other"]},
        question="Which team should handle this support ticket?",
        state="My card was charged twice for the same invoice this month.",
    ))
```

## How this differs from a real System One model

Be clear-eyed about the gap. Jev is non-autoregressive and answers a whole battery of questions in one parallel pass; this makes five generation calls per question. Its confidence is a calibrated probability trained with RLCD; ours is a vote count that can only take six values and says nothing about calibration. Latency is a second or two against a claimed 70–500ms, and each decision costs five Haiku calls against $0.042 per million tokens. What survives the swap is the contract — and that is the part your code depends on. Next: [the confidence-gated router](build-router.md).
