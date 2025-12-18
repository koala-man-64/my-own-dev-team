from __future__ import annotations

import pytest


@pytest.fixture(autouse=True)
def _clear_caches():
    from app import clients

    clients.get_httpx_client.cache_clear()
    clients.get_openai_client.cache_clear()
    yield
    clients.get_httpx_client.cache_clear()
    clients.get_openai_client.cache_clear()

