#Requires -Version 7.0
<#
.SYNOPSIS
  EVL-99-TokenHealthCheck ワークフローを Logic App にデプロイする
#>

$repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
Push-Location $repoRoot
try {
    . "./scripts/load-env.ps1"
} finally {
    Pop-Location
}

$workflowName = "EVL-99-TokenHealthCheck"
$workflowJson = "$PSScriptRoot/workflow.json"

Write-Host "=== Deploy: $workflowName ===" -ForegroundColor Cyan
Write-Host "Logic App     : $env:LOGIC_APP_NAME"
Write-Host "Resource Group: $env:RESOURCE_GROUP_NAME"

$token = (az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
if (-not $token) { Write-Error "az login が必要です"; exit 1 }

$workflowDef = Get-Content $workflowJson -Raw | ConvertFrom-Json
$armBody = @{
    properties = @{
        definition = $workflowDef.definition
        kind       = $workflowDef.kind
    }
} | ConvertTo-Json -Depth 20

$resourceId = "/subscriptions/$env:AZURE_SUBSCRIPTION_ID/resourceGroups/$env:RESOURCE_GROUP_NAME/providers/Microsoft.Web/sites/$env:LOGIC_APP_NAME"
$apiVersion = "2023-12-01"
$workflowUri = "https://management.azure.com$resourceId/workflows/$workflowName?api-version=$apiVersion"

Write-Host "Deploying workflow via ARM..." -ForegroundColor Yellow
Invoke-RestMethod -Uri $workflowUri -Method Put -Body $armBody `
    -Headers @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" } | Out-Null

Write-Host "✓ workflow deployed" -ForegroundColor Green

Write-Host "Restarting Logic App..." -ForegroundColor Yellow
az webapp restart --name $env:LOGIC_APP_NAME --resource-group $env:RESOURCE_GROUP_NAME | Out-Null
Write-Host "Waiting 60s for warmup..." -ForegroundColor Yellow
Start-Sleep -Seconds 60
Write-Host "✓ Logic App restarted" -ForegroundColor Green

Write-Host ""
Write-Host "=== Deploy Complete ===" -ForegroundColor Green
Write-Host "EVL-99 will run automatically every 6 hours."
Write-Host "To trigger manually:"
Write-Host "  az logicapp workflow run-trigger -g $env:RESOURCE_GROUP_NAME -n $env:LOGIC_APP_NAME -r $workflowName"
