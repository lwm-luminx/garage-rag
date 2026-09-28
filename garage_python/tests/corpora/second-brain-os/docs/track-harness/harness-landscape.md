# Harness Landscape

A survey of what is alive in September 2026, with one honest take each. They all run the same loop described in [what a harness is](what-a-harness-is.md); they differ in how much machinery they wrap around it and whose opinions you inherit.

## The main options

- **[Claude Agent SDK](https://code.claude.com/docs/en/agent-sdk/overview)** (Anthropic, Python/TS). The Claude Code loop as a library: permissions, hooks, subagents, skills, compaction included. The most complete harness you can adopt wholesale — at the price of Anthropic's opinions and Anthropic's models doing their best work in it. Detailed in [Claude Code as harness](claude-code-as-harness.md).

- **[OpenAI Agents SDK](https://openai.github.io/openai-agents-python/)** (Python, TS lagging). Lightweight: agents, handoffs, guardrails, sessions. The April 2026 update added native sandboxing and a "model-native harness" tuned for GPT-5-class models. Part of the broader [AgentKit](https://openai.com/index/introducing-agentkit/) bundle — note the drag-and-drop Agent Builder is being retired November 2026, so bet on the SDK, not the canvas.

- **[LangGraph](https://www.langchain.com/langgraph)** (LangChain, Python/JS). Agents as explicit state graphs, 1.0 since late 2025, durable execution and human-in-the-loop interrupts. Genuinely production-proven, and genuinely heavy. Choose it when you need auditable control flow, not because it is the famous one.

- **[Vercel AI SDK 6](https://ai-sdk.dev)** (TypeScript). Went from streaming toolkit to real harness: `ToolLoopAgent`, tool approval, full MCP support. The sensible default when your agent lives inside a web product. Release notes: [AI SDK 6](https://vercel.com/blog/ai-sdk-6).

- **[smolagents](https://github.com/huggingface/smolagents)** (Hugging Face, Python). ~1,000 lines of core; agents write Python code as their actions instead of JSON tool calls. The fastest route to a working loop and the best codebase for learning. Thin on production concerns by design.

- **[OpenHands](https://github.com/OpenHands/OpenHands)** (formerly OpenDevin; the org moved from All-Hands-AI to OpenHands). Open-source autonomous software engineering: sandboxed runtime, browser, cloud platform at [openhands.dev](https://www.openhands.dev/). The reference for what a fully sandboxed coding harness looks like; heavier to self-host than a CLI.

- **[pi](https://github.com/earendil-works/pi)** (Mario Zechner, ex badlogic/pi-mono, now under Earendil; docs at [pi.dev](https://pi.dev)). A deliberately minimal terminal harness, extensible via TypeScript rather than configuration sprawl. Databricks benchmarking found it beat heavier harnesses on pass rate while sending roughly a third of the context per turn — minimalism as [context engineering](context-engineering.md), and proof the harness moves the numbers.

- **[Pydantic AI](https://ai.pydantic.dev)** (Python). Type-safe agents from the validation people. Boring in the best way; strong choice when structured outputs are the whole job.

## How to choose

Building on Claude: Agent SDK. TypeScript web product: Vercel AI SDK. Explicit workflow control: LangGraph. Learning: smolagents, then read pi's source. Autonomous coding infra: OpenHands. Most teams need one harness and the discipline to feed it well — not a framework tour.
