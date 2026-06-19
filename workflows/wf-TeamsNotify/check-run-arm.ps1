#Requires -Version 7.0
<#
.SYNOPSIS
  EVL-04d の実行結果を ARM proxy 経由で確認する
  （Logic App publicNetworkAccess=Disabled 後でも使用可）

.PARAMETER RunId
  確認する run ID
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$RunId
)

. "$PSScriptRoot/../../scripts/load-env.ps1"

$token = (az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
if (-not $token) { Write-Error "az login が必要です"; exit 1 }

$resourceId = "/subscriptions/$env:AZURE_SUBSCRIPTION_ID/resourceGroups/$env:RESOURCE_GROUP_NAME/providers/Microsoft.Web/sites/$env:LOGIC_APP_NAME"
$uri = "https://management.azure.com$resourceId/hostruntime/runtime/webhooks/workflow/api/management/workflows/wf-TeamsNotify/runs/$($RunId)?api-version=2023-12-01"

Write-Host "Fetching run (ARM): $RunId" -ForegroundColor Cyan

$response = Invoke-RestMethod -Uri $uri -Method Get `
    -Headers @{ Authorization = "Bearer $token" }

$status = $response.properties.status
Write-Host "Status: $status"

if ($response.properties.error) {
    Write-Host "Run error:" -ForegroundColor Red
    Write-Host "  code   : $($response.properties.error.code)"
    Write-Host "  message: $($response.properties.error.message)"
}

# アクション単位の結果を取得（runs/{id}/actions）
$actionsUri = "https://management.azure.com$resourceId/hostruntime/runtime/webhooks/workflow/api/management/workflows/wf-TeamsNotify/runs/$($RunId)/actions?api-version=2023-12-01"
$actions = Invoke-RestMethod -Uri $actionsUri -Method Get `
    -Headers @{ Authorization = "Bearer $token" }

foreach ($a in $actions.value) {
    $name   = $a.name
    $st     = $a.properties.status
    $code   = $a.properties.code
    Write-Host "  - $name : $st ($code)" -ForegroundColor ($(if ($st -eq 'Failed') { 'Red' } else { 'Gray' }))

    if ($a.properties.error) {
        Write-Host "      error.code   : $($a.properties.error.code)" -ForegroundColor Red
        Write-Host "      error.message: $($a.properties.error.message)" -ForegroundColor Red
    }

    # 失敗アクションの出力（HTTP レスポンス本文など）を取得
    if ($st -eq 'Failed' -and $a.properties.outputsLink) {
        try {
            $out = Invoke-RestMethod -Uri $a.properties.outputsLink.uri -Method Get
            Write-Host "      outputs: $($out | ConvertTo-Json -Depth 6 -Compress)" -ForegroundColor Yellow
        } catch {
            Write-Host "      (outputs 取得不可: $($_.Exception.Message))" -ForegroundColor DarkGray
        }
    }
}

