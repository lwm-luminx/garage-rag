# System One Models

Most AI products today are built on large language models: you send text in, the model writes text back, one token at a time. That is slow and expensive when all your software actually needs is a decision. "System One models" are a new category — introduced by TypeSafe AI on 15 September 2026 with a model called Jev — built for exactly that gap: fast typed decisions instead of slow text generation.

## The Kahneman framing

The name borrows from Daniel Kahneman's *Thinking, Fast and Slow*. System 1 is fast, intuitive judgement; System 2 is slow, deliberate reasoning. LLMs, in this framing, are System 2 machines: they reason out loud, in prose. TypeSafe's pitch is that a large share of what software asks a model to do — classify, route, score, gate — is System 1 work, and paying LLM latency and cost for it is waste. Their founder, Diogo Almeida (ex-OpenAI, worked on RLHF and ChatGPT), calls it "a frontier-intelligence function call: unstructured state in, typed probabilistic decisions out".

## What Jev actually returns

Jev is non-autoregressive: it does not generate text at all. You send it a `state` (strings, JSON objects, or arrays of text) plus one or more typed questions, and it answers them all in a single parallel pass. Three primitives:

- `Choice` — pick one of up to 255 defined options, with a probability per option
- `Score` — place the input on an ordered scale of 2–10 levels
- `Noul` — a yes/no judgement returned as a probability between 0 and 1

Every answer carries a calibrated probability. TypeSafe trained this with a method they call RLCD (Reinforcement Learning for Calibrated Decisions), which optimises for honest confidence rather than pleasing a human rater.

## Honest caveats

This launched days ago, and nearly every number is the vendor's own:

- The headline claims — roughly 200x faster and up to 400x cheaper than frontier LLMs — come from benchmarks built by TypeSafe's own team, which the company itself admits sit at the high end.
- "Zero hallucinations" really means zero *out-of-schema* outputs. Jev cannot invent an option you did not define; it can still pick the wrong one.
- Architecture, model size, and weights are undisclosed. No peer-reviewed paper exists yet. Calibration under distribution shift is unproven, as sceptics like Anthony Maio have pointed out.

Treat the mechanism as real and the magnitudes as marketing until independent evaluations land. For what tasks it plausibly fits, see [what Jev is good for](what-jev-is-good-for.md); to try it, see [getting started](getting-started.md); for sources, see [resources](resources.md).
