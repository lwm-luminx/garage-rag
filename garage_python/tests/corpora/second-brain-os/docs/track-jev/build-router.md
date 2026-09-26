# Build: the Confidence-Gated Router

The [typed decision endpoint](build-decision-endpoint.md) earns its keep in front of an agent. The pattern, described in [Jev in an agent stack](jev-in-an-agent-stack.md): classify the incoming request cheaply, act directly when the classifier is confident, fall through to the full LLM when it is not. The decision head is the fast path, never the only path.

## The design

Three rules do all the work:

- Every route with a deterministic handler can be served without touching the big model.
- The fast path fires only when confidence clears a threshold *and* the route has a handler. Everything else falls through.
- Every decision is logged, routed or not. The log is your future eval set: once you have human labels for these tickets, you can measure the classifier's accuracy, tune the threshold against real error costs, and later compare Jev's answers on identical inputs.

## The code

Runnable as-is with `decision.py` from the previous page in the same directory.

```python
# router.py
import json
import time

import anthropic

from decision import decide

client = anthropic.Anthropic()
FULL_MODEL = "claude-opus-5"   # the fall-through: full-strength, full price
THRESHOLD = 0.8                # start conservative; tune against labels later
LOG_PATH = "decisions.jsonl"

# Routes with a handler get a fast path. "other" is a deliberate catch-all
# with no handler, so anything unfamiliar always falls through.
ROUTES = {
    "billing": lambda t: "Routed to billing queue with a receipt request.",
    "password_reset": lambda t: "Sent the automated password-reset link.",
    "cancellation": lambda t: "Escalated to a human retention agent.",
    "other": None,
}
ROUTE_SCHEMA = {"type": "string", "enum": list(ROUTES)}
QUESTION = "Which route should handle this support ticket?"

def log_decision(entry: dict) -> None:
    with open(LOG_PATH, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry) + "\n")

def fall_through(ticket: str) -> str:
    response = client.messages.create(
        model=FULL_MODEL,
        max_tokens=16000,
        messages=[{"role": "user", "content": f"Handle this support ticket:\n{ticket}"}],
    )
    return next(b.text for b in response.content if b.type == "text")

def handle(ticket: str) -> str:
    start = time.perf_counter()
    decision = decide(ROUTE_SCHEMA, QUESTION, ticket)
    decide_ms = round((time.perf_counter() - start) * 1000)

    handler = ROUTES.get(decision["value"])
    fast = handler is not None and decision["confidence"] >= THRESHOLD
    outcome = handler(ticket) if fast else fall_through(ticket)

    log_decision({
        "ts": time.time(),
        "ticket": ticket,
        "value": decision["value"],
        "confidence": decision["confidence"],
        "threshold": THRESHOLD,
        "path": "fast" if fast else "fall_through",
        "decide_ms": decide_ms,
    })
    return outcome

if __name__ == "__main__":
    print(handle("I was charged twice for the same invoice this month."))
    print(handle("Your app deleted three years of my data and I am furious."))
```

## What to watch

The threshold is a business decision, not a modelling one — price it by the cost of a wrong fast-path action, per the thresholds discussion linked above. With the stand-in, remember the confidence is sample agreement, not a calibrated probability: five agreeing samples on an ambiguous ticket is common, so keep the catch-all route and audit the log weekly against human judgement before lowering the threshold. The one thing not to skip is the logging. When Jev access arrives, this file of inputs, decisions and confidences is exactly what you will replay through it — which is the next page: [the Jev swap](build-swap-in-jev.md).
