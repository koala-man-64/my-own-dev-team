[CmdletBinding()]
param(
  [string]$Rg,
  [string]$Location,
  [string]$AppName,
  [string]$SearchName,
  [string]$OpenAIName,

  [string]$SearchIndex = "kb-index",
  [string]$ChatDeployment = "chat",
  [string]$EmbedDeployment = "embeddings",
  [string]$SearchApiVersion = "2025-09-01",
  [string]$OpenAIApiVersion = "2024-02-15-preview"
)

function Prompt-IfEmpty([string]$Value, [string]$Label, [string]$Default = "") {
  if ($Value -and $Value.Trim().Length -gt 0) { return $Value }
  if ($Default -and $Default.Trim().Length -gt 0) {
    $entered = Read-Host "$Label [$Default]"
    if (-not $entered) { return $Default }
    return $entered
  }
  $entered = Read-Host $Label
  if (-not $entered) { throw "Missing required value: $Label" }
  return $entered
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
  throw "Azure CLI (az) is required."
}

$Rg = Prompt-IfEmpty $Rg "Resource group"
$Location = Prompt-IfEmpty $Location "Location" "eastus"
$AppName = Prompt-IfEmpty $AppName "Container App name" "rag-api"
$SearchName = Prompt-IfEmpty $SearchName "Search service name"
$OpenAIName = Prompt-IfEmpty $OpenAIName "Azure OpenAI account name"

$searchEndpoint = "https://$SearchName.search.windows.net"
$openaiEndpoint = az cognitiveservices account show -g $Rg -n $OpenAIName --query properties.endpoint -o tsv
$openaiKey = az cognitiveservices account keys list -g $Rg -n $OpenAIName --query key1 -o tsv

$searchKey = ""
try {
  $searchKey = az search admin-key show -g $Rg --service-name $SearchName --query primaryKey -o tsv
} catch {}
if (-not $searchKey) {
  $searchId = az resource show -g $Rg -n $SearchName --resource-type "Microsoft.Search/searchServices" --query id -o tsv
  $searchKey = az rest --method post --url "https://management.azure.com$searchId/listAdminKeys?api-version=2023-11-01" --query primaryKey -o tsv
}

Write-Host "Deploying FastAPI to Azure Container Apps (builds from local source)..."
az containerapp up `
  --name $AppName `
  --resource-group $Rg `
  --location $Location `
  --source . `
  --ingress external `
  --target-port 8000 `
  --env-vars `
    AZURE_SEARCH_ENDPOINT=$searchEndpoint `
    AZURE_SEARCH_INDEX=$SearchIndex `
    AZURE_SEARCH_API_VERSION=$SearchApiVersion `
    AZURE_SEARCH_API_KEY=$searchKey `
    AZURE_OPENAI_ENDPOINT=$openaiEndpoint `
    AZURE_OPENAI_API_VERSION=$OpenAIApiVersion `
    AZURE_OPENAI_CHAT_DEPLOYMENT=$ChatDeployment `
    AZURE_OPENAI_EMBED_DEPLOYMENT=$EmbedDeployment `
    AZURE_OPENAI_API_KEY=$openaiKey `
    USE_SEARCH_VECTORIZER=true `
  | Out-Null

$fqdn = az containerapp show -g $Rg -n $AppName --query properties.configuration.ingress.fqdn -o tsv
Write-Host "Deployed: https://$fqdn"

