#!/usr/bin/env bash
set -euo pipefail

prompt() {
  local var_name="$1"
  local label="$2"
  local default_value="${3:-}"
  local current_value="${!var_name:-}"

  if [[ -n "$current_value" ]]; then
    return 0
  fi

  if [[ -n "$default_value" ]]; then
    read -r -p "${label} [${default_value}]: " current_value
    current_value="${current_value:-$default_value}"
  else
    read -r -p "${label}: " current_value
  fi

  if [[ -z "$current_value" ]]; then
    echo "Missing required value: ${label}" >&2
    exit 1
  fi

  printf -v "$var_name" '%s' "$current_value"
  export "$var_name"
}

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

RG="${RG:-}"
LOCATION="${LOCATION:-}"
NAME_PREFIX="${NAME_PREFIX:-}"
SEARCH_SKU="${SEARCH_SKU:-S1}"
CHAT_MODEL_NAME="${CHAT_MODEL_NAME:-}"
CHAT_MODEL_VERSION="${CHAT_MODEL_VERSION:-}"
EMBED_MODEL_NAME="${EMBED_MODEL_NAME:-}"
EMBED_MODEL_VERSION="${EMBED_MODEL_VERSION:-}"
CHAT_DEPLOYMENT_NAME="${CHAT_DEPLOYMENT_NAME:-chat}"
EMBED_DEPLOYMENT_NAME="${EMBED_DEPLOYMENT_NAME:-embeddings}"

prompt RG "Resource group" "rg-rag"
prompt LOCATION "Location" "eastus"
prompt NAME_PREFIX "Name prefix" "ragdemo"
prompt CHAT_MODEL_NAME "Chat model name (e.g. gpt-4o-mini)"
prompt CHAT_MODEL_VERSION "Chat model version"
prompt EMBED_MODEL_NAME "Embedding model name (e.g. text-embedding-3-small)"
prompt EMBED_MODEL_VERSION "Embedding model version"

echo "Creating resource group..."
az group create -n "$RG" -l "$LOCATION" >/dev/null

echo "Deploying infra/main.bicep..."
DEPLOYMENT_NAME="rag-${NAME_PREFIX}-$(date +%Y%m%d%H%M%S)"
az deployment group create \
  -g "$RG" \
  -n "$DEPLOYMENT_NAME" \
  -f infra/main.bicep \
  -p location="$LOCATION" \
  -p namePrefix="$NAME_PREFIX" \
  -p searchSku="$SEARCH_SKU" \
  -p chatModelName="$CHAT_MODEL_NAME" \
  -p chatModelVersion="$CHAT_MODEL_VERSION" \
  -p embedModelName="$EMBED_MODEL_NAME" \
  -p embedModelVersion="$EMBED_MODEL_VERSION" \
  -p chatDeploymentName="$CHAT_DEPLOYMENT_NAME" \
  -p embedDeploymentName="$EMBED_DEPLOYMENT_NAME" \
  >/dev/null

echo "Reading deployment outputs..."
OUTPUTS_JSON="$(az deployment group show -g "$RG" -n "$DEPLOYMENT_NAME" --query properties.outputs -o json)"
"$PYTHON_BIN" - <<'PY'
import json, os
o = json.loads(os.environ["OUTPUTS_JSON"])
def val(k): return o[k]["value"]
print("searchServiceName=", val("searchServiceName"))
print("searchEndpoint=", val("searchEndpoint"))
print("openaiAccountName=", val("openaiAccountName"))
print("openaiEndpoint=", val("openaiEndpoint"))
print("storageAccountName=", val("storageAccountName"))
print("storageContainerName=", val("storageContainerName"))
print("chatDeployment=", val("chatDeployment"))
print("embedDeployment=", val("embedDeployment"))
PY

read -r -p "Configure Azure AI Search objects now (datasource/skillset/index/indexer)? [Y/n]: " DO_APPLY
DO_APPLY="${DO_APPLY:-Y}"
if [[ "$DO_APPLY" =~ ^[Yy]$ ]]; then
  EMBED_DIMENSIONS="${EMBED_DIMENSIONS:-}"
  prompt EMBED_DIMENSIONS "Embedding dimensions (e.g. 1536 or 3072)"

  export OUTPUTS_JSON
  SEARCH_NAME="$("$PYTHON_BIN" - <<'PY'
import json, os
o=json.loads(os.environ["OUTPUTS_JSON"])
print(o["searchServiceName"]["value"])
PY
)"
  OPENAI_NAME="$("$PYTHON_BIN" - <<'PY'
import json, os
o=json.loads(os.environ["OUTPUTS_JSON"])
print(o["openaiAccountName"]["value"])
PY
)"
  STORAGE_NAME="$("$PYTHON_BIN" - <<'PY'
import json, os
o=json.loads(os.environ["OUTPUTS_JSON"])
print(o["storageAccountName"]["value"])
PY
)"

  ./scripts/apply-search.sh \
    --rg "$RG" \
    --search-name "$SEARCH_NAME" \
    --openai-name "$OPENAI_NAME" \
    --storage-name "$STORAGE_NAME" \
    --embed-deployment "$EMBED_DEPLOYMENT_NAME" \
    --embed-model "$EMBED_MODEL_NAME" \
    --embed-dimensions "$EMBED_DIMENSIONS"
fi
