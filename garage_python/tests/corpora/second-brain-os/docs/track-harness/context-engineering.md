# Context Engineering

Prompt engineering asked "what words do I use?". Context engineering asks "what does the model see at this moment, and why?". For agents the second question dominates: every tool result, file read and old turn competes for a finite window, and the harness curates it. Anthropic's [Effective context engineering for AI agents](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) is the canonical statement of the discipline.

## The budget

Treat the window as a budget, not a bin. Attention degrades before the window fills — Chroma's [context rot](https://www.trychroma.com/research/context-rot) research showed performance sliding as input grows, long before any hard limit. The practical rule: the smallest set of high-signal tokens that lets the model act. Everything you add dilutes everything already there.

## What goes in, and when

- **Always in**: system prompt, tool schemas, memory files like `CLAUDE.md`. Keep these lean and stable — stable prefixes also keep the KV-cache warm, which Manus [measured at a 10x cost difference](https://manus.im/blog/Context-Engineering-for-AI-Agents-Lessons-from-Building-Manus).
- **On demand**: file contents, search results, skill bodies, documentation. Give the agent retrieval tools and let it pull what it needs, rather than pre-loading what it might need.
- **Never**: whole codebases, full API responses, ten variants of the same instruction.

## Compaction

Long sessions outgrow any window. Compaction summarises the transcript — decisions, open threads, file paths — and starts fresh with the summary. It is lossy by design; a good harness compacts around tool results (bulky, rarely needed again) and preserves intent. [Claude Code](claude-code-as-harness.md) does this automatically and exposes `PreCompact` hooks for control.

## Memory files

State that must survive compaction and sessions belongs outside the window, in plain files the agent reads and writes: a scratchpad, a `MEMORY.md`, a todo list. The filesystem is the agent's long-term memory; the window is working memory. Second-brain readers will recognise the pattern.

## Structured outputs

When downstream code consumes the agent's answer, demand a schema — JSON with typed fields, enforced by the API where possible. Free text is for humans; structure is for pipelines. It also disciplines the model: a required field is a question it cannot dodge.

## Failure modes

- **Context poisoning**: one hallucinated "fact" enters the transcript and gets treated as ground truth for the rest of the session.
- **Distraction**: buried instructions lose to recent noise; the agent forgets the goal amid tool output.
- **Clash**: contradictory instructions from system prompt, memory file and user, resolved arbitrarily.
- **Bloat**: a 40,000-token tool result nobody reads, paid for on every subsequent turn.

Most "the model got dumber" reports are one of these four. Diagnose by reading the actual transcript — the harness should let you.

## Where tools fit

Tool schemas and results are the biggest single consumer of context in most agents, which makes tool design a context-engineering decision — the subject of [tools and MCP](tools-and-mcp.md).
