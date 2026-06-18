#Requires -Version 7.0
<#
.SYNOPSIS
  EVL-04d-TeamsNotify ワークフローを Logic App にデプロイする
#>

. "$PSScriptRoot/../../scripts/load-env.ps1"

$workflowName = "EVL-04d-TeamsNotify"
$workflowJson = "$PSScriptRoot/workflow.json"

Write-Host "=== Deploy: $workflowName ===" -ForegroundColor Cyan
Write-Host "Logic App : $env:LOGIC_APP_NAME"
Write-Host "Resource Group: $env:RESOURCE_GROUP_NAME"

# workflow.json を Logic App の VFS エンドポイントへ PUT (ARM proxy)
$resourceId = "/subscriptions/$env:AZURE_SUBSCRIPTION_ID/resourceGroups/$env:RESOURCE_GROUP_NAME/providers/Microsoft.Web/sites/$env:LOGIC_APP_NAME"
$vfsPath     = "site/wwwroot/$workflowName/workflow.json"
$apiVersion  = "2023-12-01"
$uri         = "https://management.azure.com$resourceId/hostruntime/admin/vfs/$($vfsPath)?api-version=$apiVersion"

$token = (az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
if (-not $token) { Write-Error "az login が必要です"; exit 1 }

$body = Get-Content $workflowJson -Raw

Write-Host "Uploading workflow.json..." -ForegroundColor Yellow
$response = Invoke-RestMethod -Uri $uri -Method Put -Body $body `
    -Headers @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }

Write-Host "✓ workflow.json deployed" -ForegroundColor Green

# Logic App を再起動して反映
Write-Host "Restarting Logic App..." -ForegroundColor Yellow
az webapp restart --name $env:LOGIC_APP_NAME --resource-group $env:RESOURCE_GROUP_NAME | Out-Null
Write-Host "Waiting 60s for warmup..." -ForegroundColor Yellow
Start-Sleep -Seconds 60
Write-Host "✓ Logic App restarted" -ForegroundColor Green

# callback URL を取得
Write-Host "Fetching callback URL..." -ForegroundColor Yellow
$callbackUri = "https://management.azure.com$resourceId/hostruntime/runtime/webhooks/workflow/api/management/workflows/$workflowName/triggers/manual/listCallbackUrl?api-version=$apiVersion"
$callbackResponse = Invoke-RestMethod -Uri $callbackUri -Method Post `
    -Headers @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }

$callbackUrl = $callbackResponse.value
$callbackUrl | Out-File "$PSScriptRoot/callback-url.txt" -Encoding utf8
Write-Host "✓ Callback URL saved to callback-url.txt" -ForegroundColor Green
Write-Host "  $callbackUrl"

Write-Host ""
Write-Host "=== Deploy Complete ===" -ForegroundColor Green
Write-Host "Next: pwsh ./test.ps1 -Target <UPN>"
