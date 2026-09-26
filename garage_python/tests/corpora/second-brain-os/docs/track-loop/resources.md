# Resources

A health warning first: "loop engineering" was coined in June 2026 and is three months old as this page is written. The practices underneath are sturdier than the label — Steinberger himself was already asking whether the conversation had moved from loops to graphs by mid-July. Read for the mechanisms, hold the vocabulary loosely.

## The naming

- [Peter Steinberger's post](https://x.com/steipete/status/2063697162748260627) — the line that caught, June 2026: "You shouldn't be prompting coding agents anymore. You should be designing loops that prompt your agents."
- [Loop Engineering](https://www.oreilly.com/radar/loop-engineering/) — Addy Osmani's essay, syndicated on O'Reilly Radar. The anatomy: automations, worktrees, skills, connectors, subagents, external state — and the honest closing warnings about verification burden and comprehension debt.
- [Code review in the age of AI](https://addyosmani.com/blog/code-review-ai/) — Osmani's companion piece; "your job is to ship code you confirmed works" is this track in nine words.
- [What is loop engineering?](https://www.ibm.com/think/topics/loop-engineering) — IBM's topic page; useful as the sober institutional definition, strong on the risks (comprehension debt, intent debt, cognitive surrender).

## Papers

- [Stop Hand-Holding Your Coding Agent](https://arxiv.org/pdf/2607.00038) — Sandeco Macedo. The academic treatment: termination conditions, verification and critic components as first-class loop infrastructure.
- [Less Context, Better Agents](https://arxiv.org/pdf/2606.10209) — efficient context engineering for long-horizon tool-using agents; the measured case for the pruning argued in [context hygiene](context-hygiene.md).

## Anthropic material

- [Managing context on the Claude Developer Platform](https://claude.com/blog/context-management) — context editing and the memory tool, with the numbers this track quotes: an 84% token cut on a 100-turn evaluation, 29% from editing alone, 39% combined.
- The harness track's [resources page](../track-harness/resources.md) holds the rest of the Anthropic canon — building effective agents, effective context engineering — which this track assumes rather than repeats.

## Practice

- [Ralph Wiggum as a "software engineer"](https://ghuntley.com/ralph/) — Geoffrey Huntley. The bash loop that started it, with unusually honest failure notes.
- [Designing agentic loops](https://simonwillison.net/2025/Sep/30/designing-agentic-loops/) — Simon Willison, September 2025. Which tasks loop well, and the security posture for letting one run.

## Repos worth reading

- [humanlayer/12-factor-agents](https://github.com/humanlayer/12-factor-agents) — principles for agents that survive production; several factors are loop discipline by another name.
- [anthropics/claude-code](https://github.com/anthropics/claude-code/blob/main/plugins/ralph-wiggum/README.md) — the `ralph-wiggum` plugin: the run-in-a-loop pattern as maintained, inspectable code.
- [vercel-labs/ralph-loop-agent](https://github.com/vercel-labs/ralph-loop-agent) — the same pattern rebuilt on the AI SDK, with verification and iteration made explicit.

## Start here

1. **Write one goal test.** Pick a task you keep hand-prompting and express done as a script that exits 0. If you cannot, per [what loop engineering is](what-loop-engineering-is.md), it is not a loop candidate yet.
2. **Build the retry loop.** Work through [Build: the goal test](build-goal-test.md) on a small repo with failing tests. One evening.
3. **Add the judge, then the rails.** Critic pass, then ratchet and report — and only once the loop stops legibly every single time do you let it run while you sleep.
