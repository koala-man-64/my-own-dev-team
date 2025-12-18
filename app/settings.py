from __future__ import annotations

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    azure_search_endpoint: str = Field(alias="AZURE_SEARCH_ENDPOINT")
    azure_search_index: str = Field(default="kb-index", alias="AZURE_SEARCH_INDEX")
    azure_search_api_version: str = Field(default="2025-09-01", alias="AZURE_SEARCH_API_VERSION")
    azure_search_api_key: str = Field(alias="AZURE_SEARCH_API_KEY")
    azure_search_vector_field: str = Field(default="contentVector", alias="AZURE_SEARCH_VECTOR_FIELD")
    azure_search_vectorizer: str = Field(default="openai-vectorizer", alias="AZURE_SEARCH_VECTORIZER")

    azure_openai_endpoint: str = Field(alias="AZURE_OPENAI_ENDPOINT")
    azure_openai_api_version: str = Field(default="2024-02-15-preview", alias="AZURE_OPENAI_API_VERSION")
    azure_openai_chat_deployment: str = Field(default="chat", alias="AZURE_OPENAI_CHAT_DEPLOYMENT")
    azure_openai_api_key: str | None = Field(default=None, alias="AZURE_OPENAI_API_KEY")
    azure_openai_embed_deployment: str | None = Field(default=None, alias="AZURE_OPENAI_EMBED_DEPLOYMENT")

    use_search_vectorizer: bool = Field(default=True, alias="USE_SEARCH_VECTORIZER")


def get_settings() -> Settings:
    return Settings()

