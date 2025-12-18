"""
Configuration loading.

This app is intentionally "12-factor": all runtime configuration comes from environment variables
(optionally via a local `.env` file for development).
"""

from __future__ import annotations

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """
    Strongly-typed configuration sourced from environment variables.

    Notes:
    - Values are read at instantiation time; do not create `Settings()` at import time.
    - `.env` is supported for local development only; in Azure, set env vars/secrets on the resource.
    """

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    # Azure AI Search
    azure_search_endpoint: str = Field(alias="AZURE_SEARCH_ENDPOINT")
    azure_search_index: str = Field(default="kb-index", alias="AZURE_SEARCH_INDEX")
    azure_search_api_version: str = Field(default="2025-09-01", alias="AZURE_SEARCH_API_VERSION")
    azure_search_api_key: str = Field(alias="AZURE_SEARCH_API_KEY")
    azure_search_vector_field: str = Field(default="contentVector", alias="AZURE_SEARCH_VECTOR_FIELD")
    azure_search_vectorizer: str = Field(default="openai-vectorizer", alias="AZURE_SEARCH_VECTORIZER")

    # Azure OpenAI
    azure_openai_endpoint: str = Field(alias="AZURE_OPENAI_ENDPOINT")
    azure_openai_api_version: str = Field(default="2024-02-15-preview", alias="AZURE_OPENAI_API_VERSION")
    azure_openai_chat_deployment: str = Field(default="chat", alias="AZURE_OPENAI_CHAT_DEPLOYMENT")
    azure_openai_api_key: str | None = Field(default=None, alias="AZURE_OPENAI_API_KEY")
    azure_openai_embed_deployment: str | None = Field(default=None, alias="AZURE_OPENAI_EMBED_DEPLOYMENT")

    # Retrieval mode:
    # - True: let Search vectorize query text using the index's configured vectorizer
    # - False: app embeds the query and sends the raw vector to Search
    use_search_vectorizer: bool = Field(default=True, alias="USE_SEARCH_VECTORIZER")


def get_settings() -> Settings:
    """
    Small indirection to centralize settings creation.

    Tests can monkeypatch `app.main.get_settings` (or env vars) without needing a global singleton.
    """

    return Settings()

