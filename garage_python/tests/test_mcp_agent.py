"""rag_agent: the tool-calling loop behind the menu bar's "Ask Garage"."""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from unittest.mock import MagicMock, patch

import pytest

from garage_rag.enrich.generation import ChatReply
from garage_rag.mcp_server import agent
from garage_rag.mcp_server.agent import (
    AGENT_TOOL_NAMES,
    FINAL_ANSWER_PROMPT,
    NO_ANSWER_TEXT,
    AgentResult,
    AgentTool,
    build_agent_messages,
    describe_tools,
    parse_tool_call,
    render_tool_result,
    restrict_for_host,
    result_allowed_for_host,
    run_agent,
    summarize_step,
    tools_from_server,
)
from garage_rag.mcp_server.server import Hit, SearchResult, mcp, rag_agent

# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------


@dataclass
class FakeDocument:
    document_id: int = 10
    location: str = "~/docs/guide.md"
    title: str | None = "User Guide"
    corpus_class: str = "document"
    trust_tier: str = "authored"
    authors: list[str] = field(default_factory=lambda: ["Rick Mark"])
    extractor: str = "text"
    byte_size: int | None = 100
    chunk_count: int = 2
    truncated: bool = False
    content: str = "Widgets ship on Tuesdays."


def _hit(
    document_id: int = 10,
    corpus_class: str = "document",
    text: str = "Widgets ship on Tuesdays.",
    direction: str | None = None,
    sender: str | None = None,
) -> Hit:
    return Hit(
        chunk_id=document_id * 100,
        document_id=document_id,
        location=f"~/docs/{document_id}.md",
        title=f"Doc {document_id}",
        corpus_class=corpus_class,
        trust_tier="authored",
        section=None,
        authors=["Rick Mark"],
        matched_by="hybrid",
        score=0.5,
        text=text,
        direction=direction,
        sender=sender,
    )


def _search_result(*hits: Hit, query: str = "widgets") -> SearchResult:
    return SearchResult(query=query, mode="hybrid", model="bge-m3", count=len(hits), hits=list(hits))


def _model(replies: list[str], *, host: str = "http://127.0.0.1:8790", tokens: bool = True) -> MagicMock:
    model = MagicMock()
    model.provider = "llama_xpc"
    model.model_ref = "gemma2-2b"
    model.host = host
    model.complete.side_effect = [
        ChatReply(text=text, prompt_tokens=100 if tokens else None, completion_tokens=10 if tokens else None)
        for text in replies
    ]
    return model


def _tools(search=None, document=None) -> tuple[list[AgentTool], dict[str, MagicMock]]:
    runners = {
        "rag_search": MagicMock(side_effect=search or (lambda args: _search_result(_hit(), query=args["query"]))),
        "rag_get_document": MagicMock(side_effect=document or (lambda args: FakeDocument())),
        "rag_stats": MagicMock(return_value={"documents": 3}),
    }
    tools = [
        AgentTool(
            name=name,
            description=f"{name} does things",
            parameters={"type": "object", "properties": {}},
            run=runner,
        )
        for name, runner in runners.items()
    ]
    return tools, runners


def _call(tool: str, **arguments) -> str:
    return json.dumps({"tool": tool, "arguments": arguments})


# ---------------------------------------------------------------------------
# reading the model's replies
# ---------------------------------------------------------------------------
class TestParseToolCall:
    def test_bare_object(self) -> None:
        assert parse_tool_call('{"tool": "rag_search", "arguments": {"query": "x"}}') == ("rag_search", {"query": "x"})

    def test_code_fence(self) -> None:
        text = 'Sure.\n```json\n{"tool": "rag_stats", "arguments": {}}\n```'
        assert parse_tool_call(text) == ("rag_stats", {})

    def test_prose_around_the_object(self) -> None:
        text = 'I will search: {"tool": "rag_search", "arguments": {"query": "boot"}} and then answer.'
        assert parse_tool_call(text) == ("rag_search", {"query": "boot"})

    def test_missing_arguments_means_none(self) -> None:
        assert parse_tool_call('{"tool": "rag_stats"}') == ("rag_stats", {})
        assert parse_tool_call('{"tool": "rag_stats", "arguments": null}') == ("rag_stats", {})

    def test_alternative_keys(self) -> None:
        assert parse_tool_call('{"name": "rag_search", "parameters": {"query": "x"}}') == ("rag_search", {"query": "x"})

    @pytest.mark.parametrize(
        "text",
        [
            "Widgets ship on Tuesdays.",
            "The answer is {not json}.",
            '{"answer": "Tuesdays"}',
            '{"tool": 3}',
            '{"tool": "rag_search", "arguments": "boot"}',
            "",
        ],
    )
    def test_prose_is_not_a_call(self, text: str) -> None:
        assert parse_tool_call(text) is None


# ---------------------------------------------------------------------------
# the prompt
# ---------------------------------------------------------------------------
class TestPrompt:
    def test_tools_from_server_are_the_read_only_ones(self) -> None:
        tools = tools_from_server(mcp)
        assert [t.name for t in tools] == list(AGENT_TOOL_NAMES)
        assert "rag_ask" not in {t.name for t in tools}
        assert "rag_agent" not in {t.name for t in tools}

    def test_schema_is_simplified_for_the_prompt(self) -> None:
        search = next(t for t in tools_from_server(mcp) if t.name == "rag_search")
        props = search.parameters["properties"]
        assert search.parameters["required"] == ["query"]
        assert props["query"] == {
            "type": "string",
            "description": "Natural-language question or keywords to search for.",
        }
        assert "title" not in props["limit"]
        assert props["limit"]["default"] == 10
        # X | None loses the null branch and the null default.
        assert "default" not in props["author"]
        assert props["author"]["type"] == "string"
        # list[Literal] | Literal keeps both shapes, without the null.
        assert {o["type"] for o in props["trust"]["anyOf"]} == {"array", "string"}

    def test_messages_open_with_the_tools_and_end_with_the_question(self) -> None:
        tools, _ = _tools()
        messages = build_agent_messages("when do widgets ship?", tools)
        assert [m["role"] for m in messages] == ["system", "user"]
        assert describe_tools(tools) in messages[0]["content"]
        assert '{"tool": "<name>", "arguments": {...}}' in messages[0]["content"]
        assert messages[1]["content"] == "Question: when do widgets ship?"

    def test_describe_tools_is_one_line_per_tool(self) -> None:
        tools, _ = _tools()
        text = describe_tools(tools)
        assert text.splitlines() == [
            "- rag_search(): rag_search does things",
            "- rag_get_document(): rag_get_document does things",
            "- rag_stats(): rag_stats does things",
        ]

    def test_server_tools_read_as_signatures(self) -> None:
        lines = describe_tools(tools_from_server(mcp)).splitlines()
        search = next(line for line in lines if line.startswith("- rag_search("))
        # Required arguments are bare, optional ones carry ?, enums (through list-or-scalar) are spelled out.
        assert search.startswith('- rag_search(query, limit?, corpus_class?: "document" | "code" | "communication", ')
        assert 'trust?: "authored" | "reference" | "received"' in search
        # The search mode and the document length are the agent's to choose, not the model's.
        assert "mode" not in search
        document = next(line for line in lines if line.startswith("- rag_get_document("))
        assert document.startswith("- rag_get_document(document_id?, location?): ")
        # Only the first sentence of each description: rag_stats' "useful before searching" is left out.
        stats = next(line for line in lines if line.startswith("- rag_stats("))
        assert stats == "- rag_stats(): Summarize corpus size, composition, and embedding coverage."
        # No JSON schema in the prompt.
        assert '"properties"' not in "\n".join(lines)

    def test_owner_is_named_when_configured(self) -> None:
        tools, _ = _tools()
        system = build_agent_messages("q", tools, owner="Rick Mark")[0]["content"]
        assert 'The user is Rick Mark; "authored" documents and the author Rick Mark are theirs.' in system
        assert "The user is" not in build_agent_messages("q", tools)[0]["content"]
        assert "The user is" not in build_agent_messages("q", tools, owner="  ")[0]["content"]

    def test_prompt_maps_questions_to_filters(self) -> None:
        tools, _ = _tools()
        system = build_agent_messages("q", tools)[0]["content"]
        assert '{"tool": "rag_search", "arguments": {"query": "BMW", "corpus_class": "communication"}}' in system
        assert "Hits carry no date" in system


# ---------------------------------------------------------------------------
# tool results
# ---------------------------------------------------------------------------
class TestToolResults:
    def test_search_result_is_compact_json_without_scores(self) -> None:
        text = render_tool_result("rag_search", _search_result(_hit(text="long " * 500)))
        data = json.loads(text)
        hit = data["hits"][0]
        assert set(hit) == {
            "document_id",
            "location",
            "title",
            "corpus_class",
            "trust_tier",
            "section",
            "authors",
            "text",
        }
        assert len(hit["text"]) <= agent.HIT_TEXT_CHARS
        assert hit["text"].endswith("…")

    def test_search_result_keeps_direction_and_sender_of_a_message(self) -> None:
        text = render_tool_result("rag_search", _search_result(_hit(direction="sent", sender="me")))
        hit = json.loads(text)["hits"][0]
        assert (hit["direction"], hit["sender"]) == ("sent", "me")

    def test_long_results_are_cut(self) -> None:
        text = render_tool_result("rag_get_document", FakeDocument(content="x" * 10_000), limit=100)
        assert len(text) == 100
        assert text.endswith("…")

    def test_step_summaries(self) -> None:
        assert (
            summarize_step("rag_search", {"query": "boot"}, _search_result(_hit(), _hit(11)))
            == "Searched for “boot”: 2 hits"
        )
        assert summarize_step("rag_get_document", {"document_id": 10}, FakeDocument()) == "Read User Guide"
        assert summarize_step("rag_get_document", {"location": "~/x.md"}, FakeDocument(title=None)) == "Read ~/x.md"
        assert summarize_step("rag_stats", {}, {"documents": 3}) == "Read the corpus statistics"
        assert summarize_step("rag_list_sources", {}, {"count": 2, "sources": []}) == "Listed 2 sources"
        assert summarize_step("other", {}, None) == "Called other"


# ---------------------------------------------------------------------------
# the content rule
# ---------------------------------------------------------------------------
class TestContentRule:
    def test_loopback_host_changes_nothing(self) -> None:
        args = {"query": "x", "corpus_class": "communication"}
        assert restrict_for_host("rag_search", args, communications_allowed=True) == args
        doc = FakeDocument(corpus_class="communication")
        assert result_allowed_for_host("rag_get_document", doc, communications_allowed=True)

    def test_off_box_search_is_restricted_to_documents_and_code(self) -> None:
        assert restrict_for_host("rag_search", {"query": "x"}, communications_allowed=False) == {
            "query": "x",
            "corpus_class": ["document", "code"],
        }
        assert restrict_for_host(
            "rag_search", {"query": "x", "corpus_class": "code"}, communications_allowed=False
        ) == {
            "query": "x",
            "corpus_class": ["code"],
        }
        assert restrict_for_host(
            "rag_search", {"query": "x", "corpus_class": ["communication"]}, communications_allowed=False
        ) == {"query": "x", "corpus_class": ["document", "code"]}
        # Other tools carry no content and are left alone.
        assert restrict_for_host("rag_stats", {}, communications_allowed=False) == {}

    def test_off_box_refuses_a_communication(self) -> None:
        assert not result_allowed_for_host(
            "rag_get_document", FakeDocument(corpus_class="communication"), communications_allowed=False
        )
        assert result_allowed_for_host("rag_get_document", FakeDocument(), communications_allowed=False)
        assert not result_allowed_for_host(
            "rag_search", _search_result(_hit(), _hit(11, corpus_class="communication")), communications_allowed=False
        )
        assert result_allowed_for_host("rag_stats", {"documents": 1}, communications_allowed=False)


# ---------------------------------------------------------------------------
# the loop
# ---------------------------------------------------------------------------
class TestRunAgent:
    def test_search_then_answer(self) -> None:
        tools, runners = _tools()
        model = _model([_call("rag_search", query="widgets", limit=3), "Widgets ship on Tuesdays (User Guide)."])

        result = run_agent("when do widgets ship?", tools, model, search_first=False, max_tokens=200, temperature=0.1)

        assert isinstance(result, AgentResult)
        assert result.answer == "Widgets ship on Tuesdays (User Guide)."
        assert result.model == "gemma2-2b"
        assert result.provider == "llama_xpc"
        assert result.question == "when do widgets ship?"
        runners["rag_search"].assert_called_once_with({"query": "widgets", "limit": 3})
        assert [(s.n, s.tool, s.ok, s.summary) for s in result.steps] == [
            (1, "rag_search", True, "Searched for “widgets”: 1 hits")
        ]
        assert result.steps[0].arguments == {"query": "widgets", "limit": 3}
        assert [(c.n, c.document_id, c.title, c.location) for c in result.citations] == [
            (1, 10, "Doc 10", "~/docs/10.md")
        ]
        assert result.prompt_tokens == 200
        assert result.completion_tokens == 20

        # The conversation the model saw: system, question, its call, the result, then it answered.
        assert model.complete.call_count == 2
        messages = model.complete.call_args_list[1].args[0]
        assert [m["role"] for m in messages] == ["system", "user", "assistant", "user"]
        assert json.loads(messages[2]["content"]) == {
            "tool": "rag_search",
            "arguments": {"query": "widgets", "limit": 3},
        }
        assert messages[3]["content"].startswith("Result of rag_search:\n{")
        assert model.complete.call_args_list[1].kwargs == {"max_tokens": 200, "temperature": 0.1}

    def test_citations_are_one_per_document_across_steps(self) -> None:
        tools, _ = _tools(search=lambda args: _search_result(_hit(10), _hit(11), _hit(10)))
        model = _model([_call("rag_search", query="a"), _call("rag_get_document", document_id=10), "Done."])
        result = run_agent("q", tools, model, search_first=False)
        assert [c.document_id for c in result.citations] == [10, 11]
        assert result.citations[0].snippet == "Widgets ship on Tuesdays."
        assert [s.summary for s in result.steps] == ["Searched for “a”: 3 hits", "Read User Guide"]

    def test_unknown_tool_is_reported_to_the_model(self) -> None:
        tools, _ = _tools()
        model = _model([_call("rag_delete_everything"), "I cannot do that."])
        result = run_agent("q", tools, model, search_first=False)
        assert result.answer == "I cannot do that."
        assert [(s.tool, s.ok) for s in result.steps] == [("rag_delete_everything", False)]
        messages = model.complete.call_args_list[1].args[0]
        assert messages[-1]["content"].startswith("Error: there is no tool named 'rag_delete_everything'")
        assert "rag_search" in messages[-1]["content"]

    def test_document_reads_ask_for_no_more_than_fits(self) -> None:
        tools, runners = _tools()
        model = _model(
            [_call("rag_get_document", document_id=10), _call("rag_get_document", document_id=10, max_chars=900), "ok"]
        )
        result = run_agent("q", tools, model, search_first=False)
        assert [c.args[0] for c in runners["rag_get_document"].call_args_list] == [
            {"max_chars": agent.TOOL_RESULT_CHARS, "document_id": 10},
            {"max_chars": 900, "document_id": 10},
        ]
        # The step list keeps what the model asked for.
        assert result.steps[0].arguments == {"document_id": 10}

    def test_tool_failure_is_reported_to_the_model(self) -> None:
        tools, _ = _tools(document=MagicMock(side_effect=ValueError("no such document: 99")))
        model = _model([_call("rag_get_document", document_id=99), "There is no document 99."])
        result = run_agent("q", tools, model, search_first=False)
        assert result.steps[0].ok is False
        assert result.steps[0].summary == "rag_get_document failed: no such document: 99"
        messages = model.complete.call_args_list[1].args[0]
        assert messages[-1]["content"] == "Error from rag_get_document: no such document: 99"
        assert result.citations == []

    def test_step_limit_forces_an_answer(self) -> None:
        tools, runners = _tools()
        model = _model([_call("rag_search", query="a"), _call("rag_search", query="b"), "Final."])
        result = run_agent("q", tools, model, search_first=False, max_steps=2)
        assert result.answer == "Final."
        assert runners["rag_search"].call_count == 2
        messages = model.complete.call_args_list[2].args[0]
        assert messages[-1] == {"role": "user", "content": FINAL_ANSWER_PROMPT}

    def test_a_model_that_never_answers_gets_a_stock_reply(self) -> None:
        tools, _ = _tools()
        model = _model([_call("rag_search", query="a"), _call("rag_search", query="b")])
        result = run_agent("q", tools, model, search_first=False, max_steps=1)
        assert result.answer == NO_ANSWER_TEXT
        assert len(result.steps) == 1

    def test_token_counts_are_none_when_the_server_reports_none(self) -> None:
        tools, _ = _tools()
        model = _model(["Plain answer."], tokens=False)
        result = run_agent("q", tools, model, search_first=False)
        assert result.prompt_tokens is None
        assert result.completion_tokens is None
        assert result.steps == []

    def test_off_box_host_never_sees_a_communication(self) -> None:
        tools, runners = _tools(
            search=lambda args: _search_result(_hit(10)),
            document=lambda args: FakeDocument(corpus_class="communication", content="a private message"),
        )
        model = _model(
            [
                _call("rag_search", query="a", corpus_class="communication"),
                _call("rag_get_document", document_id=12),
                "Answer.",
            ],
            host="http://nas.local:11434",
        )
        result = run_agent("q", tools, model, search_first=False)
        runners["rag_search"].assert_called_once_with({"query": "a", "corpus_class": ["document", "code"]})
        assert result.steps[1].ok is False
        assert result.steps[1].summary == "rag_get_document: a communication stays on this machine"
        # The step list keeps the arguments the model asked for, not the restricted ones.
        assert result.steps[0].arguments == {"query": "a", "corpus_class": "communication"}
        messages = model.complete.call_args_list[2].args[0]
        assert "a private message" not in json.dumps(messages)
        assert messages[-1]["content"].startswith("Error from rag_get_document: that is a communication")
        assert [c.document_id for c in result.citations] == [10]

    def test_server_tools_validate_arguments(self) -> None:
        tools = tools_from_server(mcp, ("rag_search",))
        with patch("garage_rag.mcp_server.server._retrieve", return_value=([], "bge-m3")) as retrieve:
            # A limit outside the schema is the model's mistake and comes back as an error.
            model = _model([_call("rag_search", query="a", limit=500), _call("rag_search", query="a", limit="5"), "ok"])
            result = run_agent("q", tools, model, search_first=False)
        assert result.steps[0].ok is False
        assert "limit" in result.steps[0].summary
        # A string "5" is coerced the way tools/call coerces it, and defaults are filled in.
        retrieve.assert_called_once_with(
            "a", limit=5, mode="hybrid", corpus_class=None, trust=None, source=None, author=None, direction=None
        )
        assert result.steps[1].ok is True


class TestSearchFirst:
    """By default the question is searched before the model speaks (gemma2-2b otherwise
    answers "I don't have access to personal information" without calling a tool)."""

    def test_the_question_is_searched_before_the_model_replies(self) -> None:
        tools, runners = _tools()
        model = _model(["You last wrote to BMW on 3 May (Doc 10)."])

        result = run_agent("When did I last talk to BMW", tools, model)

        runners["rag_search"].assert_called_once_with(
            {"query": "When did I last talk to BMW", "limit": agent.FIRST_SEARCH_LIMIT}
        )
        assert result.answer == "You last wrote to BMW on 3 May (Doc 10)."
        assert [(s.tool, s.ok) for s in result.steps] == [("rag_search", True)]
        assert [c.document_id for c in result.citations] == [10]
        # The model's first turn already holds the call and its hits, as if it had made it.
        messages = model.complete.call_args_list[0].args[0]
        assert [m["role"] for m in messages] == ["system", "user", "assistant", "user"]
        assert json.loads(messages[2]["content"])["tool"] == "rag_search"
        assert "Widgets ship on Tuesdays." in messages[3]["content"]

    def test_keyword_backed_hits_carry_no_caution(self) -> None:
        tools, _ = _tools()
        model = _model(["Answer."])
        run_agent("q", tools, model)
        messages = model.complete.call_args_list[0].args[0]
        assert "Note:" not in messages[3]["content"]

    def test_vector_only_hits_are_flagged_as_possibly_unrelated(self) -> None:
        """A vector search always returns its nearest neighbours, so a question the corpus cannot
        answer still gets hits; the model is told they may be about something else."""
        hit = _hit()
        hit.matched_by = "vector"
        tools, _ = _tools(search=lambda args: _search_result(hit, query=args["query"]))
        model = _model(["I found nothing about BMW in your files."])

        result = run_agent("When did I last talk to BMW", tools, model)

        messages = model.complete.call_args_list[0].args[0]
        assert messages[3]["content"].startswith("Result of rag_search:")
        assert messages[3]["content"].endswith(agent.FIRST_SEARCH_VECTOR_ONLY_NOTE)
        assert result.answer == "I found nothing about BMW in your files."
        assert [c.document_id for c in result.citations] == [10]

    def test_no_hits_asks_for_one_more_search_then_a_plain_answer(self) -> None:
        tools, _ = _tools(search=lambda args: _search_result(query=args["query"]))
        model = _model(["Nothing about that in your files."])
        run_agent("q", tools, model)
        messages = model.complete.call_args_list[0].args[0]
        assert messages[3]["content"].endswith(agent.FIRST_SEARCH_NO_HITS_NOTE)

    def test_the_opening_search_does_not_use_up_a_step(self) -> None:
        tools, runners = _tools()
        model = _model([_call("rag_search", query="BMW"), "Answer."])
        result = run_agent("q", tools, model, max_steps=1)
        assert result.answer == "Answer."
        assert runners["rag_search"].call_count == 2
        assert [s.n for s in result.steps] == [1, 2]

    def test_off_box_host_opening_search_skips_communications(self) -> None:
        tools, runners = _tools()
        model = _model(["Answer."], host="http://nas.local:11434")
        run_agent("q", tools, model)
        runners["rag_search"].assert_called_once_with(
            {"query": "q", "limit": agent.FIRST_SEARCH_LIMIT, "corpus_class": ["document", "code"]}
        )

    def test_a_failed_opening_search_still_reaches_the_model(self) -> None:
        tools, _ = _tools(search=MagicMock(side_effect=RuntimeError("no embedding model")))
        model = _model(["I could not search."])
        result = run_agent("q", tools, model)
        assert result.steps[0].ok is False
        assert model.complete.call_args_list[0].args[0][-1]["content"].startswith("Error from rag_search")

    def test_skipped_without_a_search_tool(self) -> None:
        tools, _ = _tools()
        tools = [t for t in tools if t.name != "rag_search"]
        model = _model(["Plain answer."])
        result = run_agent("q", tools, model)
        assert result.steps == []

    def test_the_prompt_says_the_corpus_is_the_users_own(self) -> None:
        tools, _ = _tools()
        system = build_agent_messages("q", tools)[0]["content"]
        assert "Never say you have no access to personal information" in system
        assert '"I", "me" or "my"' in system


# ---------------------------------------------------------------------------
# the MCP tool
# ---------------------------------------------------------------------------
class TestRagAgentTool:
    def test_registered(self) -> None:
        tool = next(t for t in mcp._tool_manager.list_tools() if t.name == "rag_agent")
        assert tool.parameters["required"] == ["question"]
        assert set(tool.parameters["properties"]) == {
            "question",
            "max_steps",
            "max_tokens",
            "temperature",
            "search_first",
        }

    def test_runs_the_loop_on_the_local_model(self) -> None:
        model = MagicMock()
        expected = AgentResult(answer="a", model="m", provider="p", question="q")
        with (
            patch("garage_rag.mcp_server.server.LocalChatModel", return_value=model) as model_cls,
            patch("garage_rag.mcp_server.server._agent.run_agent", return_value=expected) as run,
            patch("garage_rag.mcp_server.server.get_settings", return_value=MagicMock(self_name="Rick Mark")),
        ):
            result = rag_agent(question="q", max_steps=3, max_tokens=100, temperature=0.5, search_first=True)
        assert result is expected
        model_cls.assert_called_once_with()
        args, kwargs = run.call_args
        assert args[0] == "q"
        assert [t.name for t in args[1]] == list(AGENT_TOOL_NAMES)
        assert args[2] is model
        assert kwargs == {
            "max_steps": 3,
            "max_tokens": 100,
            "temperature": 0.5,
            "search_first": True,
            "owner": "Rick Mark",
        }
