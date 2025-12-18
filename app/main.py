"""
FastAPI entrypoint.

Endpoints:
  - GET /healthz: health check
  - POST /chat: RAG query (Search retrieval + OpenAI generation)
"""

from __future__ import annotations

from fastapi import FastAPI
from pydantic import BaseModel, Field

from .rag import answer_question
from .settings import get_settings


app = FastAPI(title="RAG API (Azure AI Search + Azure OpenAI)")


class ChatRequest(BaseModel):
    """Request payload for /chat."""

    question: str = Field(min_length=1)
    top_k: int = Field(default=5, ge=1, le=50)


class Citation(BaseModel):
    """Minimal citation metadata returned to clients for traceability."""

    chunk_id: str
    title: str | None
    source_path: str | None
    parent_id: str | None


class ChatResponse(BaseModel):
    """Response payload for /chat."""

    answer: str
    citations: list[Citation]


@app.get("/healthz")
def healthz() -> dict[str, str]:
    """Kubernetes/App Service friendly health probe."""

    return {"status": "ok"}


@app.post("/chat", response_model=ChatResponse)
def chat(req: ChatRequest) -> ChatResponse:
    """
    Main RAG endpoint.

    - Loads current settings (env-backed)
    - Retrieves chunks from Search
    - Calls Azure OpenAI chat completion with retrieved context
    """

    settings = get_settings()
    answer, chunks = answer_question(settings=settings, question=req.question, top_k=req.top_k)
    citations = [
        Citation(chunk_id=c.chunk_id, title=c.title, source_path=c.source_path, parent_id=c.parent_id) for c in chunks
    ]
    return ChatResponse(answer=answer, citations=citations)

