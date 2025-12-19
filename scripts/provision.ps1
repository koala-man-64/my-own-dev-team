[CmdletBinding()]
param(
  [string]$Rg,
  [string]$Location,
  [string]$NamePrefix,
  [ValidateSet('S1','S2','S3')]
  [string]$SearchSku = "S1",

  [string]$ChatModelName,
  [string]$ChatModelVersion,
  [string]$EmbedModelName,
  [string]$EmbedModelVersion,

  [string]$ChatDeploymentName = "chat",
  [string]$EmbedDeploymentName = "embeddings"
)

function Prompt-IfEmpty([string]$Value, [string]$Label, [string]$Default = "") {
  if ($Value -and $Value.Trim().Length -gt 0) { return $Value.Trim() }
  if ($Default -and $Default.Trim().Length -gt 0) {
    $entered = Read-Host "$Label [$Default]"
    if (-not $entered -or $entered.Trim().Length -eq 0) { return $Default.Trim() }
    return $entered.Trim()
  }
  $entered = Read-Host $Label
  if (-not $entered -or $entered.Trim().Length -eq 0) { throw "Missing required value: $Label" }
  return $entered.Trim()
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
  throw "Azure CLI (az) is required."
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Push-Location $RepoRoot
try {
  if (-not $PSBoundParameters.ContainsKey('Rg') -and $env:RG) { $Rg = $env:RG }
  if (-not $PSBoundParameters.ContainsKey('Location') -and $env:LOCATION) { $Location = $env:LOCATION }
  if (-not $PSBoundParameters.ContainsKey('NamePrefix') -and $env:NAME_PREFIX) { $NamePrefix = $env:NAME_PREFIX }
  if (-not $PSBoundParameters.ContainsKey('SearchSku') -and $env:SEARCH_SKU) { $SearchSku = $env:SEARCH_SKU }
  if (-not $PSBoundParameters.ContainsKey('ChatModelName') -and $env:CHAT_MODEL_NAME) { $ChatModelName = $env:CHAT_MODEL_NAME }
  if (-not $PSBoundParameters.ContainsKey('ChatModelVersion') -and $env:CHAT_MODEL_VERSION) { $ChatModelVersion = $env:CHAT_MODEL_VERSION }
  if (-not $PSBoundParameters.ContainsKey('EmbedModelName') -and $env:EMBED_MODEL_NAME) { $EmbedModelName = $env:EMBED_MODEL_NAME }
  if (-not $PSBoundParameters.ContainsKey('EmbedModelVersion') -and $env:EMBED_MODEL_VERSION) { $EmbedModelVersion = $env:EMBED_MODEL_VERSION }
  if (-not $PSBoundParameters.ContainsKey('ChatDeploymentName') -and $env:CHAT_DEPLOYMENT_NAME) { $ChatDeploymentName = $env:CHAT_DEPLOYMENT_NAME }
  if (-not $PSBoundParameters.ContainsKey('EmbedDeploymentName') -and $env:EMBED_DEPLOYMENT_NAME) { $EmbedDeploymentName = $env:EMBED_DEPLOYMENT_NAME }

  if ($SearchSku) { $SearchSku = $SearchSku.Trim().ToUpperInvariant() }
  if ($SearchSku -notin @('S1','S2','S3')) { throw "Invalid SearchSku: $SearchSku (must be S1, S2, or S3)" }

  $Rg = Prompt-IfEmpty $Rg "Resource group" "rg-rag"
  $Location = Prompt-IfEmpty $Location "Location" "eastus"
  $NamePrefix = Prompt-IfEmpty $NamePrefix "Name prefix" "ragdemo"

  $ChatModelName = Prompt-IfEmpty $ChatModelName "Chat model name (e.g. gpt-4o-mini)" "gpt-4o-mini"
  $chatModelVersionDefault = ""
  if ($ChatModelName -eq "gpt-4o-mini") { $chatModelVersionDefault = "2024-07-18" }
  $ChatModelVersion = Prompt-IfEmpty $ChatModelVersion "Chat model version (e.g. 2024-07-18)" $chatModelVersionDefault

  $EmbedModelName = Prompt-IfEmpty $EmbedModelName "Embedding model name (e.g. text-embedding-3-small)" "text-embedding-3-small"
  $embedModelVersionDefault = ""
  if ($EmbedModelName -like "text-embedding-3-*") { $embedModelVersionDefault = "1" }
  $EmbedModelVersion = Prompt-IfEmpty $EmbedModelVersion "Embedding model version (e.g. 1)" $embedModelVersionDefault

  Write-Host "Creating resource group..."
  az group create -n $Rg -l $Location | Out-Null

  $deploymentName = "rag-$NamePrefix-$(Get-Date -Format yyyyMMddHHmmss)"
  $bicepFile = Join-Path $RepoRoot "infra/main.bicep"
  Write-Host "Deploying $bicepFile ($deploymentName)..."
  az deployment group create `
    -g $Rg `
    -n $deploymentName `
    -f $bicepFile `
    -p location=$Location `
    -p namePrefix=$NamePrefix `
    -p searchSku=$SearchSku `
    -p chatModelName=$ChatModelName `
    -p chatModelVersion=$ChatModelVersion `
    -p embedModelName=$EmbedModelName `
    -p embedModelVersion=$EmbedModelVersion `
    -p chatDeploymentName=$ChatDeploymentName `
    -p embedDeploymentName=$EmbedDeploymentName `
    | Out-Null

  $outputs = az deployment group show -g $Rg -n $deploymentName --query properties.outputs -o json | ConvertFrom-Json
  $searchName = $outputs.searchServiceName.value
  $openaiName = $outputs.openaiAccountName.value
  $storageName = $outputs.storageAccountName.value

  Write-Host ""
  Write-Host "Outputs:"
  Write-Host "  Search:   $searchName ($($outputs.searchEndpoint.value))"
  Write-Host "  OpenAI:   $openaiName ($($outputs.openaiEndpoint.value))"
  Write-Host "  Storage:  $storageName ($($outputs.storageContainerName.value))"
  Write-Host "  Chat dep: $($outputs.chatDeployment.value)"
  Write-Host "  Emb dep:  $($outputs.embedDeployment.value)"
  Write-Host ""

  $apply = Read-Host "Configure Azure AI Search objects now (datasource/skillset/index/indexer)? [Y/n]"
  if (-not $apply) { $apply = "Y" }
  if ($apply -match "^[Yy]$") {
    $embedDimensions = Read-Host "Embedding dimensions (e.g. 1536 or 3072)"
    if (-not $embedDimensions) { throw "Embedding dimensions required." }

    & (Join-Path $PSScriptRoot "apply-search.ps1") `
      -Rg $Rg `
      -SearchName $searchName `
      -OpenAIName $openaiName `
      -StorageName $storageName `
      -EmbedDeploymentName $EmbedDeploymentName `
      -EmbedModelName $EmbedModelName `
      -EmbedDimensions ([int]$embedDimensions)
  }
} finally {
  Pop-Location
}

