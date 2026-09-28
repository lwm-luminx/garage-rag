# What Jev Is Good For

Jev is not a general-purpose model. It answers typed questions about a blob of context, nothing more. That makes the fit question simple: does your task reduce to picking from a bounded answer space? If yes, it is Jev-shaped. If the answer needs to be written, it is not. Background in [system one models](system-one-models.md).

## The task shapes

- **Classification.** Intent detection, ticket categorisation, content labelling — a `Choice` over up to 255 options with a probability per option.
- **Routing.** Which team, which tool, which downstream model handles this request. Same primitive, wired into control flow.
- **Extraction to schema.** Answering a battery of typed questions about one document: is this an invoice (`Noul`), which vendor (`Choice`), how urgent (`Score`). Extra questions barely add latency because everything is answered in one parallel pass.
- **Guardrails.** Pre-flight checks on agent tool calls: "is this action destructive?" as a `Noul`, blocked above a threshold.
- **Ranking and scoring.** Placing items on an ordered scale — lead quality, frustration level, relevance — at volumes where LLM scoring is unaffordable.

## Where an LLM still wins

- Anything that produces text, code, or a summary. Jev generates no strings at all.
- Open-ended reasoning where you cannot enumerate the answers up front.
- Tasks needing an explanation. Jev gives you a probability, not a rationale — a real problem for audits in regulated settings.
- Careful reading. Early users report Jev reads literally: negations and scoping words trip it, it cannot count reliably, and it does not treat dates as ordered quantities.
- Raw accuracy at the frontier. On TypeSafe's own eval, Claude Opus 5 scored 73.1% against Jev's 67.8%.

## The latency and cost maths

All figures are TypeSafe's published claims, not independent measurements:

- End-to-end latency of 70–500ms, versus 3–329s quoted for frontier LLM workflows — the "40–200x faster" range.
- Pricing of $0.042 per million input tokens, output tokens free. On their four-workflow eval that works out to about $0.0004 per case, against $0.0304 for GPT-5.6 Terra (67.9% accuracy, 10.1s) and $0.1761 for Claude Opus 5 (37.8s).
- Peak claims of 193.6x faster and 444.6x cheaper come from workflows built by TypeSafe's own capabilities team, run from their own machines. They concede these are high-end numbers, and they cannot yet prove pricing is not subsidised.

The steel-manned version: for a million classify-or-route decisions a day, even a 10x real-world saving changes what is economical to build. Whether the saving is 10x or 400x is exactly what independent testing has not yet established. To wire it into an agent, see [Jev in an agent stack](jev-in-an-agent-stack.md); to try a first project, see [getting started](getting-started.md).
