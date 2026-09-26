# What Loop Engineering Is

Loop engineering is the discipline of designing the control system that runs an agent: the thing that decides what to prompt, how to verify the result, whether to retry, and when to stop. You stop doing those jobs by hand, turn by turn, and encode them once. Prompt engineering optimised a single message. Loop engineering optimises the cycle — who calls the model next, against what goal, judged by what test, under what budget.

## Where the term came from

On 7 June 2026 Peter Steinberger posted the line that named the shift: "You shouldn't be prompting coding agents anymore. You should be designing loops that prompt your agents." It was viewed millions of times within a day. Addy Osmani's essay "Loop Engineering" followed almost immediately (O'Reilly Radar syndicated it on 22 June), giving the idea an anatomy: automations, worktrees, skills, connectors, subagents, and external state so progress survives between runs. Boris Cherny of Anthropic put it bluntly: "I don't prompt Claude anymore. I have loops running that prompt Claude... My job is to write loops."

The practices are older than the name. Geoffrey Huntley's Ralph loop dates from July 2025; Simon Willison wrote "Designing agentic loops" that September, defining an agent as something that "runs tools in a loop to achieve a goal". June 2026 is simply when the discipline got a label — it is three months old as this track is written, so expect the vocabulary to churn.

## Prompt engineering versus loop engineering

Hand-prompting spends your judgement one turn at a time: you read the output, decide whether it is good, and phrase the next nudge. Loop engineering spends that judgement once, up front, on four artefacts: a goal expressed as an executable test, a retry policy that feeds failures back, a budget, and a stop rule. After that, the loop prompts the agent and you review outcomes. The bottleneck moves from writing instructions to proving results.

## The four pillars

- **Context hygiene** — deciding what survives between turns and attempts, and what gets deliberately thrown away. Covered in [context hygiene](context-hygiene.md).
- **Stop conditions** — goal tests, budgets, ratchets and spin detection, because "the agent says it's done" is a claim, not a condition. Covered in [stop conditions](stop-conditions.md).
- **A real critic** — verification the agent cannot argue with, separated from the agent that did the work. Covered in [critics and verification](critics-and-verification.md).
- **Idempotent tools** — anything the loop retries will eventually run twice, so every write the agent can reach must be safe to repeat. A retried "create invoice" must not create two invoices; design tools so the second call is a no-op.

## Not the same thing as a harness

This site already has a track on [agent harnesses](../track-harness/what-a-harness-is.md) — the machinery around the model: the inner while-loop, tool schemas, permissions, context window management. Loop engineering is the control discipline layered on top of that machinery. The harness executes a turn; the loop decides whether there should be a next turn, what it should attempt, who judges it, and when the whole exercise ends. You need both: a good harness with no loop discipline is a very fast way to produce unverified work, and loop discipline without a decent harness has nothing reliable to steer.
