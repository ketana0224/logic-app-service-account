#Requires -Version 7.0
<#
.SYNOPSIS
  EVL-04d-TeamsNotify ワークフローを Logic App にデプロイする
#>

$repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
Push-Location $repoRoot
try {
    . "./scripts/load-env.ps1"
} finally {
    Pop-Location
}

$workflowName = "EVL-04d-TeamsNotify"
$workflowJson = "$PSScriptRoot/workflow.json"

Write-Host "=== Deploy: $workflowName ===" -ForegroundColor Cyan
Write-Host "Logic App     : $env:LOGIC_APP_NAME"
Write-Host "Resource Group: $env:RESOURCE_GROUP_NAME"

$token = (az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
if (-not $token) { Write-Error "az login が必要です"; exit 1 }

$resourceId = "/subscriptions/$env:AZURE_SUBSCRIPTION_ID/resourceGroups/$env:RESOURCE_GROUP_NAME/providers/Microsoft.Web/sites/$env:LOGIC_APP_NAME"
$apiVersion = "2023-12-01"
$headers   = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }

# Step 1: ワークフロー用ディレクトリを VFS に作成（末尾スラッシュで PUT）
$mkdirUri = "https://management.azure.com$resourceId/hostruntime/admin/vfs/site/wwwroot/$workflowName/?api-version=$apiVersion"
Write-Host "Creating workflow directory..." -ForegroundColor Yellow
try {
    Invoke-RestMethod -Uri $mkdirUri -Method Put -Headers $headers -Body "" | Out-Null
} catch {
    # 既に存在する場合は無視
}
Write-Host "✓ Directory ready" -ForegroundColor Green

# Step 2: workflow.json をアップロード
$fileUri = "https://management.azure.com$resourceId/hostruntime/admin/vfs/site/wwwroot/$workflowName/workflow.json?api-version=$apiVersion"
$body = Get-Content $workflowJson -Raw

Write-Host "Uploading workflow.json..." -ForegroundColor Yellow
Invoke-RestMethod -Uri $fileUri -Method Put -Headers $headers -Body $body | Out-Null
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
