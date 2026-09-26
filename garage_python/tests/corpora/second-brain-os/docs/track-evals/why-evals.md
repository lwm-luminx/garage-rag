# Why Evals

Evals are the tests of AI products. A prompt change that fixes one complaint quietly breaks three other things; without measurement you find out from users. Teams that ship reliable LLM features treat evaluation as an engineering discipline, not a vibe check before the demo.

## Vibes vs measurement

Vibes-based development looks like this: tweak the prompt, paste in the three examples you remember, nod, ship. It works for a weekend project. It collapses the moment you have real traffic, because you are sampling your own memory instead of your users' inputs.

Measurement is boring and specific:

- a fixed set of inputs that represent real usage
- an automated way to score each output
- a number that moves when you change something

That number is what lets you say "the new model is worth the migration" or "this prompt edit made retrieval worse" with a straight face.

## The eval flywheel

The loop, roughly as taught by Hamel Husain and Shreya Shankar and echoed in [Anthropic's agent-evals guide](https://www.anthropic.com/engineering/demystifying-evals-for-ai-agents):

1. **Error analysis.** Read real traces. Not dashboards — actual transcripts, thirty or a hundred of them. Write a short note on every failure you see.
2. **Taxonomy.** Cluster those notes into named failure modes: "hallucinated order ID", "ignored the date filter", "apologised instead of acting".
3. **Metrics.** Turn each frequent failure mode into a check — a string assertion, a code test, or an [llm as judge](llm-as-judge.md) with a narrow rubric.
4. **Iterate.** Fix the biggest failure mode, re-run, watch the numbers, go back to step 1 with fresh traces.

The flywheel matters more than any single metric. Generic scores like "helpfulness 1–10" tell you nothing; a metric born from your own failure taxonomy tells you exactly what to fix. How to turn failure modes into concrete test cases is covered in [designing evals](designing-evals.md).

## Why teams skip it, and the bill

Common excuses, all understandable, all expensive:

- "Outputs are subjective, you can't test them." You can. Subjective wholes decompose into objective parts.
- "We'll add evals after launch." After launch you are debugging in production with angry users as your graders.
- "Looking at data is grunt work." Reading traces is the highest-leverage hour an AI engineer spends. Nobody delegates their unit tests to hope.

The bill arrives as regression whack-a-mole: every fix is a gamble, model upgrades are terrifying, and velocity drops precisely when the product starts mattering. Teams with evals upgrade models the week they ship, because the suite tells them what broke.

Start small. Twenty real failures, one taxonomy, one metric. The flywheel does the rest. When your product is an agent rather than a single call, see [agent evals](agent-evals.md) for the extra machinery.
