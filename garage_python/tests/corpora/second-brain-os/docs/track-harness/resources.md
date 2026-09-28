# Resources

Curated, not exhaustive. Everything here was checked in September 2026 and earns its place. Read alongside [what a harness is](what-a-harness-is.md) for the vocabulary.

## Foundational posts

- [Building effective agents](https://www.anthropic.com/engineering/building-effective-agents) — Anthropic, December 2024. Still the clearest taxonomy: workflows versus agents, and the advice everyone quotes and few follow — start simple.
- [Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) — Anthropic. Named the discipline covered in [context engineering](context-engineering.md).
- [Context engineering for AI agents: lessons from building Manus](https://manus.im/blog/Context-Engineering-for-AI-Agents-Lessons-from-Building-Manus) — production scars: KV-cache economics, append-only context, masking tools instead of removing them.
- [Writing effective tools for agents](https://www.anthropic.com/engineering/writing-tools-for-agents) — the tool-design companion to [tools and MCP](tools-and-mcp.md).

## Deep guides and talks

- [How to build an agent](https://ampcode.com/notes/how-to-build-an-agent) — Thorsten Ball. A code-editing agent in under 400 lines of Go. Do this before adopting any framework; nothing demystifies faster.
- [12-factor agents](https://github.com/humanlayer/12-factor-agents) — HumanLayer. Principles for agents that survive production: own your prompts, own your context window, small focused agents.
- [How we built our multi-agent research system](https://www.anthropic.com/engineering/multi-agent-research-system) — Anthropic. Orchestrator-worker patterns, and the honest admission that multi-agent burns ~15x the tokens.
- [Context rot](https://www.trychroma.com/research/context-rot) — Chroma. The evidence that model performance degrades as input grows, long before the window fills.
- [The lethal trifecta](https://simonwillison.net/2025/Jun/16/the-lethal-trifecta/) — Simon Willison. The security frame for every agent that reads untrusted content. His ongoing blog is the best running commentary on agents generally.
- [The 2026-07-28 MCP specification](https://blog.modelcontextprotocol.io/posts/2026-07-28/) — what changed when MCP went stateless, from the protocol team.

- [Improved token efficiency](https://cursor.com/blog/improved-token-efficiency) — Cursor. A production harness slimmed in six moves: two thirds of the system prompt deleted as models improved, tools loaded on demand (60% of static tool tokens gone), explicit cache breakpoints, sparser line numbers, subagent discipline. The rare post with numbers per change; [this replication prompt](https://x.com/undefinedKi/status/2103219508605555033) applies the same audit to your own setup.

## Repos worth reading

- [pi](https://github.com/earendil-works/pi) — a full harness small enough to actually read; the loop, tools and extensions with no ceremony.
- [smolagents](https://github.com/huggingface/smolagents) — the code-as-actions pattern in ~1,000 core lines.
- [OpenHands](https://github.com/OpenHands/OpenHands) — how sandboxed runtimes and event streams look at production scale.
- [Claude Code docs](https://code.claude.com/docs/en/overview) — not a repo, but the reference harness's manual; the [hooks reference](https://code.claude.com/docs/en/hooks) alone is an education in lifecycle design.

## Start here

1. **Build the naked loop.** Work through Thorsten Ball's tutorial in your language of choice. One afternoon; permanently changes how you read framework docs.
2. **Read two posts.** Building effective agents, then effective context engineering. Together they cover 80% of the judgement calls you will face.
3. **Adopt one harness and instrument it.** Pick from the [landscape](harness-landscape.md), wire up a real task, and read the raw transcripts of every failure. The transcript is the curriculum; everything in this track is visible there.
