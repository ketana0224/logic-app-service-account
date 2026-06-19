#Requires -Version 7.0
<#
.SYNOPSIS
  wf-TokenHealthCheck ワークフローを Logic App にデプロイする
#>

$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
Push-Location $repoRoot
try {
    . "./scripts/load-env.ps1"
} finally {
    Pop-Location
}

$workflowName = "wf-TokenHealthCheck"
$workflowJson = "$PSScriptRoot/workflow.json"

Write-Host "=== Deploy: $workflowName ===" -ForegroundColor Cyan
Write-Host "Logic App     : $env:LOGIC_APP_NAME"
Write-Host "Resource Group: $env:RESOURCE_GROUP_NAME"

$token = (az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
if (-not $token) { Write-Error "az login が必要です"; exit 1 }

$resourceId = "/subscriptions/$env:AZURE_SUBSCRIPTION_ID/resourceGroups/$env:RESOURCE_GROUP_NAME/providers/Microsoft.Web/sites/$env:LOGIC_APP_NAME"
$apiVersion = "2023-12-01"
$headers   = @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" }

function Invoke-HostRuntimeRequest {
  param(
    [Parameter(Mandatory = $true)][string]$Uri,
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter()][hashtable]$Headers,
    [Parameter()]$Body,
    [bool]$AllowConflict = $false,
    [int]$MaxRetries = 12,
    [int]$DelaySeconds = 10
  )

  for ($attempt = 1; $attempt -le $MaxRetries; $attempt++) {
    try {
      return Invoke-RestMethod -Uri $Uri -Method $Method -Headers $Headers -Body $Body
    } catch {
      $msg = $_.Exception.Message
      if ($AllowConflict -and ($msg -match '409') -and ($msg -match 'Conflict')) {
        return $null
      }
      $isRetryable = ($msg -match 'ServiceUnavailable') -or ($msg -match 'host runtime') -or ($msg -match '429')
      if (-not $isRetryable -or $attempt -eq $MaxRetries) {
        throw
      }
      Write-Host "Host runtime not ready (attempt $attempt/$MaxRetries). Retrying in ${DelaySeconds}s..." -ForegroundColor Yellow
      Start-Sleep -Seconds $DelaySeconds
    }
  }
}

$fileUri = "https://management.azure.com$resourceId/hostruntime/admin/vfs/site/wwwroot/$workflowName/workflow.json?api-version=$apiVersion"
$dirUri = "https://management.azure.com$resourceId/hostruntime/admin/vfs/site/wwwroot/$workflowName/?api-version=$apiVersion"
$body = Get-Content $workflowJson -Raw

# host.json (Logic Apps Workflows 拡張バンドル) を配置
# 誤ったバンドル (Microsoft.Azure.Functions.ExtensionBundle) だとワークフロー拡張が
# ロードされず runtime/webhooks/workflow が 404 になるため、毎回正しい host.json を上書きする
$hostJson = "$PSScriptRoot/../host.json"
$hostUri = "https://management.azure.com$resourceId/hostruntime/admin/vfs/site/wwwroot/host.json?api-version=$apiVersion"
$hostHeaders = $headers.Clone()
$hostHeaders["If-Match"] = "*"

Write-Host "Uploading host.json via VFS..." -ForegroundColor Yellow
Invoke-HostRuntimeRequest -Uri $hostUri -Method Put -Headers $hostHeaders -Body (Get-Content $hostJson -Raw) | Out-Null
Write-Host "✓ host.json deployed" -ForegroundColor Green

Write-Host "Ensuring workflow directory exists..." -ForegroundColor Yellow
Invoke-HostRuntimeRequest -Uri $dirUri -Method Put -Headers $headers -Body '' -AllowConflict $true | Out-Null

Write-Host "Uploading workflow.json via VFS..." -ForegroundColor Yellow
$workflowHeaders = $headers.Clone()
$workflowHeaders["If-Match"] = "*"
Invoke-HostRuntimeRequest -Uri $fileUri -Method Put -Headers $workflowHeaders -Body $body | Out-Null

Write-Host "✓ workflow.json deployed" -ForegroundColor Green

Write-Host "Restarting Logic App..." -ForegroundColor Yellow
az webapp restart --name $env:LOGIC_APP_NAME --resource-group $env:RESOURCE_GROUP_NAME | Out-Null
Write-Host "Waiting 60s for warmup..." -ForegroundColor Yellow
Start-Sleep -Seconds 60
Write-Host "✓ Logic App restarted" -ForegroundColor Green

Write-Host ""
Write-Host "=== Deploy Complete ===" -ForegroundColor Green
Write-Host "wf-TokenHealthCheck will run automatically every 6 hours."
Write-Host "To trigger manually:"
Write-Host "  az logicapp workflow run-trigger -g $env:RESOURCE_GROUP_NAME -n $env:LOGIC_APP_NAME -r $workflowName"


