from __future__ import annotations

import sys
from pathlib import Path

import pytest


PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))


@pytest.fixture(autouse=True)
def _clear_caches():
    from app import clients

    clients.get_httpx_client.cache_clear()
    clients.get_openai_client.cache_clear()
    yield
    clients.get_httpx_client.cache_clear()
    clients.get_openai_client.cache_clear()
