[CmdletBinding()]
param(
  [string]$Rg,
  [string]$SearchName,
  [string]$OpenAIName,
  [string]$StorageName,

  [string]$ApiVersion = "2025-09-01",

  [string]$DataSourceName = "kb-blob-ds",
  [string]$SkillsetName = "kb-skillset",
  [string]$IndexName = "kb-index",
  [string]$IndexerName = "kb-indexer",

  [string]$EmbedDeploymentName,
  [string]$EmbedModelName,
  [int]$EmbedDimensions
)

function Prompt-IfEmpty([string]$Value, [string]$Label) {
  if ($Value -and $Value.Trim().Length -gt 0) { return $Value }
  $entered = Read-Host $Label
  if (-not $entered) { throw "Missing required value: $Label" }
  return $entered
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
  throw "Azure CLI (az) is required."
}

$Rg = Prompt-IfEmpty $Rg "Resource group"
$SearchName = Prompt-IfEmpty $SearchName "Search service name"
$OpenAIName = Prompt-IfEmpty $OpenAIName "Azure OpenAI account name"
$StorageName = Prompt-IfEmpty $StorageName "Storage account name"
$EmbedDeploymentName = Prompt-IfEmpty $EmbedDeploymentName "Embedding deployment name"
$EmbedModelName = Prompt-IfEmpty $EmbedModelName "Embedding model name"
if (-not $EmbedDimensions) { $EmbedDimensions = [int](Prompt-IfEmpty "" "Embedding dimensions (e.g. 1536 or 3072)") }

$searchEndpoint = "https://$SearchName.search.windows.net"

Write-Host "Fetching Search admin key..."
$searchKey = ""
try {
  $searchKey = az search admin-key show -g $Rg --service-name $SearchName --query primaryKey -o tsv
} catch {}
if (-not $searchKey) {
  $searchId = az resource show -g $Rg -n $SearchName --resource-type "Microsoft.Search/searchServices" --query id -o tsv
  $searchKey = az rest --method post --url "https://management.azure.com$searchId/listAdminKeys?api-version=2023-11-01" --query primaryKey -o tsv
}

Write-Host "Fetching Storage connection string..."
$storageConn = az storage account show-connection-string -g $Rg -n $StorageName --query connectionString -o tsv

Write-Host "Fetching Azure OpenAI endpoint + key..."
$aoaiEndpoint = az cognitiveservices account show -g $Rg -n $OpenAIName --query properties.endpoint -o tsv
$aoaiKey = az cognitiveservices account keys list -g $Rg -n $OpenAIName --query key1 -o tsv

$ds = Get-Content "search/datasource.json" -Raw | ConvertFrom-Json
$ds.name = $DataSourceName
$ds.credentials.connectionString = $storageConn
$ds | ConvertTo-Json -Depth 100 | Set-Content "search/.datasource.rendered.json"

$skillset = Get-Content "search/skillset.json" -Raw | ConvertFrom-Json
$skillset.name = $SkillsetName
foreach ($skill in $skillset.skills) {
  if ($skill.name -eq "embed") {
    $skill.resourceUri = $aoaiEndpoint
    $skill.apiKey = $aoaiKey
    $skill.deploymentId = $EmbedDeploymentName
    $skill.modelName = $EmbedModelName
    $skill.dimensions = $EmbedDimensions
  }
}
$skillset.indexProjections.selectors[0].targetIndexName = $IndexName
$skillset | ConvertTo-Json -Depth 100 | Set-Content "search/.skillset.rendered.json"

$index = Get-Content "search/index.json" -Raw | ConvertFrom-Json
$index.name = $IndexName
foreach ($field in $index.fields) {
  if ($field.name -eq "contentVector") { $field.dimensions = $EmbedDimensions }
}
foreach ($v in $index.vectorSearch.vectorizers) {
  if ($v.name -eq "openai-vectorizer") {
    $v.azureOpenAIParameters.resourceUri = $aoaiEndpoint
    $v.azureOpenAIParameters.apiKey = $aoaiKey
    $v.azureOpenAIParameters.deploymentId = $EmbedDeploymentName
    $v.azureOpenAIParameters.modelName = $EmbedModelName
  }
}
$index | ConvertTo-Json -Depth 100 | Set-Content "search/.index.rendered.json"

$indexer = Get-Content "search/indexer.json" -Raw | ConvertFrom-Json
$indexer.name = $IndexerName
$indexer.dataSourceName = $DataSourceName
$indexer.skillsetName = $SkillsetName
$indexer.targetIndexName = $IndexName
$indexer | ConvertTo-Json -Depth 100 | Set-Content "search/.indexer.rendered.json"

$hdrs = @("Content-Type=application/json", "api-key=$searchKey")

Write-Host "Upserting datasource..."
az rest --method put --url "$searchEndpoint/datasources/$DataSourceName?api-version=$ApiVersion" --headers $hdrs --body "@search/.datasource.rendered.json" | Out-Null

Write-Host "Upserting skillset..."
az rest --method put --url "$searchEndpoint/skillsets/$SkillsetName?api-version=$ApiVersion" --headers $hdrs --body "@search/.skillset.rendered.json" | Out-Null

Write-Host "Upserting index..."
az rest --method put --url "$searchEndpoint/indexes/$IndexName?api-version=$ApiVersion" --headers $hdrs --body "@search/.index.rendered.json" | Out-Null

Write-Host "Upserting indexer..."
az rest --method put --url "$searchEndpoint/indexers/$IndexerName?api-version=$ApiVersion" --headers $hdrs --body "@search/.indexer.rendered.json" | Out-Null

Write-Host "Done."
Write-Host "Next: upload docs to the 'kb-docs' container, then run the indexer:"
Write-Host "  az rest --method post --url `"$searchEndpoint/indexers/$IndexerName/run?api-version=$ApiVersion`" --headers `"api-key=$searchKey`""

