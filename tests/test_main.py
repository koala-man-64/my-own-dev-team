from __future__ import annotations

from types import SimpleNamespace

from fastapi.testclient import TestClient

from app.main import app
from app.rag import RetrievedChunk


def test_healthz() -> None:
    client = TestClient(app)
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json() == {"status": "ok"}


def test_chat_returns_answer_and_citations(monkeypatch) -> None:
    monkeypatch.setattr("app.main.get_settings", lambda: SimpleNamespace())

    def fake_answer_question(*, settings, question: str, top_k: int):
        assert question == "hello"
        assert top_k == 5
        return (
            "hi",
            [
                RetrievedChunk(
                    chunk_id="c1",
                    parent_id="p1",
                    title="Doc",
                    content="content",
                    source_path="blob://doc",
                )
            ],
        )

    monkeypatch.setattr("app.main.answer_question", fake_answer_question)

    client = TestClient(app)
    r = client.post("/chat", json={"question": "hello", "top_k": 5})
    assert r.status_code == 200
    assert r.json() == {
        "answer": "hi",
        "citations": [{"chunk_id": "c1", "title": "Doc", "source_path": "blob://doc", "parent_id": "p1"}],
    }


def test_chat_validation_errors() -> None:
    client = TestClient(app)
    assert client.post("/chat", json={"question": "", "top_k": 5}).status_code == 422
    assert client.post("/chat", json={"question": "ok", "top_k": 0}).status_code == 422
    assert client.post("/chat", json={"question": "ok", "top_k": 51}).status_code == 422

