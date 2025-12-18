"""
Retrieval-Augmented Generation (RAG) orchestration.

Flow:
  1) Retrieve relevant chunks from Azure AI Search (hybrid + vector query)
  2) Build a compact context string
  3) Ask Azure OpenAI to answer using that context
"""

from __future__ import annotations

from dataclasses import dataclass

import httpx

from .clients import get_httpx_client, get_openai_client
from .settings import Settings


@dataclass(frozen=True)
class RetrievedChunk:
    """Normalized shape of a retrieved chunk as returned by Azure AI Search."""

    chunk_id: str
    title: str | None
    content: str
    source_path: str | None
    parent_id: str | None
    score: float | None = None
    reranker_score: float | None = None


def _search_headers(settings: Settings) -> dict[str, str]:
    """Headers for Search data-plane requests when using API key authentication."""

    return {
        "Content-Type": "application/json",
        "api-key": settings.azure_search_api_key,
    }


def retrieve_chunks(*, settings: Settings, question: str, top_k: int) -> list[RetrievedChunk]:
    """
    Query Azure AI Search and return the top retrieved chunks.

    This uses:
      - `search`: lexical (BM25) match on text fields
      - `vectorQueries`: semantic proximity on the vector field
    """

    if not settings.use_search_vectorizer and not settings.azure_openai_embed_deployment:
        raise ValueError("AZURE_OPENAI_EMBED_DEPLOYMENT is required when USE_SEARCH_VECTORIZER=false")

    http = get_httpx_client()

    url = (
        f"{settings.azure_search_endpoint}/indexes/{settings.azure_search_index}/docs/search"
        f"?api-version={settings.azure_search_api_version}"
    )

    body: dict = {
        "top": top_k,
        "select": "chunkId,parentId,title,content,sourcePath",
        "search": question,
    }

    if settings.use_search_vectorizer:
        # Let Search call its configured vectorizer to embed the query text at query-time.
        body["vectorQueries"] = [
            {
                "kind": "text",
                "text": question,
                "k": top_k,
                "fields": settings.azure_search_vector_field,
                "vectorizer": settings.azure_search_vectorizer,
            }
        ]
    else:
        # Embed in-app and send the raw vector to Search (useful if you don't want Search vectorizers).
        oai = get_openai_client()
        emb = oai.embeddings.create(model=settings.azure_openai_embed_deployment, input=question)
        vector = emb.data[0].embedding
        body["vectorQueries"] = [
            {"kind": "vector", "vector": vector, "k": top_k, "fields": settings.azure_search_vector_field}
        ]

    resp = http.post(url, headers=_search_headers(settings), json=body)
    resp.raise_for_status()
    payload = resp.json()

    results: list[RetrievedChunk] = []
    for doc in payload.get("value", []):
        # The Search response includes both our fields and special @search.* fields.
        results.append(
            RetrievedChunk(
                chunk_id=doc.get("chunkId"),
                parent_id=doc.get("parentId"),
                title=doc.get("title"),
                content=doc.get("content") or "",
                source_path=doc.get("sourcePath"),
                score=doc.get("@search.score"),
                reranker_score=doc.get("@search.rerankerScore"),
            )
        )
    return results


def answer_question(*, settings: Settings, question: str, top_k: int) -> tuple[str, list[RetrievedChunk]]:
    """
    End-to-end RAG call: retrieve chunks, build context, generate answer.

    Returns:
      (answer_text, retrieved_chunks)
    """

    chunks = retrieve_chunks(settings=settings, question=question, top_k=top_k)

    context_blocks: list[str] = []
    for i, c in enumerate(chunks, start=1):
        title = c.title or "Untitled"
        src = c.source_path or c.parent_id or "unknown"
        # Bracket numbering enables easy citations in the generated answer, e.g. [1], [2].
        context_blocks.append(f"[{i}] {title}\nSource: {src}\n{c.content}")

    context = "\n\n".join(context_blocks) if context_blocks else "(no matches)"

    system = (
        "You are a helpful assistant. Use the provided context to answer the user's question.\n"
        "If the answer is not in the context, say you don't know and ask a follow-up question.\n"
        "Cite sources by bracket number like [1], [2]."
    )

    oai = get_openai_client()
    completion = oai.chat.completions.create(
        model=settings.azure_openai_chat_deployment,
        messages=[
            {"role": "system", "content": system},
            {"role": "user", "content": f"Question:\n{question}\n\nContext:\n{context}"},
        ],
        temperature=0.2,
    )

    answer = completion.choices[0].message.content or ""
    return answer, chunks

