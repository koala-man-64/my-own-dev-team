#!/usr/bin/env bash
set -euo pipefail

RG="${RG:-}"
SEARCH_NAME="${SEARCH_NAME:-}"
INDEXER_NAME="${INDEXER_NAME:-kb-indexer}"
API_VERSION="${API_VERSION:-2025-09-01}"

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

command -v az >/dev/null 2>&1 || { echo "Azure CLI (az) is required." >&2; exit 1; }

prompt RG "Resource group"
prompt SEARCH_NAME "Search service name"
prompt INDEXER_NAME "Indexer name" "$INDEXER_NAME"

SEARCH_ENDPOINT="https://${SEARCH_NAME}.search.windows.net"
SEARCH_KEY="$(az search admin-key show -g "$RG" --service-name "$SEARCH_NAME" --query primaryKey -o tsv 2>/dev/null || true)"
if [[ -z "$SEARCH_KEY" ]]; then
  SEARCH_ID="$(az resource show -g "$RG" -n "$SEARCH_NAME" --resource-type "Microsoft.Search/searchServices" --query id -o tsv)"
  SEARCH_KEY="$(az rest --method post --url "https://management.azure.com${SEARCH_ID}/listAdminKeys?api-version=2023-11-01" --query primaryKey -o tsv)"
fi

az rest --method post --url "${SEARCH_ENDPOINT}/indexers/${INDEXER_NAME}/run?api-version=${API_VERSION}" --headers "api-key=${SEARCH_KEY}" >/dev/null
echo "Indexer run requested: ${INDEXER_NAME}"

