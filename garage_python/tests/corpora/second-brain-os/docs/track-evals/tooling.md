# Eval Tooling

The market consolidated around two shapes: eval-first platforms with observability bolted on, and tracing-first platforms with evals bolted on. All of the below are alive and maintained as of late 2026. Pick one and move on; the flywheel from [why evals](why-evals.md) matters far more than the vendor.

## Platforms

- [Braintrust](https://www.braintrust.dev/) — eval-first commercial platform built around the `Eval()` loop: datasets, experiments, side-by-side regression diffs, CI gates. The default choice for engineering-led teams that started with evals rather than dashboards.
- [Langfuse](https://langfuse.com/) — the most mature open-source option; OpenTelemetry-style tracing you can self-host in an afternoon, with datasets and LLM-judge evals layered on top. Take it if data residency or an open licence is non-negotiable.
- [LangSmith](https://www.langchain.com/langsmith) — LangChain's platform. If you are on LangChain/LangGraph, instrumentation is a one-line change and the dataset workflow is solid; if you are not, there is little reason to arrive here.
- [W&B Weave](https://weave-docs.wandb.ai/) — evaluation and tracing from Weights & Biases; decorate functions, get versioned traces and eval dashboards. Natural if your org already lives in W&B.

## Frameworks and CLIs

- [promptfoo](https://www.promptfoo.dev/) — open-source CLI: declare prompts, providers and assertions in YAML, get a comparison matrix. Fastest route to "which prompt/model is better", plus a serious red-teaming mode. Excellent in CI.
- [Inspect](https://inspect.aisi.org.uk/) — the UK AI Security Institute's open-source Python framework: composable solvers, scorers and sandboxed agent environments, with 200+ ready evals in [inspect_evals](https://github.com/UKGovernmentBEIS/inspect_evals). Built for rigour; the standard in safety-testing circles and very good for [agent evals](agent-evals.md) generally.
- [OpenAI Evals](https://github.com/openai/evals) — the 2023 registry repo still stands, but OpenAI's supported path is now the Evals product inside the API and dashboard, with an [evaluation best-practices guide](https://developers.openai.com/api/docs/guides/evaluation-best-practices). Use the docs, not the repo.
- [DeepEval](https://github.com/confident-ai/deepeval) — pytest-style eval framework with off-the-shelf metrics (faithfulness, answer relevancy). Convenient for CI; treat the prebuilt metrics as starting points, not truths — calibrate per [llm as judge](llm-as-judge.md).

## Claude Code plugin evals

Anthropic shipped an eval harness inside Claude Code itself (v2.1.269+, September 2026): `claude plugin eval` runs a plugin or skill against a suite of realistic prompts, grades results with six grader types (`regex`, `tool_used`, `tool_order`, `file_exists`, `llm`, `baseline`), and — the honest part — re-runs *without* the plugin to report the delta the plugin actually contributes. `claude plugin eval init` proposes cases interactively; `--threshold` gates CI. Documented at [code.claude.com/docs/en/plugin-evals](https://code.claude.com/docs/en/plugin-evals). If you write skills for agents, this is the same discipline applied to your prompt scaffolding.

## Honest advice

Every platform demos beautifully with a toy dataset. The differentiator is whether your team will actually read traces in it weekly. Trial with your own failure taxonomy for a fortnight before signing anything.
