#Requires -Version 7.0
<#
.SYNOPSIS
  EVL-99-TokenHealthCheck ワークフローを Logic App にデプロイする
#>

. "$PSScriptRoot/../../scripts/load-env.ps1"

$workflowName = "EVL-99-TokenHealthCheck"
$workflowJson = "$PSScriptRoot/workflow.json"

Write-Host "=== Deploy: $workflowName ===" -ForegroundColor Cyan
Write-Host "Logic App     : $env:LOGIC_APP_NAME"
Write-Host "Resource Group: $env:RESOURCE_GROUP_NAME"

$resourceId = "/subscriptions/$env:AZURE_SUBSCRIPTION_ID/resourceGroups/$env:RESOURCE_GROUP_NAME/providers/Microsoft.Web/sites/$env:LOGIC_APP_NAME"
$vfsPath    = "site/wwwroot/$workflowName/workflow.json"
$apiVersion = "2023-12-01"
$uri        = "https://management.azure.com$resourceId/hostruntime/admin/vfs/$($vfsPath)?api-version=$apiVersion"

$token = (az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
if (-not $token) { Write-Error "az login が必要です"; exit 1 }

$body = Get-Content $workflowJson -Raw

Write-Host "Uploading workflow.json..." -ForegroundColor Yellow
Invoke-RestMethod -Uri $uri -Method Put -Body $body `
    -Headers @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" } | Out-Null

Write-Host "✓ workflow.json deployed" -ForegroundColor Green

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
