# Application Runtime Flow (Serving Path)

This document describes what happens when a client calls the API at runtime. It is structured so you can convert it directly into a flow chart or swimlane diagram.

## Technologies and responsibilities

- **Client**: Sends an HTTP request to the API.
- **FastAPI** (`app/main.py`): HTTP routing, request validation, response shaping.
- **Pydantic** (`app/main.py`): Validates incoming request payloads.
- **pydantic-settings** (`app/settings.py`): Loads strongly-typed configuration from environment variables.
- **httpx** (`app/clients.py`, `app/rag.py`): Makes REST calls to Azure AI Search (connection pooling, timeouts).
- **Azure AI Search (data plane REST)**: Retrieves relevant chunks using lexical search + vector search.
- **Azure OpenAI (OpenAI Python SDK)** (`app/clients.py`, `app/rag.py`): Generates answers (chat completions) and optionally embeds queries.
- **Azure Identity** (`DefaultAzureCredential`): Optional AAD / Managed Identity authentication for Azure OpenAI (when no API key is set).

## Preconditions (outside the request path)

- **Search index is built and populated**. The API only *queries* Search; it does not ingest documents on demand.
  - Documents are uploaded to Blob Storage (`kb-docs` container).
  - An Azure AI Search **indexer pipeline** (datasource + skillset + indexer) extracts text, chunks it, embeds chunks, and writes them into the Search index (default index name: `kb-index`).

## Swimlanes (systems/actors)

- **Client**
- **FastAPI Service** (this repo running under Uvicorn)
- **Azure AI Search**
- **Azure OpenAI**
- **Azure AD** (optional; only used when Azure OpenAI auth is AAD/Managed Identity)

## Primary runtime flow: `POST /chat`

### 1) Client sends request

- **Client → FastAPI**: `POST /chat`
- **Payload**: `{ "question": "<string>", "top_k": <int> }`
- **Tech**: FastAPI + `ChatRequest` model (`app/main.py`)

### 2) FastAPI validates input

- Validations (Pydantic):
  - `question` must be non-empty
  - `top_k` defaults to `5`, must be between `1` and `50`
- **If invalid**: FastAPI returns **422** and stops.

### 3) Load configuration from environment

- **FastAPI** calls `get_settings()` → `Settings()` (`app/settings.py`)
- Settings include endpoints, API versions, deployment names, and (optionally) secrets.
- **If required env vars are missing**: settings creation fails → request typically returns **500**.

### 4) Enter RAG orchestration

- **FastAPI** calls `answer_question(settings, question, top_k)` (`app/rag.py`)
- `answer_question()` coordinates:
  1. retrieval from Search (`retrieve_chunks`)
  2. context assembly
  3. LLM generation (Azure OpenAI chat completion)

### 5) Retrieval from Azure AI Search (hybrid + vector)

`answer_question()` calls `retrieve_chunks(settings, question, top_k)`:

1. **Build Search request**
   - **Hybrid search**:
     - lexical: `search = question`
     - vector: `vectorQueries = [...]` targeting `AZURE_SEARCH_VECTOR_FIELD` (default: `contentVector`)
   - **Select fields**: `chunkId,parentId,title,content,sourcePath`
2. **Send Search request**
   - **FastAPI → Azure AI Search**: `POST /indexes/{index}/docs/search?api-version=...`
   - **Auth**: `api-key: AZURE_SEARCH_API_KEY`
   - **Tech**: `httpx` client (cached per-process via `lru_cache` in `app/clients.py`)
3. **Parse Search response**
   - Maps each hit into a `RetrievedChunk` dataclass (including `@search.score`)

### 6) Decision: where does query embedding happen?

This is controlled by `USE_SEARCH_VECTORIZER`:

#### 6A) `USE_SEARCH_VECTORIZER=true` (default)

- The app asks Search to vectorize the query text:
  - `vectorQueries[0].kind = "text"`
  - `vectorQueries[0].text = question`
  - `vectorQueries[0].vectorizer = AZURE_SEARCH_VECTORIZER` (default: `openai-vectorizer`)
- **Azure AI Search** performs query-time vectorization using the vectorizer defined on the index.
- **Important for the diagram**: in this mode, **Search** will call **Azure OpenAI embeddings** behind the scenes; the app does not call the embeddings endpoint directly.

#### 6B) `USE_SEARCH_VECTORIZER=false`

- The app embeds the query itself, then sends the raw vector to Search:
  - **FastAPI → Azure OpenAI**: embeddings call using `AZURE_OPENAI_EMBED_DEPLOYMENT`
  - **FastAPI → Azure AI Search**: `vectorQueries[0].kind = "vector"` with `vector = [float, ...]`
- If `AZURE_OPENAI_EMBED_DEPLOYMENT` is missing, `retrieve_chunks()` fails fast with a `ValueError` before any Search call.

### 7) Context assembly (“augmentation”)

- `answer_question()` formats retrieved chunks into a single context string:
  - Each chunk is labeled `[1]`, `[2]`, ... (citation IDs)
  - Each block includes `title` and a “Source” line (`sourcePath` if available)
- If Search returns no hits, context becomes `(no matches)`.

### 8) LLM generation (Azure OpenAI chat completion)

- **FastAPI → Azure OpenAI**: chat completion call using `AZURE_OPENAI_CHAT_DEPLOYMENT`
- Prompt includes:
  - system instruction: answer based on the provided context, cite like `[1]`
  - user question
  - assembled context

**Auth decision (Azure OpenAI client)**

- If `AZURE_OPENAI_API_KEY` is set: use API key auth.
- Else: use AAD auth via `DefaultAzureCredential` (Managed Identity, CLI login, etc.) → token scope `https://cognitiveservices.azure.com/.default`.

### 9) Return response

- **FastAPI** returns `ChatResponse` JSON:
  - `answer`: model output text
  - `citations`: chunk metadata (for traceability to sources)

## Flow-chart node list (IDs + edges)

You can turn this into boxes/diamonds and connectors.

### Nodes

- **N0** Start
- **N1** Client sends `POST /chat` (question, top_k)
- **D1** Request valid? (Pydantic validation)
- **N2** Load `Settings` from env
- **D2** Settings valid?
- **N3** Call `answer_question()`
- **N4** Call `retrieve_chunks()`
- **D3** `USE_SEARCH_VECTORIZER`?
- **N5A** Search retrieval with `vectorQueries(kind=text)` (Search performs query-time embedding)
- **N5B1** Embed query via Azure OpenAI embeddings
- **N5B2** Search retrieval with `vectorQueries(kind=vector)` (app supplies vector)
- **N6** Parse Search hits → `RetrievedChunk[]`
- **N7** Build context string with citations
- **N8** Azure OpenAI chat completion
- **N9** Build `ChatResponse` (answer + citations)
- **N10** Return 200
- **E422** Return 422 (validation failure)
- **E500** Return 500 (misconfig / upstream errors / unhandled exception)

### Edges

- N0 → N1 → D1
- D1 (No) → E422
- D1 (Yes) → N2 → D2
- D2 (No) → E500
- D2 (Yes) → N3 → N4 → D3
- D3 (Yes) → N5A → N6
- D3 (No) → N5B1 → N5B2 → N6
- N6 → N7 → N8 → N9 → N10

## Failure paths to include in the diagram

- **Azure AI Search error** (401/403 wrong key, 404 missing index, 429 throttling, 5xx): `httpx.raise_for_status()` raises → request becomes 500 unless you add exception handlers.
- **Azure OpenAI error** (401/403 wrong key, 429 throttling, 5xx): SDK raises → request becomes 500 unless you add exception handlers.
- **Timeouts**: `httpx` client defaults to a 30s timeout; OpenAI SDK timeouts depend on underlying HTTP client defaults.
