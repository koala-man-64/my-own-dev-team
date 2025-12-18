from __future__ import annotations

from types import SimpleNamespace

import pytest

from app.rag import RetrievedChunk, answer_question, retrieve_chunks


class FakeResponse:
    def __init__(self, payload: dict):
        self._payload = payload
        self.status_checked = False

    def raise_for_status(self) -> None:
        self.status_checked = True

    def json(self) -> dict:
        return self._payload


class FakeHttpClient:
    def __init__(self, payload: dict):
        self._payload = payload
        self.last_url = None
        self.last_headers = None
        self.last_json = None

    def post(self, url, *, headers=None, json=None):
        self.last_url = url
        self.last_headers = headers
        self.last_json = json
        return FakeResponse(self._payload)


def test_retrieve_chunks_uses_search_vectorizer(monkeypatch: pytest.MonkeyPatch) -> None:
    payload = {
        "value": [
            {
                "chunkId": "c1",
                "parentId": "p1",
                "title": "Doc 1",
                "content": "hello",
                "sourcePath": "blob://doc1",
                "@search.score": 1.23,
            }
        ]
    }
    fake_http = FakeHttpClient(payload)
    monkeypatch.setattr("app.rag.get_httpx_client", lambda: fake_http)

    settings = SimpleNamespace(
        azure_search_endpoint="https://example.search.windows.net",
        azure_search_index="kb-index",
        azure_search_api_version="2025-09-01",
        azure_search_api_key="search-key",
        azure_search_vector_field="contentVector",
        azure_search_vectorizer="openai-vectorizer",
        use_search_vectorizer=True,
        azure_openai_embed_deployment="embeddings",
    )

    results = retrieve_chunks(settings=settings, question="what is this?", top_k=3)
    assert results == [
        RetrievedChunk(
            chunk_id="c1",
            title="Doc 1",
            content="hello",
            source_path="blob://doc1",
            parent_id="p1",
            score=1.23,
            reranker_score=None,
        )
    ]

    assert fake_http.last_headers["api-key"] == "search-key"
    assert "docs/search?api-version=2025-09-01" in fake_http.last_url
    assert fake_http.last_json["search"] == "what is this?"
    assert fake_http.last_json["top"] == 3

    vq = fake_http.last_json["vectorQueries"][0]
    assert vq["kind"] == "text"
    assert vq["text"] == "what is this?"
    assert vq["k"] == 3
    assert vq["fields"] == "contentVector"
    assert vq["vectorizer"] == "openai-vectorizer"


def test_retrieve_chunks_requires_embed_deployment_when_not_using_search_vectorizer() -> None:
    settings = SimpleNamespace(use_search_vectorizer=False, azure_openai_embed_deployment=None)
    with pytest.raises(ValueError, match="AZURE_OPENAI_EMBED_DEPLOYMENT"):
        retrieve_chunks(settings=settings, question="q", top_k=1)


def test_retrieve_chunks_embeds_query_when_not_using_search_vectorizer(monkeypatch: pytest.MonkeyPatch) -> None:
    payload = {"value": []}
    fake_http = FakeHttpClient(payload)
    monkeypatch.setattr("app.rag.get_httpx_client", lambda: fake_http)

    calls = {}

    class FakeEmbeddings:
        def create(self, *, model: str, input: str):
            calls["model"] = model
            calls["input"] = input
            return SimpleNamespace(data=[SimpleNamespace(embedding=[0.1, 0.2, 0.3])])

    class FakeOAI:
        embeddings = FakeEmbeddings()

    monkeypatch.setattr("app.rag.get_openai_client", lambda: FakeOAI())

    settings = SimpleNamespace(
        azure_search_endpoint="https://example.search.windows.net",
        azure_search_index="kb-index",
        azure_search_api_version="2025-09-01",
        azure_search_api_key="search-key",
        azure_search_vector_field="contentVector",
        azure_search_vectorizer="openai-vectorizer",
        use_search_vectorizer=False,
        azure_openai_embed_deployment="embeddings",
    )

    retrieve_chunks(settings=settings, question="q", top_k=2)

    assert calls == {"model": "embeddings", "input": "q"}
    vq = fake_http.last_json["vectorQueries"][0]
    assert vq["kind"] == "vector"
    assert vq["vector"] == [0.1, 0.2, 0.3]
    assert vq["k"] == 2
    assert vq["fields"] == "contentVector"


def test_answer_question_formats_context_and_returns_citations(monkeypatch: pytest.MonkeyPatch) -> None:
    chunks = [
        RetrievedChunk(
            chunk_id="c1",
            parent_id="p1",
            title="T1",
            content="C1",
            source_path="blob://doc1",
        ),
        RetrievedChunk(
            chunk_id="c2",
            parent_id="p2",
            title=None,
            content="C2",
            source_path=None,
        ),
    ]
    monkeypatch.setattr("app.rag.retrieve_chunks", lambda *, settings, question, top_k: chunks)

    called = {}

    class FakeChatCompletions:
        def create(self, *, model: str, messages, temperature: float):
            called["model"] = model
            called["messages"] = messages
            called["temperature"] = temperature
            return SimpleNamespace(choices=[SimpleNamespace(message=SimpleNamespace(content="answer"))])

    class FakeChat:
        completions = FakeChatCompletions()

    class FakeOAI:
        chat = FakeChat()

    monkeypatch.setattr("app.rag.get_openai_client", lambda: FakeOAI())

    settings = SimpleNamespace(azure_openai_chat_deployment="chat")
    answer, got_chunks = answer_question(settings=settings, question="q", top_k=2)

    assert answer == "answer"
    assert got_chunks == chunks
    assert called["model"] == "chat"

    user_msg = next(m for m in called["messages"] if m["role"] == "user")["content"]
    assert "[1] T1" in user_msg
    assert "Source: blob://doc1" in user_msg
    assert "C1" in user_msg
    assert "[2] Untitled" in user_msg
    assert "C2" in user_msg

