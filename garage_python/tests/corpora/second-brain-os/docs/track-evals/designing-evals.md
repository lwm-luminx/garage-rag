# Designing Evals

An eval is only as good as its test cases. The route from "our bot sometimes messes up" to a suite you trust runs through failure modes: name what goes wrong, then build cases that provoke it. This page assumes you have done the error analysis described in [why evals](why-evals.md).

## Golden sets

A golden set is a fixed collection of inputs with known-good expectations, curated by a human who understands the product. Rules of thumb:

- Source from production traces first, invention second. Real inputs are weirder than anything you will write.
- Every named failure mode gets at least a handful of cases that historically triggered it.
- Include boring successes too, or you will over-fit to pathology and regress the happy path.
- Version it in git next to the code. A golden set nobody can diff is a golden set nobody trusts.

## Synthetic data

When traffic is thin — pre-launch, or for rare-but-critical paths — generate cases. Use an LLM to vary dimensions you choose deliberately: persona, phrasing, length, language, adversarial intent. Two cautions:

- Synthetic inputs are fine; synthetic *labels* are circular. A model grading a model on data it invented proves little. Have a human spot-check labels.
- Generate along a schema of dimensions, not "give me 100 diverse examples", which yields 100 examples of the same three ideas.

## Graded vs binary

Prefer binary. Pass/fail forces you to define the bar, and disagreements between humans surface immediately. A 1–5 "quality" scale mostly measures the grader's mood; two annotators will happily give the same output a 3 and a 4 and learn nothing. If something genuinely has degrees, decompose it into several binary checks (cites a source: yes/no; correct source: yes/no) rather than one fuzzy scalar. This matters double when the grader is an [llm as judge](llm-as-judge.md).

## Per-step vs end-to-end

For single calls the question does not arise. For agents you need both:

- **End-to-end**: did the task get done? This is the number that matters to users.
- **Per-step**: was each tool call sensible, did retrieval return the right document, did the plan address the request? These localise the failure when end-to-end fails.

End-to-end tells you *that* it broke; per-step tells you *where*. Details in [agent evals](agent-evals.md).

## Sample sizes that matter

Small suites lie. With 20 cases, a swing from 70% to 80% is two examples — noise. Rough guidance:

- 20–50 cases: enough to start the flywheel, not enough to compare prompts.
- 100–200 per failure mode you care about: differences of ~10 points start meaning something.
- Run stochastic systems multiple times per case; report the spread, not one lucky run.

When in doubt, compute a confidence interval before celebrating. If the interval spans both "improved" and "regressed", collect more cases instead of shipping.
