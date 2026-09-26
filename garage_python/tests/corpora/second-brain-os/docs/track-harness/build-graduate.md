# Build: Know When to Graduate

You now own roughly 150 lines that do what every harness does: loop, execute, gate, budget, stop. The build was the education. This page is the exit interview — what those lines lack, what solves each gap off the shelf, and an honest rule for choosing.

The comparison below uses the [Claude Agent SDK](https://code.claude.com/docs/en/agent-sdk/overview), because it is Claude Code's own machinery as a library and the natural upgrade path from this build; the [landscape page](harness-landscape.md) covers the alternatives.

## Gap one: compaction quality

Your budget drops old turns and leaves a one-line gist. That loses decisions, file paths and half-finished threads — precisely the things worth keeping. The Agent SDK inherits Claude Code's automatic context management: compaction that summarises the transcript properly, preserving intent while shedding bulky tool output, with hooks to control what survives. The difference between a gist and a good summary is the difference between an agent that resumes work and one that repeats it — [context engineering](context-engineering.md) explains why.

## Gap two: parallel tool execution

Current models routinely return several `tool_use` blocks in one turn. Your loop executes them one after another, which is correct but slow — three thirty-second commands take ninety seconds. The SDK runs independent tool calls concurrently, and adds subagents for the bigger version of the same idea: delegated work in a fresh context window, with only the final report returned to the parent.

## Gap three: sandboxing

Part two admitted its gate is leaky: prefix matching waves through shell metacharacters, and `input()` only works while you are watching. The SDK ships the full permission system described in [Claude Code as harness](claude-code-as-harness.md) — allowlist rules in settings, permission modes, sandboxed command execution, and `PreToolUse` hooks that block deterministically rather than probabilistically. Policy enforced by code, not by hoping you are at the keyboard.

## Gap four: resume

Kill your agent mid-task and everything is gone; the transcript lived in a Python list. The SDK's sessions persist state across exchanges and let you resume or fork a conversation later. Combined with memory files loaded from `.claude/`, the agent starts each session knowing the project instead of rediscovering it.

## The decision rule

Build your own when at least one of these is true: you are learning (the reason this track exists); the loop itself is your product and you need to own every line; or the task is narrow enough — two or three tools, short sessions, a human present — that 150 lines genuinely cover it. Plenty of useful internal tools live happily at that size.

Adopt a harness the moment any of these becomes true: the agent runs unattended; it reads untrusted content (web pages, emails, other people's code); sessions run long enough that compaction quality decides success; or you catch yourself building a permission system in earnest. Each of those is months of unglamorous engineering that Anthropic and others have already done, tested against failure modes you have not met yet. Rebuilding it is not rigour, it is expense.

The honest summary: the 150 lines were never the destination. They are the reason framework documentation now reads as choices rather than magic — you know what the loop looks like naked, so you can tell which coats are warm and which are decoration. Pick from the [landscape](harness-landscape.md), wire up a real task, and keep reading transcripts.
