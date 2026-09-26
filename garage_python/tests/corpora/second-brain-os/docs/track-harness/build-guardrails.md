# Build: Permissions and Context

[Part one](build-the-loop.md) left you with a demo: an agent that runs whatever it likes and grows its transcript without limit. This part adds the three things that make it a harness — a permission gate, a context budget, and a stop condition. The [anatomy page](what-a-harness-is.md) called these the parts that let you leave an agent unattended; here they cost about eighty lines.

Everything from part one — imports, `TOOLS`, `read_file`, `run_command` — stays as it was. Replace `execute` and `agent`, and add the rest.

## The code

```python
MAX_TURNS = 30
CONTEXT_BUDGET = 100_000  # characters, roughly 25k tokens

ALLOWLIST = ["ls", "pwd", "cat", "head", "grep", "find",
             "git status", "git diff", "git log", "python", "pytest"]


def permitted(command):
    command = command.strip()
    if any(command == entry or command.startswith(entry + " ") for entry in ALLOWLIST):
        return True
    answer = input(f"\nAgent wants to run: {command}\nAllow? [y/N] ")
    return answer.strip().lower() in ("y", "yes")


def execute(name, tool_input):
    if name == "read_file":
        return read_file(tool_input["path"])
    if name == "run_command":
        if not permitted(tool_input["command"]):
            return "The user declined to run this command. Try another approach or ask them why."
        return run_command(tool_input["command"])
    raise ValueError(f"unknown tool: {name}")


def size_of(message):
    content = message["content"]
    if isinstance(content, str):
        return len(content)
    return sum(len(json.dumps(b)) if isinstance(b, dict) else len(b.model_dump_json())
               for b in content)


def describe(message):
    content = message["content"]
    if isinstance(content, str):
        return content[:150]
    parts = []
    for block in content:
        if isinstance(block, dict):
            parts.append(f"tool output, {len(json.dumps(block))} chars")
        elif block.type == "text":
            parts.append(block.text[:150])
        elif block.type == "tool_use":
            parts.append(f"ran {block.name}({json.dumps(block.input)[:100]})")
    return "; ".join(parts) or "(empty turn)"


def enforce_budget(messages, summaries):
    while sum(size_of(m) for m in messages) > CONTEXT_BUDGET and len(messages) > 5:
        summaries.append(describe(messages.pop(1)))
        summaries.append(describe(messages.pop(1)))


def with_summary(messages, task, summaries):
    if not summaries:
        return messages
    header = (task + "\n\n[Older turns were removed to fit the context budget. "
              "Summary of what happened in them:\n- " + "\n- ".join(summaries) + "]")
    return [{"role": "user", "content": header}] + messages[1:]


def agent(task):
    client = anthropic.Anthropic()
    messages = [{"role": "user", "content": task}]
    summaries = []
    for turn in range(MAX_TURNS):
        enforce_budget(messages, summaries)
        response = client.messages.create(
            model=MODEL, max_tokens=8000, system=SYSTEM, tools=TOOLS,
            messages=with_summary(messages, task, summaries),
        )
        for block in response.content:
            if block.type == "text":
                print(block.text)
        if response.stop_reason != "tool_use":
            return
        messages.append({"role": "assistant", "content": response.content})
        results = []
        for block in response.content:
            if block.type != "tool_use":
                continue
            print(f"-> {block.name} {json.dumps(block.input)}")
            try:
                results.append({"type": "tool_result", "tool_use_id": block.id,
                                "content": execute(block.name, block.input)})
            except Exception as exc:
                results.append({"type": "tool_result", "tool_use_id": block.id,
                                "content": f"Error: {exc}", "is_error": True})
        messages.append({"role": "user", "content": results})
    print("Stopped: hit the turn limit without finishing.")
```

## The permission gate

Allowlisted read-only commands run silently; anything else asks you via `input()`. A declined command goes back as an ordinary tool result, not an exception — the model reads it as data and adapts. Note the honesty required here: prefix matching is leaky (`git diff; rm -rf ~` starts with `git diff `), which is why production harnesses parse commands properly and sandbox execution besides. The gate teaches the shape, not the security.

## The context budget

When the transcript exceeds the budget, the oldest turns after the task are dropped in pairs — assistant turn plus its tool results, so no `tool_use` block loses its match — and a one-line gist of each joins a running summary that rides in the first message. Crude, deliberately: tool output is bulky and rarely needed again, exactly the trade described in [context engineering](context-engineering.md).

## The stop condition

`MAX_TURNS` bounds the bill when the model loops on a task it cannot finish. Every real harness has this; every builder forgets it once.

You now have a harness in miniature. What it still lacks — and when that matters — is [part three](build-graduate.md).
