# Getting Started With Jev

Jev has been publicly documented for about a week. This page reflects what is published as of 21 September 2026; expect it to date quickly.

## Access

Jev is in waitlisted early access. You sign up at [console.typesafe.ai](https://console.typesafe.ai/), and TypeSafe says it is admitting developers off the waitlist in batches. API keys live at `console.typesafe.ai/settings/keys`; some gateways (Vercel AI Gateway, Netlify, Cloudflare) also proxy it. There is a free playground on the console for poking at it before you have quota.

## The API shape

The entire API is one endpoint — `POST https://api.typesafe.ai/v1/systemone` — with the default model `jev-latest` (currently `jev-1.13.0`). Official SDKs: `pip install typesafe-sdk` and `npm install @typesafe-ai/sdk`, both reading `TYPESAFE_API_KEY` from the environment.

A request is a `state` (string, JSON object, or array of text — text only for now) plus named questions using three primitives:

```python
from typesafe import Choice, Score, Noul

questions = {
    "team": Choice(instructions="Which team should handle this",
                   criteria={"billing": "Payment issues", "technical": "Bugs"}),
    "frustration": Score(instructions="Customer frustration level",
                         criteria=["Calm", "Frustrated but civil", "Very angry"]),
    "refund": Noul(instructions="Customer explicitly requesting a refund"),
}
```

All questions are answered in one parallel pass. Documented limits: 64k tokens of state, 32k for state plus the longest question, up to 255 options per `Choice`. Pricing is $0.042 per million input tokens; output is unmetered.

## A realistic first project

Support-ticket triage is the canonical starter: take 200 historical tickets you have already labelled, ask Jev the three questions above, and compare its answers and probabilities against your labels. This gives you the two things that matter — accuracy on *your* distribution, and whether the confidence scores are honest enough to set thresholds against, per [Jev in an agent stack](jev-in-an-agent-stack.md). Early reports of working demos in under an hour are plausible; treat your own eval as the real milestone.

Mind the documented gotchas: Jev reads literally (negations bite), cannot count, does not order dates, and degrades with bloated context — retrieve and filter in code before sending state. Test adversarial injection if state includes user text.

## What is still unknown or unreleased

Plainly: architecture, model size, and weights are undisclosed. No self-hosting, no fine-tuning, no image/audio/video input, no rate-limit or SLA documentation in public, no independent benchmarks, and no proof the pricing is sustainable rather than subsidised. General availability has no announced date. If any of these are blockers, wait — see [what Jev is good for](what-jev-is-good-for.md) for whether it is worth queueing for, and [resources](resources.md) for the docs.
