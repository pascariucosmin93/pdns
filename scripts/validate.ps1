param(
    [string]$ComposeBinary = "podman"
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$composeFile = Join-Path $projectRoot "compose.yaml"
$zoneFile = Join-Path $projectRoot "zones\\db.portfolio.test"

Write-Host "Validating compose file..."
& $ComposeBinary compose -f $composeFile config | Out-Null

Write-Host "Validating DNS zone serial..."
$zoneContent = Get-Content $zoneFile -Raw
if ($zoneContent -notmatch '\b20\d{8}\b') {
    throw "Zone serial does not look like YYYYMMDDNN."
}

Write-Host "Validation successful."

