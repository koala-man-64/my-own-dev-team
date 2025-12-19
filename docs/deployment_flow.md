# Deployment & Setup Flow (Azure Resources + Ingestion + API)

This document describes the “setup” and “deployment” path for this repo end-to-end. It is structured so you can convert it directly into a flow chart or swimlane diagram.

## Technologies and responsibilities

- **Developer workstation / CI runner (GitHub Actions)**: runs scripts, builds, and tests.
- **Git + GitHub**: source control and CI trigger.
- **Azure CLI (`az`)**: executes ARM deployments and calls Azure service APIs.
- **Bicep / ARM (control plane)**: provisions Azure resources declared in `infra/main.bicep`.
- **Azure AI Search**
  - **Management plane**: retrieve admin keys (when needed).
  - **Data plane REST API**: create datasource/skillset/index/indexer and run the indexer.
- **Azure OpenAI**
  - **Management plane**: creates the OpenAI account + model deployments via Bicep.
  - **Data plane**: used by Search skillset (embeddings) and the API (chat completions).
- **Azure Storage (Blob)**: stores source documents in the `kb-docs` container.
- **Azure Container Apps**: hosts the FastAPI container with external HTTPS ingress.
- **Docker build (via `az containerapp up`)**: builds the container image from this repo’s `Dockerfile` and deploys it.

## Inputs (values you provide)

These are prompted for by `scripts/provision.sh` / `scripts/provision.ps1`:

- **Azure scope**: `RG` (resource group), `LOCATION`
- **Naming**: `NAME_PREFIX` (drives resource names)
- **Search**: `SEARCH_SKU` (`standard`, `standard2`, `standard3`; aliases `S1`, `S2`, `S3`)
- **OpenAI deployments**:
  - chat: `CHAT_MODEL_NAME`, `CHAT_MODEL_VERSION`, `CHAT_DEPLOYMENT_NAME` (default `chat`)
  - embeddings: `EMBED_MODEL_NAME`, `EMBED_MODEL_VERSION`, `EMBED_DEPLOYMENT_NAME` (default `embeddings`)

These are prompted for when configuring the Search index/skillset:

- **Embedding dimensions**: `EMBED_DIMENSIONS` (must match the chosen embedding model)

## Artifacts created (what exists after setup)

- **Azure resources (control plane)**:
  - Azure AI Search service
  - Azure OpenAI account + 2 deployments (chat + embeddings)
  - Storage account + `kb-docs` blob container
- **Azure AI Search objects (data plane)**:
  - datasource: `kb-blob-ds`
  - skillset: `kb-skillset` (chunking + embedding)
  - index: `kb-index` (stores chunk text + metadata + vectors)
  - indexer: `kb-indexer` (ties the above together; scheduled + on-demand run)
- **Indexed data**:
  - chunk documents and vectors in the Search index (created by the indexer)
- **API hosting (optional)**:
  - Azure Container App running the FastAPI service, with env vars/secrets configured

## Swimlanes (systems/actors)

- **Developer / CI**
- **Azure Resource Manager (Bicep/ARM)**
- **Azure AI Search (mgmt + data plane)**
- **Azure Storage (Blob)**
- **Azure OpenAI (mgmt + data plane)**
- **Azure Container Apps**

## Deployment sequence (phases)

### Phase A: Provision Azure resources (control plane)

**Entry points**

- Bash: `scripts/provision.sh`
- PowerShell: `scripts/provision.ps1`

**Steps**

1. **Developer/CI → Azure CLI**: authenticate (`az login`) and select subscription (if needed).
2. **Developer/CI → Azure CLI**: create resource group (`az group create`).
3. **Developer/CI → ARM (Bicep)**: deploy `infra/main.bicep` (`az deployment group create`).
4. **ARM creates resources**:
   - Search service
   - OpenAI account + chat/embedding deployments
   - Storage account + `kb-docs` container
5. **Azure CLI returns outputs** (names/endpoints) that are later used for Search configuration and app runtime config.

### Phase B: Configure Azure AI Search pipeline objects (data plane)

**Entry points**

- Bash: `scripts/apply-search.sh`
- PowerShell: `scripts/apply-search.ps1`

**Purpose**

- Create the Search “ingestion pipeline” objects that turn blobs into a vector-searchable index.

**Steps**

1. **Developer/CI → Azure CLI**: fetch required secrets/config:
   - Search admin key (management plane)
   - Storage connection string
   - Azure OpenAI endpoint + key
2. **Render templates**:
   - Reads JSON templates from `search/`
   - Writes rendered files `search/.datasource.rendered.json`, `search/.skillset.rendered.json`, `search/.index.rendered.json`, `search/.indexer.rendered.json`
3. **Upsert Search objects (REST PUT)**:
   - datasource → `datasources/{name}`
   - skillset → `skillsets/{name}`
   - index → `indexes/{name}`
   - indexer → `indexers/{name}`

### Phase C: Upload documents and run ingestion

**Entry points**

- Bash: `scripts/upload-docs.sh` then `scripts/run-indexer.sh`
- PowerShell: `scripts/upload-docs.ps1` then `scripts/run-indexer.ps1`

**Steps**

1. **Developer/CI → Azure Storage**: upload local files from `docs/` into the `kb-docs` blob container.
2. **Developer/CI → Azure AI Search**: trigger the indexer run (`POST /indexers/{indexer}/run`).
3. **Azure AI Search indexer pipeline executes**:
   - reads blobs
   - extracts text/metadata
   - chunks text (Split skill)
   - embeds chunks (Azure OpenAI embedding skill)
   - writes chunk documents + vectors into the Search index (`kb-index`)

### Phase D: Local setup (developer validation)

**Purpose**

- Validate the API behavior and configuration before deploying.

**Steps**

1. Create `.env` from `.env.example` and fill in endpoints/keys/deployments.
2. Install dependencies (`pip install -r requirements.txt`).
3. Run the API locally (`uvicorn app.main:app --reload`).
4. Call `GET /healthz` and `POST /chat` to verify retrieval + generation.

### Phase E: Deploy the FastAPI service to Azure Container Apps (optional)

**Entry points**

- Bash: `scripts/deploy-api-containerapp.sh`
- PowerShell: `scripts/deploy-api-containerapp.ps1`

**Steps**

1. **Developer/CI → Azure CLI**: fetch runtime values:
   - Search endpoint + key
   - Azure OpenAI endpoint + key
2. **Developer/CI → Azure Container Apps**: run `az containerapp up --source .`
   - builds the container image using `Dockerfile`
   - deploys a Container App with external ingress on port `8000`
   - sets env vars/secrets needed by the app (Search/OpenAI config)
3. **Azure CLI outputs the FQDN** for the deployed API (call `/healthz` and `/chat`).

### Phase F: CI tests on push (GitHub Actions)

**Entry point**

- `.github/workflows/tests.yml`

**Steps**

1. A `push` or `pull_request` triggers the workflow.
2. GitHub Actions checks out the repo.
3. Installs `requirements-dev.txt`.
4. Runs `pytest`.

## Flow-chart node list (IDs + edges)

Use these as boxes/diamonds in a diagram.

### Nodes

- **N0** Start
- **N1** Choose execution environment (Local vs GitHub Actions)
- **N2** Authenticate to Azure (`az login`)
- **N3** Run provisioning script (`scripts/provision.*`)
- **N4** ARM deploys `infra/main.bicep`
- **N5** Capture outputs (Search/OpenAI/Storage names + endpoints)
- **D1** Configure Search objects now?
- **N6** Run apply script (`scripts/apply-search.*`)
- **N7** Upsert datasource/skillset/index/indexer (Search REST)
- **N8** Upload documents to Blob (`scripts/upload-docs.*`)
- **N9** Trigger indexer run (`scripts/run-indexer.*`)
- **N10** Indexer populates Search index (chunks + vectors)
- **D2** Validate locally?
- **N11** Configure `.env` and run `uvicorn`
- **D3** Deploy API to Azure?
- **N12** Run Container Apps deploy script (`scripts/deploy-api-containerapp.*`)
- **N13** Container App deployed; FQDN available
- **N14** (CI) Run tests workflow (`pytest`)
- **E1** Stop on failure (auth/ARM/Search/Storage/OpenAI/build)
- **N15** Done

### Edges

- N0 → N1
- N1 (Local) → N2
- N1 (GitHub Actions) → N14 → N2 (only if you also deploy from CI)
- N2 → N3 → N4 → N5 → D1
- D1 (Yes) → N6 → N7
- D1 (No) → N8
- N7 → N8 → N9 → N10 → D2
- D2 (Yes) → N11 → D3
- D2 (No) → D3
- D3 (Yes) → N12 → N13 → N15
- D3 (No) → N15
- Any node failure → E1

## Common failure points (for diagramming)

- **Model availability/region**: Bicep succeeds, but OpenAI deployment creation can fail if the model/version isn’t available in the selected region.
- **Search/OpenAI permissions**: insufficient roles prevent creating resources or listing keys.
- **Embedding dimensions mismatch**: Search index requires the vector field dimensions to match the embedding model output size.
- **Indexer ingestion errors**: document parsing/extraction problems or OpenAI throttling can cause partial ingestion.
- **Container build/deploy issues**: `az containerapp up` requires the ability to build and push an image; failures often surface as build logs.
