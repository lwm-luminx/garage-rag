# Build: the Loop

The [anatomy page](what-a-harness-is.md) claims the core of every harness is a while-loop. This page proves it. In roughly seventy lines of Python you get an agent that reads files and runs commands against the live Claude API; the [next part](build-guardrails.md) adds the machinery that makes it a harness. Budget an evening for all three pages, about 150 lines total.

You need Python 3.10+, `pip install anthropic` (the 1.x SDK), and `ANTHROPIC_API_KEY` set in your environment.

## Two tools

Tools are JSON schemas plus functions. The descriptions matter as much as the code — the model chooses by reading them, a point [tools and MCP](tools-and-mcp.md) makes at length.

## The code

```python
import json
import subprocess
import sys

import anthropic

MODEL = "claude-opus-5"
SYSTEM = "You are a coding agent working in the current directory. Investigate before you conclude."

TOOLS = [
    {
        "name": "read_file",
        "description": "Read a text file and return its full contents. Use for source files, configs and logs. Paths are relative to the working directory.",
        "input_schema": {
            "type": "object",
            "properties": {"path": {"type": "string", "description": "File path, e.g. src/main.py"}},
            "required": ["path"],
        },
    },
    {
        "name": "run_command",
        "description": "Run a shell command and return its exit code, stdout and stderr. Use for listing files, searching and running tests. Times out after 30 seconds.",
        "input_schema": {
            "type": "object",
            "properties": {"command": {"type": "string", "description": "The command, e.g. ls -la"}},
            "required": ["command"],
        },
    },
]


def read_file(path):
    with open(path, "r", encoding="utf-8") as f:
        return f.read()


def run_command(command):
    result = subprocess.run(command, shell=True, capture_output=True, text=True, timeout=30)
    return f"exit code {result.returncode}\n{result.stdout}{result.stderr}"


def execute(name, tool_input):
    if name == "read_file":
        return read_file(tool_input["path"])
    if name == "run_command":
        return run_command(tool_input["command"])
    raise ValueError(f"unknown tool: {name}")


def agent(task):
    client = anthropic.Anthropic()
    messages = [{"role": "user", "content": task}]
    while True:
        response = client.messages.create(
            model=MODEL, max_tokens=8000, system=SYSTEM, tools=TOOLS, messages=messages
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


if __name__ == "__main__":
    agent(" ".join(sys.argv[1:]) or "List the files here and describe this project.")
```

## What each part is doing

The API signals its intent through `stop_reason`. While it says `tool_use`, the response contains `tool_use` blocks — each with an `id`, a `name` and a parsed `input` dict. You append the assistant's entire `response.content` back unchanged (current models include thinking blocks that must travel with it), execute every tool call, and return all results as `tool_result` blocks in a single user message, matched by `tool_use_id`. Failures go back too, flagged with `is_error` — a good error message lets the model recover in one turn instead of guessing.

Save it as `agent.py`, run `python agent.py "find the TODO comments in this repo and summarise them"`, and watch the loop go round. Thorsten Ball's tutorial in [resources](resources.md) does the same in Go; seeing it in your own terminal is the point.

## What it is not, yet

This is a demo. It will run any command the model fancies, and a long task will grow the transcript without limit. Fixing those two things — permissions and context — is [part two](build-guardrails.md).
