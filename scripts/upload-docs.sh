#!/usr/bin/env bash
set -euo pipefail

command -v az >/dev/null 2>&1 || { echo "Azure CLI (az) is required." >&2; exit 1; }

RG="${RG:-}"
STORAGE_NAME="${STORAGE_NAME:-}"
CONTAINER="${CONTAINER:-kb-docs}"
DOCS_DIR="${DOCS_DIR:-docs}"

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
prompt STORAGE_NAME "Storage account name"
prompt DOCS_DIR "Local docs folder" "$DOCS_DIR"

if [[ ! -d "$DOCS_DIR" ]]; then
  echo "Docs folder not found: $DOCS_DIR" >&2
  exit 1
fi

az storage blob upload-batch \
  --account-name "$STORAGE_NAME" \
  --destination "$CONTAINER" \
  --source "$DOCS_DIR" \
  --auth-mode login \
  >/dev/null

echo "Uploaded docs from ${DOCS_DIR} to ${STORAGE_NAME}/${CONTAINER}"

