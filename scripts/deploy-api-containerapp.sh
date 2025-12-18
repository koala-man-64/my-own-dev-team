#!/usr/bin/env bash
set -euo pipefail

command -v az >/dev/null 2>&1 || { echo "Azure CLI (az) is required." >&2; exit 1; }

RG="${RG:-}"
LOCATION="${LOCATION:-}"
APP_NAME="${APP_NAME:-}"

SEARCH_NAME="${SEARCH_NAME:-}"
OPENAI_NAME="${OPENAI_NAME:-}"
SEARCH_INDEX="${SEARCH_INDEX:-kb-index}"

CHAT_DEPLOYMENT="${CHAT_DEPLOYMENT:-chat}"
EMBED_DEPLOYMENT="${EMBED_DEPLOYMENT:-embeddings}"
SEARCH_API_VERSION="${SEARCH_API_VERSION:-2025-09-01}"
OPENAI_API_VERSION="${OPENAI_API_VERSION:-2024-02-15-preview}"

prompt() {
  local name="$1" label="$2" default_value="${3:-}" value="${!name:-}"
  if [[ -n "$value" ]]; then return 0; fi
  if [[ -n "$default_value" ]]; then
    read -r -p "${label} [${default_value}]: " value
    value="${value:-$default_value}"
  else
    read -r -p "${label}: " value
  fi
  [[ -n "$value" ]] || { echo "Missing required value: ${label}" >&2; exit 1; }
  printf -v "$name" '%s' "$value"
  export "$name"
}

prompt RG "Resource group"
prompt LOCATION "Location" "eastus"
prompt APP_NAME "Container App name" "rag-api"
prompt SEARCH_NAME "Search service name"
prompt OPENAI_NAME "Azure OpenAI account name"

SEARCH_ENDPOINT="https://${SEARCH_NAME}.search.windows.net"
OPENAI_ENDPOINT="$(az cognitiveservices account show -g "$RG" -n "$OPENAI_NAME" --query properties.endpoint -o tsv)"
OPENAI_KEY="$(az cognitiveservices account keys list -g "$RG" -n "$OPENAI_NAME" --query key1 -o tsv)"

SEARCH_KEY="$(az search admin-key show -g "$RG" --service-name "$SEARCH_NAME" --query primaryKey -o tsv 2>/dev/null || true)"
if [[ -z "$SEARCH_KEY" ]]; then
  SEARCH_ID="$(az resource show -g "$RG" -n "$SEARCH_NAME" --resource-type "Microsoft.Search/searchServices" --query id -o tsv)"
  SEARCH_KEY="$(az rest --method post --url "https://management.azure.com${SEARCH_ID}/listAdminKeys?api-version=2023-11-01" --query primaryKey -o tsv)"
fi

echo "Deploying FastAPI to Azure Container Apps (builds from local source)..."
az containerapp up \
  --name "$APP_NAME" \
  --resource-group "$RG" \
  --location "$LOCATION" \
  --source . \
  --ingress external \
  --target-port 8000 \
  --env-vars \
    AZURE_SEARCH_ENDPOINT="$SEARCH_ENDPOINT" \
    AZURE_SEARCH_INDEX="$SEARCH_INDEX" \
    AZURE_SEARCH_API_VERSION="$SEARCH_API_VERSION" \
    AZURE_SEARCH_API_KEY="$SEARCH_KEY" \
    AZURE_OPENAI_ENDPOINT="$OPENAI_ENDPOINT" \
    AZURE_OPENAI_API_VERSION="$OPENAI_API_VERSION" \
    AZURE_OPENAI_CHAT_DEPLOYMENT="$CHAT_DEPLOYMENT" \
    AZURE_OPENAI_EMBED_DEPLOYMENT="$EMBED_DEPLOYMENT" \
    AZURE_OPENAI_API_KEY="$OPENAI_KEY" \
    USE_SEARCH_VECTORIZER=true \
  >/dev/null

FQDN="$(az containerapp show -g "$RG" -n "$APP_NAME" --query properties.configuration.ingress.fqdn -o tsv)"
echo "Deployed: https://${FQDN}"

