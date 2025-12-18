from __future__ import annotations

from types import SimpleNamespace

import pytest

from app import clients


def _set_required_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("AZURE_SEARCH_ENDPOINT", "https://example.search.windows.net")
    monkeypatch.setenv("AZURE_SEARCH_API_KEY", "search-key")
    monkeypatch.setenv("AZURE_OPENAI_ENDPOINT", "https://example.openai.azure.com/")


def test_get_httpx_client_is_cached() -> None:
    c1 = clients.get_httpx_client()
    c2 = clients.get_httpx_client()
    assert c1 is c2


def test_get_openai_client_uses_api_key(monkeypatch: pytest.MonkeyPatch) -> None:
    _set_required_env(monkeypatch)
    monkeypatch.setenv("AZURE_OPENAI_API_KEY", "openai-key")
    monkeypatch.setenv("AZURE_OPENAI_API_VERSION", "2024-02-15-preview")

    created = {}

    class DummyAzureOpenAI:
        def __init__(self, **kwargs):
            created.update(kwargs)

    monkeypatch.setattr(clients, "AzureOpenAI", DummyAzureOpenAI)

    oai = clients.get_openai_client()
    assert isinstance(oai, DummyAzureOpenAI)
    assert created["api_key"] == "openai-key"
    assert created["azure_endpoint"] == "https://example.openai.azure.com/"
    assert created["api_version"] == "2024-02-15-preview"
    assert "azure_ad_token_provider" not in created


def test_get_openai_client_uses_defaultazurecredential_when_no_key(monkeypatch: pytest.MonkeyPatch) -> None:
    _set_required_env(monkeypatch)
    monkeypatch.delenv("AZURE_OPENAI_API_KEY", raising=False)

    created = {}

    class DummyAzureOpenAI:
        def __init__(self, **kwargs):
            created.update(kwargs)

    class DummyCredential:
        def __init__(self, **kwargs):
            self.kwargs = kwargs

    def dummy_token_provider(cred, scope: str):
        assert isinstance(cred, DummyCredential)
        assert scope == "https://cognitiveservices.azure.com/.default"
        return SimpleNamespace(__call__=lambda: "token")

    monkeypatch.setattr(clients, "AzureOpenAI", DummyAzureOpenAI)
    monkeypatch.setattr(clients, "DefaultAzureCredential", DummyCredential)
    monkeypatch.setattr(clients, "get_bearer_token_provider", dummy_token_provider)

    oai = clients.get_openai_client()
    assert isinstance(oai, DummyAzureOpenAI)
    assert created["azure_endpoint"] == "https://example.openai.azure.com/"
    assert "azure_ad_token_provider" in created
    assert "api_key" not in created

