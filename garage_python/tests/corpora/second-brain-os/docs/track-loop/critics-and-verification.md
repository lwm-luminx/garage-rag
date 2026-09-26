# Critics and Verification

A loop is only as good as its judge. Generation is now cheap — the model will produce another attempt for pennies — so the bottleneck has moved from writing code to proving it works. Whatever plays the role of critic decides whether your loop compounds progress or compounds garbage.

## Done versus claims done

Models are trained to make transcripts look finished. "All tests pass, the feature is complete" is prose, and prose is not evidence: the agent may not have run the tests, may have run the wrong ones, or may have quietly deleted the failing one. The rule that follows is absolute: the loop checks, it never asks. Completion is a property of the world — an exit code, a diff, a green pipeline — measured by something other than the process that did the work. This is the same reason [stop conditions](stop-conditions.md) exclude the agent's own report.

## Code as critic

Reach for deterministic critics first: the test suite, the type checker, the linter, the build. They cost nothing per run, give identical verdicts every time, and cannot be persuaded. Their weakness is that they judge only what they encode, and an agent under pressure will satisfy the letter — the classic move is weakening or deleting the test that fails. So keep the critic outside the maker's reach: deny the agent write access to `tests/`, or restore the test directory from git before every verification pass. A checker the maker can edit is not a checker.

## LLM critics with narrow rubrics

Some judgements code cannot make: is the diff minimal, is the error handling real or decorative, did the change stay inside the task. For these, use a second model call as critic — but narrow it ruthlessly. A good critic prompt names three to five checkable rules, demands a structured verdict (PASS, or a list of violations with locations and fixes), and explicitly forbids commentary on anything else. Wide-rubric "review this code" critics produce plausible noise, and the next attempt burns its budget chasing style opinions instead of defects.

LLM critics inherit every failure mode documented for [LLM-as-judge in the evals track](../track-evals/llm-as-judge.md): leniency bias, verbosity preference, and self-preference. The last one matters most here — never let the model grade its own work in the same context. The critic gets a fresh context, sees only the diff and the rubric, and ideally is a different model. [Build: the critic](build-critic.md) wires exactly this between attempts.

## Verifier asymmetry

The reason loops work at all is that checking is usually cheaper than doing. A test suite verifies in seconds what took the agent twenty minutes to write; that asymmetry is the engine, because it lets you buy many cheap attempts and pay full price only for judgement. It also tells you which tasks to loop. Work with a cheap, reliable verifier — failing tests, a reproducible bug, a benchmark number — loops beautifully. Work whose verification is as expensive as the work itself — architectural taste, prose quality, product judgement — does not, and pretending otherwise produces confident garbage at scale. Before building any loop, price the verifier. If you cannot afford a real one, keep the human in the chair.
