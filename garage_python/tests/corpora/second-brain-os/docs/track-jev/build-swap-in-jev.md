# Build: the Jev Swap

The point of the last two pages was to make this one boring. The [decision endpoint](build-decision-endpoint.md) and the [router](build-router.md) agree on one contract — `decide(schema, question, state)` returning a value and a confidence — so replacing the LLM stand-in with Jev should be a one-file change, not a rewrite. Whether you can make the change yet depends on the waitlist; current access status in [getting started](getting-started.md).

## The seam

Give the router a single import point that names no implementation. This file is the only one that ever changes:

```python
# decider.py — the seam. Swapping implementations is an edit here, nowhere else.
from decision import decide  # today: the LLM stand-in

# from jev_decider import decide  # later: Jev, once access arrives
```

Change `router.py` to `from decider import decide` and the swap is staged. The Jev side maps schema shapes onto its primitives — enums become a `Choice`, booleans a `Noul`, and anything open-ended is refused, because Jev only answers bounded questions:

```python
# jev_decider.py — written from TypeSafe's published docs, UNTESTED until you
# have quota. Verify call shapes against docs.typesafe.ai before relying on it.
from typesafe import TypeSafe, Choice, Noul  # pip install typesafe-sdk

client = TypeSafe()  # reads TYPESAFE_API_KEY

def decide(schema: dict, question: str, state: str) -> dict:
    if "enum" in schema:
        q = Choice(instructions=question,
                   criteria={str(o): str(o) for o in schema["enum"]})
    elif schema.get("type") == "boolean":
        q = Noul(instructions=question)
    else:
        raise ValueError("Jev answers bounded questions only; keep this on the LLM.")
    answer = client.decide(state=state, questions={"value": q})["value"]
    return {"value": answer.value, "confidence": answer.probability}
```

## Shadow mode first

Do not flip the import on day one. Run Jev in shadow: the stand-in still answers every request, Jev answers the same request on the side, and both go in the log. Jev failures cannot hurt production because nothing reads its answer yet.

```python
# shadow.py — point the seam here during the trial period.
import json
import time

import decision as standin
import jev_decider as jev

LOG_PATH = "shadow.jsonl"

def decide(schema: dict, question: str, state: str) -> dict:
    t0 = time.perf_counter()
    live = standin.decide(schema, question, state)
    live_ms = round((time.perf_counter() - t0) * 1000)
    try:
        t1 = time.perf_counter()
        shadow = jev.decide(schema, question, state)
        shadow_ms = round((time.perf_counter() - t1) * 1000)
    except Exception as exc:
        shadow, shadow_ms = {"error": str(exc)}, None
    with open(LOG_PATH, "a", encoding="utf-8") as f:
        f.write(json.dumps({"ts": time.time(), "state": state,
                            "live": live, "live_ms": live_ms,
                            "shadow": shadow, "shadow_ms": shadow_ms}) + "\n")
    return live  # callers only ever see the stand-in
```

## What to measure before flipping

Baseline the stand-in for a week, then compare on the shadow log:

- **Latency.** p50 and p95 of `live_ms` against `shadow_ms`, measured from your infrastructure — not TypeSafe's 70–500ms claim.
- **Cost.** Five Haiku calls per decision against Jev's metered input tokens, per thousand decisions.
- **Agreement rate.** How often the two `value`s match. High agreement plus better latency is the green light; low agreement means someone is wrong, and only labels say who.
- **Calibration.** Bucket Jev's probabilities and check accuracy per bucket against your labels — the vendor's central claim, tested on your traffic.

Flip the import in `decider.py` when the numbers earn it, and keep the stand-in one comment away as the rollback.
