"""
Thin wrappers for clients used by the app.

We cache clients to:
  - reuse connection pools (httpx)
  - avoid rebuilding auth plumbing (Azure OpenAI)
"""

from __future__ import annotations

from functools import lru_cache

import httpx
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from openai import AzureOpenAI

from .settings import Settings, get_settings


@lru_cache
def get_httpx_client() -> httpx.Client:
    """Shared httpx client (connection pooling, timeouts)."""

    return httpx.Client(timeout=httpx.Timeout(30.0))


@lru_cache
def get_openai_client() -> AzureOpenAI:
    """
    Azure OpenAI client configured for either:
      - API key auth (simplest), or
      - Azure AD auth via DefaultAzureCredential (preferred in production with Managed Identity).
    """

    settings: Settings = get_settings()

    if settings.azure_openai_api_key:
        # API key auth is straightforward and works anywhere, but requires secret distribution.
        return AzureOpenAI(
            api_key=settings.azure_openai_api_key,
            azure_endpoint=settings.azure_openai_endpoint,
            api_version=settings.azure_openai_api_version,
        )

    # Azure AD auth: DefaultAzureCredential tries multiple mechanisms (Managed Identity, CLI login, etc.).
    token_provider = get_bearer_token_provider(
        DefaultAzureCredential(exclude_interactive_browser_credential=False),
        "https://cognitiveservices.azure.com/.default",
    )
    return AzureOpenAI(
        azure_endpoint=settings.azure_openai_endpoint,
        api_version=settings.azure_openai_api_version,
        azure_ad_token_provider=token_provider,
    )

