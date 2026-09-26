# Claude Code as Harness

Claude Code is the most instructive harness to study because Anthropic ships the same machinery twice: as a terminal product, and as the [Claude Agent SDK](https://code.claude.com/docs/en/agent-sdk/overview) — a Python and TypeScript library exposing the identical loop, permission system and context management for your own agents. Read the [anatomy page](what-a-harness-is.md) first; this page maps each part to a concrete feature.

## CLAUDE.md and memory

`CLAUDE.md` is a plain markdown file read at session start — project conventions, build commands, house rules. It composes hierarchically: user-level, project-level, directory-level. Auto-memory files extend this across sessions. The lesson: persistent instructions belong in files the agent reads, not in prompts you retype. See [context engineering](context-engineering.md) for why this beats stuffing everything into one prompt.

## Hooks

[Hooks](https://code.claude.com/docs/en/hooks) are shell commands bound to lifecycle events — `PreToolUse`, `PostToolUse`, `SessionStart`, `PreCompact` and a few dozen more by 2026. They are deterministic enforcement, not suggestions: a `PreToolUse` hook can block a dangerous command every single time, where a prompt instruction merely lowers the odds. Rule of thumb: prompts for judgement, hooks for policy.

## Subagents

Subagents run in their own context window with their own system prompt and tool restrictions. The parent sees only the final report, never the intermediate noise — which keeps the orchestrating transcript clean and effectively multiplies usable context. Defined as markdown files in `.claude/agents/` or programmatically via the SDK.

## Skills

A skill is a folder with a `SKILL.md` plus optional scripts and templates. Only the one-line description sits in context permanently; the body loads when relevant. This is retrieval-on-demand for instructions — the pattern that keeps a capable agent from drowning in its own manual. Docs: [Agent Skills](https://code.claude.com/docs/en/agent-sdk/skills).

## MCP

Claude Code is an MCP client: external servers contribute tools alongside the built-ins, configured per project or per user. Powerful and the main injection surface — treated fully in [tools and MCP](tools-and-mcp.md).

## Permissions

Every tool call passes through a permission layer: allowlists in `settings.json`, per-call prompts, `plan` mode (read-only), and sandboxed execution. The design assumption is that the model will occasionally do something daft, so the harness, not the model, holds the brakes.

## Headless and SDK use

`claude -p "prompt"` runs one-shot in scripts and CI, with JSON output. The Agent SDK goes further: `query()` for simple calls, a client class for hooks and streaming, programmatic subagents and MCP servers. You are not scripting the CLI; you are embedding the harness.

## The honest take

It is the most complete off-the-shelf harness available in 2026, and the vocabulary the rest of the field defines itself against — see the [landscape](harness-landscape.md). Cost: you inherit Anthropic's opinions and their token appetite. For most builders that is a fine trade.
