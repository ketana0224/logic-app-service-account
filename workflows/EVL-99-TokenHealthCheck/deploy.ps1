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
