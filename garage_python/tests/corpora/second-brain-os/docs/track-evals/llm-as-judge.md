# LLM as Judge

Some checks are code: exact match, regex, JSON schema, "does the SQL run". Everything else — tone, faithfulness, whether the answer actually addresses the question — needs a grader that reads. That grader is usually another LLM. Useful, cheap, and untrustworthy until calibrated.

## Writing the judge prompt

A judge prompt is a job description, not a wish:

- One question per judge. "Is the claim supported by the provided context: yes/no" beats "rate overall quality".
- Binary output with a required *written rationale before the verdict*. The rationale is your debugging trail; verdict-first judges rationalise.
- Include 2–4 worked examples of pass and fail, especially borderline ones.
- Give it the same context the product had. A judge grading a RAG answer without the retrieved documents is guessing.

Keep the rubric in the prompt concrete: quote the failure taxonomy from your error analysis (see [designing evals](designing-evals.md)), not adjectives like "helpful" or "high-quality".

## Calibration against human labels

An uncalibrated judge is a random number generator with confidence. The procedure, straight from Hamel Husain's [judge guide](https://hamel.dev/blog/posts/llm-judge/):

1. A domain expert labels 50–100 outputs pass/fail with a short reason.
2. Run the judge on the same set; measure agreement (report per-class agreement, not raw accuracy — a judge that always says "pass" scores 90% on mostly-good data).
3. Read every disagreement. Fix the rubric, or discover your own labels were inconsistent — both happen.
4. Repeat until agreement is boring, then re-check quarterly and whenever you change the judge model.

Shreya Shankar's [Who Validates the Validators?](https://arxiv.org/abs/2404.12272) is the research treatment of this loop.

## Known bias failure modes

Documented since the [MT-Bench paper](https://arxiv.org/abs/2306.05685) and still alive in 2026:

- **Position bias.** In pairwise comparisons, judges favour the first (sometimes second) answer. Swap the order and average, or the comparison is meaningless.
- **Verbosity bias.** Longer answers score higher, correctness held constant. Length-cap or explicitly instruct against it, then verify.
- **Self-preference.** Models rate their own family's outputs higher. Judge with a different model than the one being judged where feasible.
- **Sycophancy toward stated intent.** Include the user's claimed goal and the judge grades effort, not results.

## When judges lie

Judges fail silently on: maths and arithmetic, niche domain facts, subtle instruction violations, and anything the judge model itself would get wrong. If a check *can* be code, make it code. Reserve the judge for genuinely linguistic judgements, keep humans auditing a sample of its verdicts forever, and never let judge scores gate a release that per-step checks contradict — see [agent evals](agent-evals.md) for how the two combine.
