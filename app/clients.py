from __future__ import annotations

from functools import lru_cache

import httpx
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from openai import AzureOpenAI

from .settings import Settings, get_settings


@lru_cache
def get_httpx_client() -> httpx.Client:
    return httpx.Client(timeout=httpx.Timeout(30.0))


@lru_cache
def get_openai_client(settings: Settings | None = None) -> AzureOpenAI:
    settings = settings or get_settings()

    if settings.azure_openai_api_key:
        return AzureOpenAI(
            api_key=settings.azure_openai_api_key,
            azure_endpoint=settings.azure_openai_endpoint,
            api_version=settings.azure_openai_api_version,
        )

    token_provider = get_bearer_token_provider(
        DefaultAzureCredential(exclude_interactive_browser_credential=False),
        "https://cognitiveservices.azure.com/.default",
    )
    return AzureOpenAI(
        azure_endpoint=settings.azure_openai_endpoint,
        api_version=settings.azure_openai_api_version,
        azure_ad_token_provider=token_provider,
    )

