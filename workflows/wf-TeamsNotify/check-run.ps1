#Requires -Version 7.0
<#
.SYNOPSIS
  EVL-04d の実行結果を Logic App host runtime endpoint から直接確認する
  （Logic App publicNetworkAccess=Enabled 時のみ使用可）

.PARAMETER RunId
  確認する run ID
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$RunId
)

. "$PSScriptRoot/../../scripts/load-env.ps1"

$logicAppUrl = "https://$env:LOGIC_APP_NAME.azurewebsites.net"
$uri = "$logicAppUrl/runtime/webhooks/workflow/api/management/workflows/wf-TeamsNotify/runs/$RunId"

Write-Host "Fetching run: $RunId" -ForegroundColor Cyan

$response = Invoke-RestMethod -Uri $uri -Method Get

$status = $response.properties.status
Write-Host "Status: $status"

$response.properties.actions.PSObject.Properties | ForEach-Object {
    $name   = $_.Name
    $result = $_.Value.status
    Write-Host "  - $name`: $result"
}

