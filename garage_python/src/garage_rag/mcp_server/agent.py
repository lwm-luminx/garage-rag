"""``rag_agent``: the local model answers a question with the corpus tools in hand.

``rag_ask`` retrieves once and hands the model the excerpts. This module lets the
model drive: it sees the read-only corpus tools the server itself serves
(``rag_search``, ``rag_get_document``, ``rag_list_sources``, ``rag_list_authors``,
``rag_stats``), asks for the ones it wants, reads the results and answers when it
has enough. The menu bar's "Ask Garage" runs it; so can any MCP client.

Tool calls travel as JSON in the conversation rather than as the OpenAI ``tools``
field, because the app's llama engine renders the model's chat template from
role/content pairs alone and small local models are steadier with one explicit
format than with a template's own calling convention. The model replies with one
object, ``{"tool": "rag_search", "arguments": {...}}``, and gets the tool's result
back as the next user turn; a reply that is not a tool call is the answer. The
same loop therefore works against Ollama and LM Studio unchanged.

Small models (gemma2-2b among them) tend to read a question about the user's own life
("when did I last talk to BMW?") as one about their training and answer that they
have no access to personal information, without calling a tool. So by default the
loop searches before the model says anything: the question goes to ``rag_search``
and the model's first turn opens on those hits, shown as a call it already made.
That call doubles as a worked example of the format, and the model can still
search again or open a document before it answers.

The content rule holds here as everywhere: when the model host is not loopback,
``rag_search`` is restricted to documents and code and ``rag_get_document`` refuses
a communication, so no message or mail reaches an off-box model.
"""

from __future__ import annotations

import dataclasses
import json
import logging
import re
from collections.abc import Callable, Mapping
from dataclasses import dataclass, field
from typing import Any

from garage_rag.enrich.generation import ChatReply, LocalChatModel
from garage_rag.net import egress

log = logging.getLogger("garage_rag.mcp.agent")

# The tools the model may call: the ones that only read the corpus. The generating
# tools stay out (an agent calling rag_ask would run a second model inside the first).
AGENT_TOOL_NAMES = ("rag_search", "rag_get_document", "rag_list_sources", "rag_list_authors", "rag_stats")

# A tool result is trimmed to this many characters before it goes back to the model.
TOOL_RESULT_CHARS = 6000
# Each rag_search hit's text is trimmed to this many characters in the tool result.
HIT_TEXT_CHARS = 700
# Citations carry a shorter snippet, as rag_ask's do.
SNIPPET_CHARS = 240
DEFAULT_MAX_STEPS = 6
# Hits the opening search asks for, before the model has said anything.
FIRST_SEARCH_LIMIT = 6

# What rag_search may return when the model host is off this machine.
_LOCAL_ONLY_CLASSES = ("document", "code")

AGENT_SYSTEM_PROMPT = """\
You are Garage, a private assistant running on the user's own computer. The user has \
indexed their own files, code, notes, mail and messages into a personal corpus, and you \
have full access to it through the tools below. When the user says "I", "me" or "my", \
they mean themselves, and the answer is in their corpus: a question about who they \
talked to, what they wrote, when something happened or what they decided is a question \
for the tools. Never say you have no access to personal information or past \
conversations; you do, through the tools. Nothing about the corpus is known to you \
except what the tools return.
{owner}
Work in steps. To use a tool, reply with exactly one JSON object and nothing else:
{{"tool": "<name>", "arguments": {{...}}}}
You will get the tool's result as the next message. Search first; open a document with \
rag_get_document only when a search excerpt is not enough. If a search finds nothing \
useful, try once more with different keywords (a name, a company, a subject). Use at \
most a few tool calls.

When you have what you need, reply with the answer in plain prose (no JSON). Name the \
documents you relied on by their title or location. If the corpus does not contain the \
answer, say that you found nothing about it in their files instead of guessing.

Tools (arguments in parentheses; ? marks an optional one):
{tools}

Which tool to use:
- Anything about the user's life, work, people, mail or files: rag_search.
- Talking, writing or meeting with someone ("when did I last talk to BMW?"): rag_search \
with corpus_class "communication", for example
  {{"tool": "rag_search", "arguments": {{"query": "BMW", "corpus_class": "communication"}}}}
- What the user wrote, thought or decided: rag_search with trust "authored".
- Documents by one person: rag_search with author set to their name; rag_list_authors lists the names.
- The whole document behind a hit: rag_get_document with the hit's document_id.
- What is indexed, and how much: rag_list_sources or rag_stats.

Each rag_search hit has document_id, title, location (the file path), corpus_class, \
trust_tier, authors and text (an excerpt). Hits carry no date: a date is known only \
when it appears in the text, the title or the location.
"""

# Arguments the model is not shown: it gains nothing from choosing them. They are still
# accepted, and validated, when a model passes one anyway.
_HIDDEN_ARGUMENTS = {"rag_search": frozenset({"mode"}), "rag_get_document": frozenset({"max_chars"})}

NO_ANSWER_TEXT = "The model kept asking for tools instead of answering. Try a more specific question."

FINAL_ANSWER_PROMPT = (
    "No more tool calls are available. Answer the question now in plain prose from what the "
    "tool results so far contain, and say plainly if they do not contain the answer."
)


# ---------------------------------------------------------------------------
# result types
# ---------------------------------------------------------------------------
@dataclass
class AgentStep:
    """One tool the model called on its way to the answer."""

    n: int
    tool: str
    arguments: dict[str, Any]
    summary: str
    ok: bool = True


@dataclass
class AgentCitation:
    """One document the model saw while answering."""

    n: int
    document_id: int
    title: str | None
    location: str
    snippet: str
    corpus_class: str


@dataclass
class AgentResult:
    answer: str
    model: str
    provider: str
    question: str
    steps: list[AgentStep] = field(default_factory=list)
    citations: list[AgentCitation] = field(default_factory=list)
    prompt_tokens: int | None = None
    completion_tokens: int | None = None


# ---------------------------------------------------------------------------
# the tools as the model sees them
# ---------------------------------------------------------------------------
@dataclass(frozen=True)
class AgentTool:
    """A tool the agent may call: its schema for the prompt, and how to run it."""

    name: str
    description: str
    parameters: Mapping[str, Any]
    run: Callable[[dict[str, Any]], Any]


def tools_from_server(server: Any, names: tuple[str, ...] = AGENT_TOOL_NAMES) -> list[AgentTool]:
    """The agent's tools, taken from the ``MCPServer`` that registered them.

    Each call validates its arguments against the tool's own input schema, exactly as
    an MCP ``tools/call`` would, then runs the plain function: this runs on the
    tool worker thread already, so there is no event loop to hand it to.
    """
    by_name = {tool.name: tool for tool in server._tool_manager.list_tools()}
    tools: list[AgentTool] = []
    for name in names:
        tool = by_name.get(name)
        if tool is None:
            continue

        def run(arguments: dict[str, Any], tool: Any = tool) -> Any:
            validated = tool.fn_metadata.validate_arguments(arguments)
            return tool.fn(**validated)

        tools.append(
            AgentTool(
                name=tool.name,
                description=" ".join((tool.description or "").split()),
                parameters=_schema_for_prompt(tool.parameters),
                run=run,
            )
        )
    return tools


def _schema_for_prompt(schema: Mapping[str, Any]) -> dict[str, Any]:
    """The input schema with the noise a model does not need taken out: titles and
    the ``anyOf`` wrappers pydantic writes for ``X | None``."""
    properties = {}
    for name, spec in (schema.get("properties") or {}).items():
        properties[name] = _simplify_property(spec)
    out: dict[str, Any] = {"type": "object", "properties": properties}
    if schema.get("required"):
        out["required"] = list(schema["required"])
    return out


def _simplify_property(spec: Mapping[str, Any]) -> dict[str, Any]:
    out: dict[str, Any] = {}
    options = spec.get("anyOf")
    if isinstance(options, list):
        kept = [o for o in options if o.get("type") != "null"]
        if len(kept) == 1:
            merged = dict(kept[0])
            merged.update({k: v for k, v in spec.items() if k not in ("anyOf", "title")})
            return _simplify_property(merged)
        out["anyOf"] = [_simplify_property(o) for o in kept]
    for key in ("type", "description", "enum", "default", "minimum", "maximum", "items"):
        if key in spec:
            value = spec[key]
            if key == "default" and value is None:
                continue
            out[key] = _simplify_property(value) if key == "items" and isinstance(value, Mapping) else value
    return out


def describe_tools(tools: list[AgentTool]) -> str:
    """The tool section of the system prompt: one line per tool, its arguments and what it does.

    Small models follow a short signature far better than a JSON schema, so each argument
    is its name, its allowed values when it has an enum and ``?`` when it is optional,
    and the description is the tool's first sentence.
    """
    return "\n".join(f"- {tool.name}({_signature(tool)}): {_first_sentence(tool.description)}" for tool in tools)


def _signature(tool: AgentTool) -> str:
    hidden = _HIDDEN_ARGUMENTS.get(tool.name, frozenset())
    required = set(tool.parameters.get("required") or ())
    parts = []
    for name, spec in (tool.parameters.get("properties") or {}).items():
        if name in hidden:
            continue
        values = _enum_values(spec)
        part = f"{name}{'' if name in required else '?'}"
        if values:
            part += ": " + " | ".join(f'"{v}"' for v in values)
        parts.append(part)
    return ", ".join(parts)


def _enum_values(spec: Mapping[str, Any]) -> list[Any]:
    """The allowed values of an argument, through the list-or-scalar ``anyOf`` the filters use."""
    if "enum" in spec:
        return list(spec["enum"])
    for option in spec.get("anyOf") or []:
        values = _enum_values(option.get("items") or option)
        if values:
            return values
    return []


def _first_sentence(text: str) -> str:
    match = re.match(r"(.+?[.!?])(\s|$)", text)
    return match.group(1) if match else text


def build_agent_messages(question: str, tools: list[AgentTool], *, owner: str = "") -> list[dict[str, str]]:
    """The opening messages: the system prompt with the tools, then the question.

    ``owner`` is the corpus owner's name (``identity.self_name``), so the model can tie
    "I" to an author and to the ``authored`` tier.
    """
    owner_line = (
        f'The user is {owner}; "authored" documents and the author {owner} are theirs.\n' if owner.strip() else ""
    )
    return [
        {
            "role": "system",
            "content": AGENT_SYSTEM_PROMPT.format(tools=describe_tools(tools), owner=owner_line),
        },
        {"role": "user", "content": f"Question: {question}"},
    ]


# ---------------------------------------------------------------------------
# reading the model's replies
# ---------------------------------------------------------------------------
_FENCE = re.compile(r"```(?:json)?\s*(.*?)```", re.DOTALL)


def parse_tool_call(text: str) -> tuple[str, dict[str, Any]] | None:
    """The tool call in a reply, or None when the reply is an answer.

    Accepts the bare object, one in a code fence, or one with a little prose around
    it, as small models tend to add. Anything without a string ``tool`` key is prose.
    """
    candidates = [text.strip()]
    candidates += [m.group(1).strip() for m in _FENCE.finditer(text)]
    start = text.find("{")
    end = text.rfind("}")
    if start != -1 and end > start:
        candidates.append(text[start : end + 1])
    for candidate in candidates:
        if not candidate.startswith("{"):
            continue
        try:
            obj = json.loads(candidate)
        except ValueError:
            continue
        if not isinstance(obj, dict):
            continue
        name = obj.get("tool") or obj.get("name")
        if not isinstance(name, str) or not name:
            continue
        arguments = obj.get("arguments", obj.get("parameters", obj.get("input", {})))
        if arguments is None:
            arguments = {}
        if not isinstance(arguments, dict):
            continue
        return name, arguments
    return None


# ---------------------------------------------------------------------------
# tool results, as the model and the caller see them
# ---------------------------------------------------------------------------
def _plain(value: Any) -> Any:
    if dataclasses.is_dataclass(value) and not isinstance(value, type):
        return {k: _plain(v) for k, v in dataclasses.asdict(value).items()}
    if isinstance(value, dict):
        return {k: _plain(v) for k, v in value.items()}
    if isinstance(value, list | tuple):
        return [_plain(v) for v in value]
    return value


def _trim(text: str, limit: int) -> str:
    text = " ".join(str(text).split())
    return text if len(text) <= limit else text[: limit - 1].rstrip() + "…"


def render_tool_result(tool: str, result: Any, *, limit: int = TOOL_RESULT_CHARS) -> str:
    """The result as compact JSON, with long texts shortened so it fits the context."""
    data = _plain(result)
    if tool == "rag_search" and isinstance(data, dict):
        for hit in data.get("hits") or []:
            if not isinstance(hit, dict):
                continue
            if isinstance(hit.get("text"), str):
                hit["text"] = _trim(hit["text"], HIT_TEXT_CHARS)
            for key in ("chunk_id", "matched_by", "score"):
                hit.pop(key, None)
    text = json.dumps(data, ensure_ascii=False, separators=(",", ":"), default=str)
    if len(text) > limit:
        text = text[: limit - 1] + "…"
    return text


def summarize_step(tool: str, arguments: Mapping[str, Any], result: Any) -> str:
    """One line for the caller's step list: what was asked and how much came back."""
    data = _plain(result)
    if tool == "rag_search":
        count = data.get("count") if isinstance(data, dict) else None
        return f"Searched for “{arguments.get('query', '')}”: {count if count is not None else '?'} hits"
    if tool == "rag_get_document":
        title = data.get("title") if isinstance(data, dict) else None
        where = title or arguments.get("location") or f"document {arguments.get('document_id')}"
        return f"Read {where}"
    if tool == "rag_list_sources":
        return f"Listed {data.get('count', '?') if isinstance(data, dict) else '?'} sources"
    if tool == "rag_list_authors":
        return f"Listed {data.get('count', '?') if isinstance(data, dict) else '?'} authors"
    if tool == "rag_stats":
        return "Read the corpus statistics"
    return f"Called {tool}"


def _collect_citations(tool: str, result: Any, citations: list[AgentCitation], seen: set[int]) -> None:
    data = _plain(result)
    if tool == "rag_search" and isinstance(data, dict):
        rows = [h for h in data.get("hits") or [] if isinstance(h, dict)]
    elif tool == "rag_get_document" and isinstance(data, dict):
        rows = [dict(data, text=data.get("content", ""))]
    else:
        return
    for row in rows:
        document_id = row.get("document_id")
        if not isinstance(document_id, int) or document_id in seen:
            continue
        seen.add(document_id)
        citations.append(
            AgentCitation(
                n=len(citations) + 1,
                document_id=document_id,
                title=row.get("title"),
                location=str(row.get("location", "")),
                snippet=_trim(row.get("text") or "", SNIPPET_CHARS),
                corpus_class=str(row.get("corpus_class", "")),
            )
        )


# ---------------------------------------------------------------------------
# the content rule
# ---------------------------------------------------------------------------
def restrict_for_host(tool: str, arguments: dict[str, Any], *, communications_allowed: bool) -> dict[str, Any]:
    """The arguments to run with: a search from an off-box model host never asks for communications."""
    if communications_allowed or tool != "rag_search":
        return arguments
    requested = arguments.get("corpus_class")
    if isinstance(requested, str):
        requested = [requested]
    if isinstance(requested, list):
        kept = [c for c in requested if c in _LOCAL_ONLY_CLASSES]
        classes = kept or list(_LOCAL_ONLY_CLASSES)
    else:
        classes = list(_LOCAL_ONLY_CLASSES)
    return {**arguments, "corpus_class": classes}


def result_allowed_for_host(tool: str, result: Any, *, communications_allowed: bool) -> bool:
    """Whether a result may go to the model host: a communication only to a loopback one."""
    if communications_allowed:
        return True
    data = _plain(result)
    if tool == "rag_get_document" and isinstance(data, dict):
        return data.get("corpus_class") != "communication"
    if tool == "rag_search" and isinstance(data, dict):
        return all(
            not (isinstance(h, dict) and h.get("corpus_class") == "communication") for h in data.get("hits") or []
        )
    return True


# ---------------------------------------------------------------------------
# the loop
# ---------------------------------------------------------------------------
def run_agent(
    question: str,
    tools: list[AgentTool],
    model: LocalChatModel,
    *,
    max_steps: int = DEFAULT_MAX_STEPS,
    max_tokens: int | None = None,
    temperature: float | None = None,
    search_first: bool = True,
    owner: str = "",
) -> AgentResult:
    """Ask ``model`` the question with ``tools`` to call, and return its answer.

    A step is one model reply. A reply that names a tool runs it (an unknown tool or bad
    arguments go back to the model as an error it can correct); after ``max_steps`` tool
    calls the model is told to answer with what it has. Token counts are summed over
    every reply.

    With ``search_first`` (the default) the question goes to ``rag_search`` before the
    model's first reply, so a model that would otherwise answer from its training
    starts from the user's own documents. It is recorded as the first step.
    """
    communications_allowed = egress.allows_communications(model.host)
    by_name = {tool.name: tool for tool in tools}
    messages = build_agent_messages(question, tools, owner=owner)
    steps: list[AgentStep] = []
    citations: list[AgentCitation] = []
    seen_documents: set[int] = set()
    prompt_tokens = 0
    completion_tokens = 0
    counted = False

    def ask() -> ChatReply:
        nonlocal prompt_tokens, completion_tokens, counted
        reply = model.complete(messages, max_tokens=max_tokens, temperature=temperature)
        if reply.prompt_tokens is not None or reply.completion_tokens is not None:
            counted = True
            prompt_tokens += reply.prompt_tokens or 0
            completion_tokens += reply.completion_tokens or 0
        return reply

    def call_tool(name: str, arguments: dict[str, Any]) -> None:
        """Run one tool call and append it, and its result or error, to the conversation."""
        messages.append({"role": "assistant", "content": json.dumps({"tool": name, "arguments": arguments})})
        tool = by_name.get(name)
        if tool is None:
            steps.append(
                AgentStep(n=len(steps) + 1, tool=name, arguments=arguments, summary=f"No such tool: {name}", ok=False)
            )
            messages.append(
                {
                    "role": "user",
                    "content": f"Error: there is no tool named {name!r}. The tools are: {', '.join(by_name)}.",
                }
            )
            return
        to_run = restrict_for_host(name, arguments, communications_allowed=communications_allowed)
        if name == "rag_get_document":
            # Ask for no more text than fits in the result, so its ``truncated`` flag tells the truth.
            to_run = {"max_chars": TOOL_RESULT_CHARS, **to_run}
        try:
            result = tool.run(to_run)
        except Exception as exc:  # the model's mistake to read and correct, or a corpus error to report
            log.info("rag_agent: %s(%s) failed: %s", name, to_run, exc)
            steps.append(
                AgentStep(n=len(steps) + 1, tool=name, arguments=arguments, summary=f"{name} failed: {exc}", ok=False)
            )
            messages.append({"role": "user", "content": f"Error from {name}: {_trim(str(exc), 600)}"})
            return
        if not result_allowed_for_host(name, result, communications_allowed=communications_allowed):
            steps.append(
                AgentStep(
                    n=len(steps) + 1,
                    tool=name,
                    arguments=arguments,
                    summary=f"{name}: a communication stays on this machine",
                    ok=False,
                )
            )
            messages.append(
                {
                    "role": "user",
                    "content": (
                        f"Error from {name}: that is a communication, "
                        "which is only available to a model on this machine."
                    ),
                }
            )
            return
        steps.append(
            AgentStep(n=len(steps) + 1, tool=name, arguments=arguments, summary=summarize_step(name, arguments, result))
        )
        _collect_citations(name, result, citations, seen_documents)
        messages.append({"role": "user", "content": f"Result of {name}:\n{render_tool_result(name, result)}"})

    # The opening search is the harness's, not the model's, so it does not count against max_steps.
    if search_first and "rag_search" in by_name:
        call_tool("rag_search", {"query": question, "limit": FIRST_SEARCH_LIMIT})

    answer: str | None = None
    for _ in range(max_steps):
        reply = ask()
        call = parse_tool_call(reply.text)
        if call is None:
            answer = reply.text
            break
        call_tool(*call)

    if answer is None:
        messages.append({"role": "user", "content": FINAL_ANSWER_PROMPT})
        reply = ask()
        answer = reply.text
        if parse_tool_call(answer) is not None:
            answer = NO_ANSWER_TEXT

    return AgentResult(
        answer=answer.strip(),
        model=model.model_ref,
        provider=model.provider,
        question=question,
        steps=steps,
        citations=citations,
        prompt_tokens=prompt_tokens if counted else None,
        completion_tokens=completion_tokens if counted else None,
    )
