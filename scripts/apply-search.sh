#!/usr/bin/env bash
set -euo pipefail

command -v az >/dev/null 2>&1 || { echo "Azure CLI (az) is required." >&2; exit 1; }
PYTHON_BIN="${PYTHON_BIN:-}"
if [[ -z "$PYTHON_BIN" ]]; then
  if command -v python3 >/dev/null 2>&1; then PYTHON_BIN="python3"
  elif command -v python >/dev/null 2>&1; then PYTHON_BIN="python"
  else
    echo "Python is required (python3 preferred)." >&2
    exit 1
  fi
fi

RG=""
SEARCH_NAME=""
OPENAI_NAME=""
STORAGE_NAME=""
API_VERSION="2025-09-01"

DATASOURCE_NAME="kb-blob-ds"
SKILLSET_NAME="kb-skillset"
INDEX_NAME="kb-index"
INDEXER_NAME="kb-indexer"

EMBED_DEPLOYMENT=""
EMBED_MODEL=""
EMBED_DIMENSIONS=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rg) RG="$2"; shift 2;;
    --search-name) SEARCH_NAME="$2"; shift 2;;
    --openai-name) OPENAI_NAME="$2"; shift 2;;
    --storage-name) STORAGE_NAME="$2"; shift 2;;
    --api-version) API_VERSION="$2"; shift 2;;
    --datasource-name) DATASOURCE_NAME="$2"; shift 2;;
    --skillset-name) SKILLSET_NAME="$2"; shift 2;;
    --index-name) INDEX_NAME="$2"; shift 2;;
    --indexer-name) INDEXER_NAME="$2"; shift 2;;
    --embed-deployment) EMBED_DEPLOYMENT="$2"; shift 2;;
    --embed-model) EMBED_MODEL="$2"; shift 2;;
    --embed-dimensions) EMBED_DIMENSIONS="$2"; shift 2;;
    *) echo "Unknown argument: $1" >&2; exit 1;;
  esac
done

[[ -n "$RG" ]] || { echo "--rg is required" >&2; exit 1; }
[[ -n "$SEARCH_NAME" ]] || { echo "--search-name is required" >&2; exit 1; }
[[ -n "$OPENAI_NAME" ]] || { echo "--openai-name is required" >&2; exit 1; }
[[ -n "$STORAGE_NAME" ]] || { echo "--storage-name is required" >&2; exit 1; }
[[ -n "$EMBED_DEPLOYMENT" ]] || { echo "--embed-deployment is required" >&2; exit 1; }
[[ -n "$EMBED_MODEL" ]] || { echo "--embed-model is required" >&2; exit 1; }
[[ -n "$EMBED_DIMENSIONS" ]] || { echo "--embed-dimensions is required" >&2; exit 1; }

SEARCH_ENDPOINT="https://${SEARCH_NAME}.search.windows.net"

echo "Fetching Search admin key..."
SEARCH_KEY="$(az search admin-key show -g "$RG" --service-name "$SEARCH_NAME" --query primaryKey -o tsv 2>/dev/null || true)"
if [[ -z "$SEARCH_KEY" ]]; then
  SEARCH_ID="$(az resource show -g "$RG" -n "$SEARCH_NAME" --resource-type "Microsoft.Search/searchServices" --query id -o tsv)"
  SEARCH_KEY="$(az rest --method post --url "https://management.azure.com${SEARCH_ID}/listAdminKeys?api-version=2023-11-01" --query primaryKey -o tsv)"
fi

echo "Fetching Storage connection string..."
STORAGE_CONN="$(az storage account show-connection-string -g "$RG" -n "$STORAGE_NAME" --query connectionString -o tsv)"

echo "Fetching Azure OpenAI endpoint + key..."
AOAI_ENDPOINT="$(az cognitiveservices account show -g "$RG" -n "$OPENAI_NAME" --query properties.endpoint -o tsv)"
AOAI_KEY="$(az cognitiveservices account keys list -g "$RG" -n "$OPENAI_NAME" --query key1 -o tsv)"

export DATASOURCE_NAME SKILLSET_NAME INDEX_NAME INDEXER_NAME
export STORAGE_CONN AOAI_ENDPOINT AOAI_KEY EMBED_DEPLOYMENT EMBED_MODEL EMBED_DIMENSIONS

"$PYTHON_BIN" - <<'PY'
import json, os, pathlib

root = pathlib.Path("search")
def load(name): return json.loads((root / name).read_text(encoding="utf-8"))
def dump(name, obj): (root / name).write_text(json.dumps(obj, indent=2) + "\n", encoding="utf-8")

ds = load("datasource.json")
ds["name"] = os.environ["DATASOURCE_NAME"]
ds["credentials"]["connectionString"] = os.environ["STORAGE_CONN"]
dump(".datasource.rendered.json", ds)

skillset = load("skillset.json")
skillset["name"] = os.environ["SKILLSET_NAME"]
for skill in skillset.get("skills", []):
  if skill.get("name") == "embed":
    skill["resourceUri"] = os.environ["AOAI_ENDPOINT"]
    skill["apiKey"] = os.environ["AOAI_KEY"]
    skill["deploymentId"] = os.environ["EMBED_DEPLOYMENT"]
    skill["modelName"] = os.environ["EMBED_MODEL"]
    skill["dimensions"] = int(os.environ["EMBED_DIMENSIONS"])
skillset["indexProjections"]["selectors"][0]["targetIndexName"] = os.environ["INDEX_NAME"]
dump(".skillset.rendered.json", skillset)

index = load("index.json")
index["name"] = os.environ["INDEX_NAME"]
for field in index.get("fields", []):
  if field.get("name") == "contentVector":
    field["dimensions"] = int(os.environ["EMBED_DIMENSIONS"])
for v in index.get("vectorSearch", {}).get("vectorizers", []):
  if v.get("name") == "openai-vectorizer":
    params = v.setdefault("azureOpenAIParameters", {})
    params["resourceUri"] = os.environ["AOAI_ENDPOINT"]
    params["apiKey"] = os.environ["AOAI_KEY"]
    params["deploymentId"] = os.environ["EMBED_DEPLOYMENT"]
    params["modelName"] = os.environ["EMBED_MODEL"]
dump(".index.rendered.json", index)

indexer = load("indexer.json")
indexer["name"] = os.environ["INDEXER_NAME"]
indexer["dataSourceName"] = os.environ["DATASOURCE_NAME"]
indexer["skillsetName"] = os.environ["SKILLSET_NAME"]
indexer["targetIndexName"] = os.environ["INDEX_NAME"]
dump(".indexer.rendered.json", indexer)
PY

HDRS=("Content-Type=application/json" "api-key=${SEARCH_KEY}")

echo "Upserting datasource..."
az rest --method put --url "${SEARCH_ENDPOINT}/datasources/${DATASOURCE_NAME}?api-version=${API_VERSION}" --headers "${HDRS[@]}" --body "@search/.datasource.rendered.json" >/dev/null

echo "Upserting skillset..."
az rest --method put --url "${SEARCH_ENDPOINT}/skillsets/${SKILLSET_NAME}?api-version=${API_VERSION}" --headers "${HDRS[@]}" --body "@search/.skillset.rendered.json" >/dev/null

echo "Upserting index..."
az rest --method put --url "${SEARCH_ENDPOINT}/indexes/${INDEX_NAME}?api-version=${API_VERSION}" --headers "${HDRS[@]}" --body "@search/.index.rendered.json" >/dev/null

echo "Upserting indexer..."
az rest --method put --url "${SEARCH_ENDPOINT}/indexers/${INDEXER_NAME}?api-version=${API_VERSION}" --headers "${HDRS[@]}" --body "@search/.indexer.rendered.json" >/dev/null

echo "Done."
echo "Next: upload docs to the 'kb-docs' container, then run:"
echo "  az rest --method post --url \"${SEARCH_ENDPOINT}/indexers/${INDEXER_NAME}/run?api-version=${API_VERSION}\" --headers \"api-key=${SEARCH_KEY}\""
