# Jev in an Agent Stack

The most credible early use of Jev is not replacing an LLM but sitting next to one. Agent loops are full of small bounded decisions — which model, which tool, is this safe, are we done — and today each one costs a full LLM call. The emerging pattern, a week old and already visible in the [LangChain harness writeup](https://www.langchain.com/blog/building-a-harness-with-jev), is to hand those decisions to a System One model and keep the LLM for the parts that need language. Background in [system one models](system-one-models.md).

## Jev in front of the loop

- **Router.** Jev classifies the incoming request and routes it: cheap fast model for simple lookups, expensive reasoning model for hard cases. At 70–500ms claimed latency, the routing step is nearly free relative to the call it saves.
- **Triage gate.** A `Noul` question ("does this need a human?") in front of the agent keeps junk out of the loop entirely.

## Jev inside the loop

- **Tool-call guardrails.** LangChain's `AutoModeMiddleware` uses Jev to check a proposed tool call for risky actions and block it before execution — a typed judgement, not a second LLM opining on the first.
- **State checks.** "Is the task complete?", "did that tool call succeed?", "is the user frustrated?" — each is a typed question over the transcript, and because Jev answers all questions in one parallel pass, asking ten costs barely more time than asking one.

The LangChain integration exposes this as `TypeSafeClassifier`: you pass a `state` and a dict of questions to `.invoke()` and get back typed answers with probabilities, which your code — not a model — then acts on.

## Failure handling with confidence thresholds

The probability on every answer is the design's load-bearing part. The pattern early adopters converge on:

- Set a threshold per decision, priced by the cost of being wrong. Auto-approving a refund might need 0.98; picking a support queue might be fine at 0.7.
- Below threshold, escalate — to an LLM, to a human, or to a safe default. Jev becomes the fast path, not the only path.
- Log the probabilities. Jev gives no rationale, so the state you sent plus the scores you got back are your entire audit trail. Keep them.

One honest caution: this whole scheme assumes the probabilities are genuinely calibrated, which is TypeSafe's central claim and is so far unverified on out-of-distribution traffic. Sceptics note that a confident score is not by itself evidence the prediction deserves trust. Start with conservative thresholds and measure against your own labels. Practical setup in [getting started](getting-started.md); task fit in [what Jev is good for](what-jev-is-good-for.md).
