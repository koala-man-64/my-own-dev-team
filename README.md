# Azure RAG Blueprint (AI Search + OpenAI + FastAPI)

This repo provisions a minimal RAG stack on Azure:

- Azure AI Search (vector index + integrated vectorization pipeline)
- Azure OpenAI (chat + embeddings deployments)
- Storage Account + Blob container for documents
- FastAPI app that queries Search and calls Azure OpenAI

## Why this approach

This is a “fully programmatic” RAG setup that splits cleanly into two parts:

- **Control plane (IaC)**: create Azure resources (Search, OpenAI, Storage) reliably and repeatably.
- **Data plane (Search objects)**: configure Search pipeline objects (datasource, skillset, index, indexer) that do the ingestion and vectorization.

It also uses **integrated vectorization** so you can run vector search by sending *text* queries to Search, letting Search apply the index’s configured vectorizer at query-time.

## What you’re building (high level)

1. Upload files to Blob Storage (`kb-docs` container).
2. An Azure AI Search indexer reads blobs, extracts text, splits into chunks, and creates embeddings for those chunks.
3. Your FastAPI `/chat` endpoint sends a hybrid query to Search, receives top chunks, then asks Azure OpenAI to answer using those chunks as context.

## Prereqs

- Azure CLI (`az`) with access to create resources
- Bicep (comes with Azure CLI in most installs)
- Python 3.12+ (for local run)
- PowerShell or Bash (choose the matching scripts)

## 1) Provision Azure resources (control plane)

**What this step does**

- Deploys `infra/main.bicep` to create:
  - Azure AI Search service
  - Azure OpenAI resource + 2 deployments (chat + embeddings)
  - Storage account + `kb-docs` blob container

**Why it matters**

- These are the foundational services; the rest of the setup references their endpoints, names, and keys.

### Bash

```bash
chmod +x scripts/*.sh
./scripts/provision.sh
```

### PowerShell

```powershell
./scripts/provision.ps1
```

Both scripts prompt for required values (RG, location, model names/versions) and deploy `infra/main.bicep`.

## 2) Configure Search pipeline objects (data plane)

**What this step does**

- Creates/updates these Azure AI Search objects (via Search REST API):
  - **Datasource**: points to the `kb-docs` blob container
  - **Skillset**: splits text into chunks and generates embeddings
  - **Index**: stores chunk text + metadata + vector field, and configures a vectorizer for query-time embedding
  - **Indexer**: ties datasource + skillset + index together and runs on a schedule

**Why it matters**

- This is where “RAG ingestion” happens: chunking + embedding + indexing so your API can retrieve relevant passages later.

If you answered “yes” during provisioning, this is already done. Otherwise run:

### Bash

```bash
./scripts/apply-search.sh --rg <rg> --search-name <search> --openai-name <openai> --storage-name <storage> \
  --embed-deployment embeddings --embed-model <embed-model> --embed-dimensions 1536
```

### PowerShell

```powershell
./scripts/apply-search.ps1 -Rg <rg> -SearchName <search> -OpenAIName <openai> -StorageName <storage> `
  -EmbedDeploymentName embeddings -EmbedModelName <embed-model> -EmbedDimensions 1536
```

Templates live in `search/`:

- `search/datasource.json`
- `search/skillset.json`
- `search/index.json`
- `search/indexer.json`

How the templates map to behavior:

- `search/datasource.json`: blob connection and container name.
- `search/skillset.json`: text splitting + Azure OpenAI embedding + index projections (write chunks into the target index).
- `search/index.json`: defines searchable fields plus `contentVector` and a vectorizer (`openai-vectorizer`).
- `search/indexer.json`: schedules ingestion (and can be run on-demand).

## 3) Upload docs + run the indexer

**What this step does**

- Uploads your files to Blob Storage (`kb-docs`).
- Triggers the Search indexer to ingest blobs and populate the Search index with chunks + embeddings.

**Why it matters**

- Until the indexer runs, Search has nothing to retrieve.

Put files under `docs/` (you create this folder), then:

### Bash

```bash
./scripts/upload-docs.sh
./scripts/run-indexer.sh
```

### PowerShell

```powershell
./scripts/upload-docs.ps1
./scripts/run-indexer.ps1
```

## 4) Run the FastAPI locally

**What this step does**

- Starts a local API that:
  - queries Azure AI Search for top relevant chunks
  - calls Azure OpenAI chat completion to generate a grounded answer

**Why it matters**

- This is the “serving layer” you can deploy behind a stable HTTP endpoint.

Create a `.env` from `.env.example` (use outputs from `scripts/provision.*`):

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
cp .env.example .env
uvicorn app.main:app --reload
```

Endpoints:

- `GET /healthz`
- `POST /chat` with JSON: `{ "question": "…", "top_k": 5 }`

## Running tests

**What this step does**

- Runs unit tests for:
  - settings/env parsing
  - client construction (key vs AAD)
  - retrieval request construction
  - FastAPI endpoints and validation

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r requirements-dev.txt
pytest
```

## 5) Deploy the FastAPI to Azure (Container Apps)

This uses `az containerapp up` to build from local source and deploy:

**What this step does**

- Builds the Dockerfile in this repo and deploys it to Azure Container Apps.
- Sets the runtime environment variables the app needs (Search/OpenAI endpoints + keys, deployments, etc.).

**Why it matters**

- You get a public HTTPS endpoint for `/chat` without managing servers.

### Bash

```bash
./scripts/deploy-api-containerapp.sh
```

### PowerShell

```powershell
./scripts/deploy-api-containerapp.ps1
```

## Secrets and variables

### GitHub (Actions)

If you run provisioning/deploy from GitHub Actions, configure one of these authentication options:

- **Recommended (OIDC)**: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID`
- **Alternative (client secret)**: `AZURE_CREDENTIALS` (service principal JSON) or `AZURE_CLIENT_ID` + `AZURE_TENANT_ID` + `AZURE_SUBSCRIPTION_ID` + `AZURE_CLIENT_SECRET`

Non-secret variables you’ll typically want in GitHub Actions (as repo variables or workflow env):

- `RG`, `LOCATION`, `NAME_PREFIX`, `SEARCH_SKU`
- `CHAT_MODEL_NAME`, `CHAT_MODEL_VERSION`
- `EMBED_MODEL_NAME`, `EMBED_MODEL_VERSION`, `EMBED_DIMENSIONS`
- Optional overrides: `CHAT_DEPLOYMENT_NAME`, `EMBED_DEPLOYMENT_NAME`

Permissions for the GitHub identity/service principal:

- Assign **Contributor** on the target resource group (or narrower roles that allow ARM deployments + listing keys for Search/OpenAI).

### Azure (runtime configuration)

The FastAPI app reads the following environment variables (see `.env.example`):

**Secrets**

- `AZURE_SEARCH_API_KEY` (Search query/admin key)
- `AZURE_OPENAI_API_KEY` (OpenAI key)  
  - Optional: omit this to use Managed Identity via `DefaultAzureCredential` (you must grant the app identity access to the Azure OpenAI resource).

**Non-secrets**

- `AZURE_SEARCH_ENDPOINT`, `AZURE_SEARCH_INDEX`, `AZURE_SEARCH_API_VERSION`
- `AZURE_SEARCH_VECTOR_FIELD`, `AZURE_SEARCH_VECTORIZER`, `USE_SEARCH_VECTORIZER`
- `AZURE_OPENAI_ENDPOINT`, `AZURE_OPENAI_API_VERSION`, `AZURE_OPENAI_CHAT_DEPLOYMENT`
- Optional (only if `USE_SEARCH_VECTORIZER=false`): `AZURE_OPENAI_EMBED_DEPLOYMENT`

Where to set them in Azure:

- **Azure Container Apps**: Container App → **Secrets** (for keys) and **Environment variables** (for the rest).

## Notes

- Integrated vectorization requires your Search service and Azure OpenAI resource to be in compatible regions.
- For production, prefer Managed Identity + Key Vault instead of passing keys in env vars.
