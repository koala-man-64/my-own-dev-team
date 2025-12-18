[CmdletBinding()]
param(
  [string]$Rg,
  [string]$SearchName,
  [string]$IndexerName = "kb-indexer",
  [string]$ApiVersion = "2025-09-01"
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
$SearchName = Prompt-IfEmpty $SearchName "Search service name"
$IndexerName = Prompt-IfEmpty $IndexerName "Indexer name" $IndexerName

$searchEndpoint = "https://$SearchName.search.windows.net"

$searchKey = ""
try {
  $searchKey = az search admin-key show -g $Rg --service-name $SearchName --query primaryKey -o tsv
} catch {}
if (-not $searchKey) {
  $searchId = az resource show -g $Rg -n $SearchName --resource-type "Microsoft.Search/searchServices" --query id -o tsv
  $searchKey = az rest --method post --url "https://management.azure.com$searchId/listAdminKeys?api-version=2023-11-01" --query primaryKey -o tsv
}

az rest --method post --url "$searchEndpoint/indexers/$IndexerName/run?api-version=$ApiVersion" --headers "api-key=$searchKey" | Out-Null
Write-Host "Indexer run requested: $IndexerName"

