from __future__ import annotations

from fastapi import FastAPI
from pydantic import BaseModel, Field

from .rag import answer_question
from .settings import get_settings


app = FastAPI(title="RAG API (Azure AI Search + Azure OpenAI)")


class ChatRequest(BaseModel):
    question: str = Field(min_length=1)
    top_k: int = Field(default=5, ge=1, le=50)


class Citation(BaseModel):
    chunk_id: str
    title: str | None
    source_path: str | None
    parent_id: str | None


class ChatResponse(BaseModel):
    answer: str
    citations: list[Citation]


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/chat", response_model=ChatResponse)
def chat(req: ChatRequest) -> ChatResponse:
    settings = get_settings()
    answer, chunks = answer_question(settings=settings, question=req.question, top_k=req.top_k)
    citations = [
        Citation(chunk_id=c.chunk_id, title=c.title, source_path=c.source_path, parent_id=c.parent_id) for c in chunks
    ]
    return ChatResponse(answer=answer, citations=citations)

