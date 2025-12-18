[CmdletBinding()]
param(
  [string]$Rg,
  [string]$StorageName,
  [string]$Container = "kb-docs",
  [string]$DocsDir = "docs"
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
$StorageName = Prompt-IfEmpty $StorageName "Storage account name"
$DocsDir = Prompt-IfEmpty $DocsDir "Local docs folder" $DocsDir

if (-not (Test-Path $DocsDir)) {
  throw "Docs folder not found: $DocsDir"
}

az storage blob upload-batch `
  --account-name $StorageName `
  --destination $Container `
  --source $DocsDir `
  --auth-mode login `
  | Out-Null

Write-Host "Uploaded docs from $DocsDir to $StorageName/$Container"

