"""``LocalChatModel``: one chat client, three local backends, no cloud path."""

from __future__ import annotations

from unittest.mock import MagicMock, patch

import pytest

from garage_rag.config import Settings
from garage_rag.enrich.generation import ChatReply, LocalChatModel, LocalModelUnavailable
from garage_rag.inference import ChatResult, InferenceClient, InferenceHTTPError, InferenceUnreachable
from garage_rag.xpc.llama_xpc import LlamaXPCClient

MESSAGES = [{"role": "system", "content": "be brief"}, {"role": "user", "content": "hi"}]


def _llama_model(**overrides) -> LocalChatModel:
    return LocalChatModel(settings=Settings(**overrides))


class TestConstruction:
    def test_defaults_come_from_the_facts_section(self) -> None:
        model = _llama_model()
        assert model.provider == "llama_xpc"
        assert model.model_ref == "gemma-4-e4b"
        assert model.host == "http://127.0.0.1:8790"

    def test_ollama_uses_the_ollama_host(self) -> None:
        model = LocalChatModel(settings=Settings(fact_provider="ollama", fact_model="gemma2:2b"))
        assert model.provider == "ollama"
        assert model.host == "http://localhost:11434"

    def test_the_inference_section_names_the_chat_model(self) -> None:
        settings = Settings(inference_model="granite-4.1-8b", fact_model="gemma2-2b", fact_provider="ollama")
        model = LocalChatModel(settings=settings)
        # inference.provider is empty, so the chat model is served where facts.provider says.
        assert (model.provider, model.model_ref) == ("ollama", "granite-4.1-8b")
        settings = Settings(inference_model="gpt-oss-20b", inference_provider="llama_xpc", fact_provider="ollama")
        assert LocalChatModel(settings=settings).provider == "llama_xpc"

    def test_an_inference_provider_alone_does_not_move_the_facts_model(self) -> None:
        settings = Settings(inference_provider="lmstudio", fact_model="gemma2-2b")
        model = LocalChatModel(settings=settings)
        assert (model.provider, model.model_ref) == ("llama_xpc", "gemma2-2b")

    def test_explicit_arguments_win(self) -> None:
        model = LocalChatModel(provider="ollama", model_ref="phi", settings=Settings())
        assert (model.provider, model.model_ref) == ("ollama", "phi")

    def test_unknown_provider_is_rejected(self) -> None:
        with pytest.raises(ValueError, match="unknown generation provider"):
            LocalChatModel(provider="openai", settings=Settings())

    def test_a_remote_ollama_is_approved_when_configured(self) -> None:
        model = LocalChatModel(settings=Settings(fact_provider="ollama", ollama_host="http://gpu-box:11434"))
        assert model.host == "http://gpu-box:11434"
        assert isinstance(model._inference_client(), InferenceClient)

    def test_an_unapproved_host_is_refused_at_construction(self) -> None:
        from garage_rag.net.egress import EgressBlocked

        settings = Settings.model_construct(fact_provider="llama_xpc", llama_host="http://gpu-box:8790")
        with pytest.raises(EgressBlocked, match="loopback"):
            LocalChatModel(settings=settings)

    def test_lmstudio_uses_the_lmstudio_host(self) -> None:
        model = LocalChatModel(settings=Settings(fact_provider="lmstudio", fact_model="google/gemma-3-4b"))
        assert (model.provider, model.host) == ("lmstudio", "http://localhost:1234/v1")
        remote = LocalChatModel(settings=Settings(fact_provider="lmstudio", lmstudio_host="http://lm.example/v1"))
        assert remote._inference_client().base_url == "http://lm.example"

    def test_each_provider_gets_its_client(self) -> None:
        assert isinstance(_llama_model()._inference_client(), LlamaXPCClient)
        for provider, root in (("ollama", "http://localhost:11434"), ("lmstudio", "http://localhost:1234")):
            client = LocalChatModel(provider=provider, settings=Settings())._inference_client()
            assert type(client) is InferenceClient
            assert (str(client.kind), client.base_url) == (provider, root)


def _reply(text: str = "  hello  ", prompt: int | None = 12, completion: int | None = 3) -> ChatResult:
    return ChatResult(text=text, prompt_tokens=prompt, completion_tokens=completion)


@pytest.mark.parametrize(
    ("provider", "model_ref"), [("llama_xpc", "gemma2-2b"), ("ollama", "gemma2:2b"), ("lmstudio", "google/gemma-3-4b")]
)
class TestEveryProvider:
    def test_chat_sends_the_model_and_returns_text(self, provider: str, model_ref: str) -> None:
        model = LocalChatModel(settings=Settings(fact_provider=provider, fact_model=model_ref))
        client = MagicMock()
        client.chat.return_value = _reply()
        with patch.object(model, "_inference_client", return_value=client):
            reply = model.complete(MESSAGES, max_tokens=64, temperature=0.2)
            assert model.chat(MESSAGES) == "hello"
        assert reply == ChatReply(text="hello", prompt_tokens=12, completion_tokens=3)
        client.chat.assert_any_call(MESSAGES, model_ref, max_tokens=64, temperature=0.2)

    def test_transport_failure_becomes_a_clear_error(self, provider: str, model_ref: str) -> None:
        model = LocalChatModel(settings=Settings(fact_provider=provider, fact_model=model_ref))
        client = MagicMock()
        client.chat.side_effect = InferenceUnreachable(f"cannot reach it at {model.host}", status_code=503)
        with (
            patch.object(model, "_inference_client", return_value=client),
            pytest.raises(LocalModelUnavailable) as info,
        ):
            model.chat(MESSAGES)
        message = str(info.value)
        assert provider in message
        assert model.host in message
        assert model_ref in message


class TestHints:
    @pytest.mark.parametrize(
        ("provider", "hint"),
        [("llama_xpc", "Models page"), ("ollama", "ollama pull gemma2:2b"), ("lmstudio", "lms get gemma2:2b")],
    )
    def test_the_fix_names_the_provider_tool(self, provider: str, hint: str) -> None:
        model = LocalChatModel(provider=provider, model_ref="gemma2:2b", settings=Settings())
        assert hint in str(model._unavailable("x"))


class TestAvailability:
    def test_llama_xpc_checks_health_and_the_served_aliases(self) -> None:
        model = _llama_model(fact_model="gemma2-2b")
        client = MagicMock(spec=LlamaXPCClient)
        client.health.return_value = {"status": "ok"}
        client.list_models.return_value = ["bge-m3", "gemma2-2b"]
        with patch.object(model, "_inference_client", return_value=client):
            assert model.is_available()
            client.list_models.return_value = ["bge-m3"]
            assert not model.is_available()
            client.list_models.return_value = []
            assert model.is_available()  # an engine that does not enumerate: the request decides
            client.health.return_value = {"error": {"message": "Loading model"}}
            assert not model.is_available()

    def test_llama_xpc_unreachable_is_false(self) -> None:
        model = _llama_model()
        client = MagicMock(spec=LlamaXPCClient)
        client.health.side_effect = InferenceUnreachable("nope", status_code=503)
        with patch.object(model, "_inference_client", return_value=client):
            assert model.is_available() is False

    @pytest.mark.parametrize("provider", ["ollama", "lmstudio"])
    def test_others_check_the_model_list(self, provider: str) -> None:
        model = LocalChatModel(provider=provider, model_ref="gemma2:2b", settings=Settings())
        client = MagicMock(spec=InferenceClient)
        client.has_model.return_value = True
        with patch.object(model, "_inference_client", return_value=client):
            assert model.is_available()
            client.has_model.assert_called_once_with("gemma2:2b")
            client.has_model.side_effect = InferenceUnreachable("down")
            assert not model.is_available()

    def test_a_server_that_refuses_is_unavailable_not_an_exception(self) -> None:
        model = LocalChatModel(provider="lmstudio", settings=Settings())
        client = MagicMock(spec=InferenceClient)
        client.has_model.side_effect = InferenceHTTPError("nope", status_code=401)
        with patch.object(model, "_inference_client", return_value=client):
            assert model.is_available() is False


def test_request_body_on_the_wire() -> None:
    """End to end through the real client: the body carries the model and the limits."""
    model = _llama_model(fact_model="gemma2-2b")
    captured: dict = {}

    def fake_call(self, method, path, body=None):
        captured.update(method=method, path=path, body=body)
        return {"choices": [{"message": {"content": "ok"}}]}

    with patch.object(InferenceClient, "_call", fake_call):
        assert model.chat([{"role": "user", "content": "hi"}], max_tokens=8) == "ok"
    assert captured == {
        "method": "POST",
        "path": "/v1/chat/completions",
        "body": {"messages": [{"role": "user", "content": "hi"}], "model": "gemma2-2b", "max_tokens": 8},
    }
