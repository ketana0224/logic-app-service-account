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
$uri = "https://management.azure.com$resourceId/hostruntime/runtime/webhooks/workflow/api/management/workflows/EVL-04d-TeamsNotify/runs/$($RunId)?api-version=2023-12-01"

Write-Host "Fetching run (ARM): $RunId" -ForegroundColor Cyan

$response = Invoke-RestMethod -Uri $uri -Method Get `
    -Headers @{ Authorization = "Bearer $token" }

$status = $response.properties.status
Write-Host "Status: $status"

$response.properties.actions.PSObject.Properties | ForEach-Object {
    $name   = $_.Name
    $result = $_.Value.status
    Write-Host "  - $name`: $result"
}
