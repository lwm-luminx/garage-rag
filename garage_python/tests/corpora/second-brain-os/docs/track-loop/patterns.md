# Patterns

Five loop shapes keep reappearing under different names. Each earns its keep on a particular kind of work, and each has failure modes its advocates tend to soft-pedal. They are listed here with both.

## Run-in-a-loop (Ralph)

Geoffrey Huntley's July 2025 original: `while :; do cat PROMPT.md | claude-code ; done`. No orchestration at all — when a session ends, another starts cold, reads the same prompt file and the same repo, and picks up where the last one left off through files on disk. It is the purest demonstration that fresh context plus persistent files beats one long degrading session, and Anthropic now ships it as the `ralph-wiggum` plugin in the Claude Code repo.

Failure modes, admitted by the author himself: placeholder implementations that satisfy the compiler and nothing else; waking up to a tree that does not build; and it suits greenfield work — Huntley's own line is that he would not run Ralph on an existing codebase. Ralph gets you roughly 90% of a first version, with a human stop button as the only brake.

## Plan-execute-verify

Split the run into phases: one pass produces a plan file, subsequent passes execute steps, a verifier gates each one. Good for multi-step work where a single prompt drifts. Failure mode: plans go stale on contact with reality, and a loop that executes a stale plan faithfully compounds the error — the verifier must run per step, not once at the end.

## Generator-critic pairs

One agent makes, a separate pass judges against a narrow rubric, defects feed the next attempt. The maker-checker separation is the point: the implementer cannot grade itself. Failure modes: a vague rubric turns the critic into a noise generator; and when generator and critic share a model and a context, they share blind spots and converge on approving each other. Details in [critics and verification](critics-and-verification.md); wiring in [Build: the critic](build-critic.md).

## Tournament / best-of-n

Launch n attempts in parallel — git worktrees make this cheap to isolate — and let a verifier pick the winner. Powerful when attempts are high-variance and verification is cheap. Failure modes: cost multiplies by n whether or not any attempt is good; and without a genuinely strong picker you have paid n times for confident garbage and then chosen the most confident of it. The verifier asymmetry test decides whether this pattern is affordable at all.

## Overnight unattended runs with mailbox reports

Budgeted, ratcheted, branch-isolated runs that work while you sleep and leave a morning report in markdown: what improved, what stopped the loop, what needs a decision. The end state of the discipline, and the pattern with the strictest entry requirements — every brake from [stop conditions](stop-conditions.md), plus rails that make the worst case boring. Failure modes: unattended loops make unattended mistakes, and the debt lands on you as comprehension debt — shipped changes outpacing your understanding of them. Osmani's warning stands: build the loop like someone who intends to stay the engineer, not just the person who presses go.

## Choosing between them

Start with the simplest loop that has a real verifier: the plain retry loop in [Build: the goal test](build-goal-test.md). Add a critic when green-but-ugly becomes your common failure. Go parallel or overnight only once the single loop stops legibly every time — the fancier patterns amplify whichever discipline you already have, including its absence.
