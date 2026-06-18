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

# zip デプロイ: ワークフローディレクトリ構造の zip を作成して ARM 経由で配置
Write-Host "Building deployment zip..." -ForegroundColor Yellow
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "la_deploy_$(Get-Random)"
$wfDir  = Join-Path $tempDir $workflowName
New-Item -ItemType Directory -Path $wfDir | Out-Null
Copy-Item $workflowJson (Join-Path $wfDir "workflow.json")
$zipPath = "$tempDir.zip"
Compress-Archive -Path (Join-Path $tempDir "*") -DestinationPath $zipPath -Force
Write-Host "✓ zip ready" -ForegroundColor Green

Write-Host "Deploying via az webapp deploy..." -ForegroundColor Yellow
az webapp deploy `
    --resource-group $env:RESOURCE_GROUP_NAME `
    --name $env:LOGIC_APP_NAME `
    --src-path $zipPath `
    --type zip `
    --async false | Out-Null

Remove-Item -Recurse -Force $tempDir, $zipPath -ErrorAction SilentlyContinue
Write-Host "✓ workflow deployed" -ForegroundColor Green

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
