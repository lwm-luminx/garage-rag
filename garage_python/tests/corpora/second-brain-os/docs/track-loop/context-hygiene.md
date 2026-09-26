# Context Hygiene

The harness track covers [context engineering](../track-harness/context-engineering.md): what the model sees within a session, curated turn by turn. Context hygiene is the loop-level version of the same discipline: what survives between turns and between attempts, and — just as important — what gets deliberately destroyed. The harness manages a window; the loop manages a lifecycle.

## Editing within long runs

Long-running loops die of context exhaustion before they die of anything else. Anthropic's context management work attacks this directly: context editing automatically clears stale tool calls and results as the window approaches its limit, keeping the conversation flow intact. In their 100-turn web search evaluation, context editing let agents complete workflows that otherwise failed outright, while cutting token consumption by 84%. On multi-step benchmarks, editing alone improved performance 29% over baseline; combined with the memory tool, 39%. The lesson generalises beyond one vendor: old tool output is the least valuable and most voluminous thing in the window, and a loop that never prunes it is paying rent on rubbish.

## Files as the loop's memory

State that must survive belongs outside the window entirely, in plain files the agent reads and writes: a `plan.md`, a `TODO.md` with checkboxes, a ratchet file recording the best score so far. The model forgets between runs; the repository remembers. This is Osmani's "external state" component and the quiet trick behind every unattended pattern — the [overnight loop](build-overnight.md) is really just a ratchet file and a report file with a while-loop around them. Second-brain readers will recognise the move: working memory is ephemeral, so anything that matters gets written down.

## Fresh context per attempt

The counterintuitive discipline, learned the hard way by the Ralph loop crowd: between attempts, throw the transcript away. A failed attempt's transcript is mostly a record of confusion — wrong hypotheses, dead-end searches, apologies — and carrying it forward poisons the next attempt, which treats the confusion as established fact. Geoffrey Huntley's original loop restarts the agent cold every iteration on purpose; the same files stack into context every pass, so the prompt file and the repo are the only memory, and each attempt gets a clean window plus the goal.

What crosses the gap between attempts is a distillation, not a history: the failing test output, the critic's list of defects, the current todo state. That is exactly what the [goal test build](build-goal-test.md) feeds back — the goal script's stderr, nothing else.

## What to carry, what to burn

- **Carry**: the goal, the todo file, the last verifier output, the critic's verdict, the ratchet score.
- **Burn**: exploration transcripts, bulk tool output, the agent's running commentary, anything it said about how well things are going.

The test for each item is blunt: would a fresh, competent agent act better with this in front of it? Verifier output passes that test. A 40,000-token log of the last attempt failing does not. Hygiene is deciding on behalf of the next attempt, which is why it belongs to the loop and not to the model.
