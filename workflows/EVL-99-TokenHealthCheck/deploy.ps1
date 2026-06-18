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

$resourceId = "/subscriptions/$env:AZURE_SUBSCRIPTION_ID/resourceGroups/$env:RESOURCE_GROUP_NAME/providers/Microsoft.Web/sites/$env:LOGIC_APP_NAME"
$apiVersion = "2023-12-01"
$headers   = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }

$mkdirUri = "https://management.azure.com$resourceId/hostruntime/admin/vfs/site/wwwroot/$workflowName/?api-version=$apiVersion"
Write-Host "Creating workflow directory..." -ForegroundColor Yellow
try {
    Invoke-RestMethod -Uri $mkdirUri -Method Put -Headers $headers -Body "" | Out-Null
} catch {}
Write-Host "✓ Directory ready" -ForegroundColor Green

$fileUri = "https://management.azure.com$resourceId/hostruntime/admin/vfs/site/wwwroot/$workflowName/workflow.json?api-version=$apiVersion"
$body = Get-Content $workflowJson -Raw

Write-Host "Uploading workflow.json..." -ForegroundColor Yellow
Invoke-RestMethod -Uri $fileUri -Method Put -Headers $headers -Body $body | Out-Null

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
