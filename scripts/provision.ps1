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

$Rg = Prompt-IfEmpty $Rg "Resource group" "rg-rag"
$Location = Prompt-IfEmpty $Location "Location" "eastus"
$NamePrefix = Prompt-IfEmpty $NamePrefix "Name prefix" "ragdemo"

$ChatModelName = Prompt-IfEmpty $ChatModelName "Chat model name (e.g. gpt-4o-mini)"
$ChatModelVersion = Prompt-IfEmpty $ChatModelVersion "Chat model version"
$EmbedModelName = Prompt-IfEmpty $EmbedModelName "Embedding model name (e.g. text-embedding-3-small)"
$EmbedModelVersion = Prompt-IfEmpty $EmbedModelVersion "Embedding model version"

Write-Host "Creating resource group..."
az group create -n $Rg -l $Location | Out-Null

$deploymentName = "rag-$NamePrefix-$(Get-Date -Format yyyyMMddHHmmss)"
Write-Host "Deploying infra/main.bicep ($deploymentName)..."
az deployment group create `
  -g $Rg `
  -n $deploymentName `
  -f infra/main.bicep `
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

  & "$PSScriptRoot/apply-search.ps1" `
    -Rg $Rg `
    -SearchName $searchName `
    -OpenAIName $openaiName `
    -StorageName $storageName `
    -EmbedDeploymentName $EmbedDeploymentName `
    -EmbedModelName $EmbedModelName `
    -EmbedDimensions ([int]$embedDimensions)
}

