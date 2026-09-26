# What a Harness Is

A harness is everything around the model that turns text prediction into work done: the loop, the tools, the prompts, the permissions, the plumbing. The model decides; the harness executes, observes, and feeds the result back. Same model, different harness, wildly different agent.

## The loop

At the core sits a while-loop. Send the conversation to the model. If the reply contains tool calls, run them, append the results, go round again. If it contains only text, stop and show the user. That is the whole trick — Thorsten Ball's [How to build an agent](https://ampcode.com/notes/how-to-build-an-agent) does it in under 400 lines of Go. Everything else in this track is refinement of that loop.

## Tool schemas

Tools are JSON schemas the model reads: a name, a description, typed parameters. The description is a prompt in disguise — the model chooses tools by reading it, so vague descriptions produce vague behaviour. Granularity, naming and error messages matter more than the transport. Covered properly in [tools and MCP](tools-and-mcp.md).

## System prompt

The standing instructions: who the agent is, how it should behave, what the environment looks like. Production harnesses ship system prompts of thousands of words — house style, safety rules, tool usage conventions. This is where "just a chatbot" becomes "an agent with judgement".

## Permissions

An agent that can run `rm -rf` needs a gate. Harnesses layer allowlists, per-tool approval prompts, sandboxes and read-only modes between the model's intent and the machine. The permission system is what lets you leave an agent unattended; without it you are the harness.

## Context window management

The window is finite and quality degrades before it fills. The harness decides what enters it: which files, how much tool output, when to summarise old turns, what persists across sessions in memory files. This is the discipline of [context engineering](context-engineering.md), and it is where good harnesses earn their keep.

## Why the harness matters as much as the model

Benchmarks through 2026 keep showing the same thing: the harness moves the numbers. Databricks' internal testing found pi's minimal harness beat heavier ones on pass rate at a third of the context per turn — same models, different machinery. A harness that sends bloated context wastes money and degrades reasoning; one that recovers well from failed tool calls finishes tasks that others abandon. Model labs now tune harnesses to their models (OpenAI calls theirs "in-distribution"), which tells you they consider it part of the product, not packaging.

## The rest of the anatomy

Mature harnesses add hooks (deterministic scripts on lifecycle events), subagents (fresh context windows for delegated work), and skills (instructions loaded on demand). [Claude Code](claude-code-as-harness.md) is the reference implementation of all of these; the [landscape page](harness-landscape.md) surveys the alternatives.

Learn the anatomy once and every framework becomes legible: they are all the same loop wearing different coats.
