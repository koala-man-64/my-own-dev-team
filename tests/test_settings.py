from __future__ import annotations

import pytest
from pydantic import ValidationError

from app.settings import Settings


def test_settings_requires_minimum_env(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("AZURE_SEARCH_ENDPOINT", raising=False)
    monkeypatch.delenv("AZURE_SEARCH_API_KEY", raising=False)
    monkeypatch.delenv("AZURE_OPENAI_ENDPOINT", raising=False)

    with pytest.raises(ValidationError):
        Settings()


def test_settings_defaults_and_bool_parsing(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("AZURE_SEARCH_ENDPOINT", "https://example.search.windows.net")
    monkeypatch.setenv("AZURE_SEARCH_API_KEY", "search-key")
    monkeypatch.setenv("AZURE_OPENAI_ENDPOINT", "https://example.openai.azure.com/")
    monkeypatch.setenv("USE_SEARCH_VECTORIZER", "false")

    s = Settings()
    assert s.azure_search_index == "kb-index"
    assert s.azure_search_api_version == "2025-09-01"
    assert s.azure_search_vector_field == "contentVector"
    assert s.azure_search_vectorizer == "openai-vectorizer"
    assert s.azure_openai_api_version == "2024-02-15-preview"
    assert s.azure_openai_chat_deployment == "chat"
    assert s.use_search_vectorizer is False

