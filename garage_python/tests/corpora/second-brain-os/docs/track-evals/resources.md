# Eval Resources

A short list, deliberately. Everything here earns its place; everything it links to is optional. The concepts they teach map onto [why evals](why-evals.md) and the rest of this track.

## The canon

- [Your AI Product Needs Evals](https://hamel.dev/blog/posts/evals/) — Hamel Husain. The essay that made evals a discipline: unit tests, human review, and A/B tests as three levels, plus the case for looking at your data. Start here.
- [AI Evals FAQ](https://hamel.dev/blog/posts/evals-faq/) — Husain and Shreya Shankar's running answers to the questions every team asks: binary vs Likert, how many labels, who should annotate, build vs buy. Dense and free.
- [AI Evals for Engineers & PMs](https://maven.com/parlance-labs/evals) — the Maven course behind the FAQ; several thousand engineers and PMs through it, cohorts still running in 2026. Paid, and the one course worth the money in this space.
- [Who Validates the Validators?](https://arxiv.org/abs/2404.12272) — Shankar et al. The research grounding for aligning LLM judges with human labels; explains why rubric criteria drift as humans grade more outputs.
- [Demystifying Evals for AI Agents](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents) — Anthropic's engineering guide (January 2026): task selection, trajectory vs outcome grading, judge calibration, evals as CI. The closest thing to an official playbook for [agent evals](agent-evals.md).
- [Evaluation Best Practices](https://developers.openai.com/api/docs/guides/evaluation-best-practices) — OpenAI's guide; complements the above and pairs with the [evals cookbook section](https://developers.openai.com/cookbook/topic/evals) for worked judge examples.

## Repos worth reading

- [inspect_evals](https://github.com/UKGovernmentBEIS/inspect_evals) — 200+ evaluations implemented under UK AISI's Inspect. Read a few scorers and solvers to see what production-grade eval code looks like.
- [terminal-bench](https://github.com/laude-institute/terminal-bench) — hand-audited tasks in Docker with executable graders. The cleanest reference for building environment-based evals of your own; more context in [agent evals](agent-evals.md).

## Start here: three steps

1. **Read 30 traces.** Pull thirty real (or realistic) transcripts from your product tonight and write one sentence per failure. No tooling, just a spreadsheet. This is error analysis, and it will reshape your roadmap.
2. **Name the failures, encode the top three.** Cluster your notes into a taxonomy, then turn the three most frequent failure modes into checks — code assertions where possible, one narrow calibrated judge where not. The mechanics are in [designing evals](designing-evals.md) and [llm as judge](llm-as-judge.md).
3. **Put the suite in CI and re-run weekly.** Wire the checks into your pipeline with a threshold, fix the biggest failure mode, and return to step 1 with fresh traces. That loop, repeated, is the entire discipline.
