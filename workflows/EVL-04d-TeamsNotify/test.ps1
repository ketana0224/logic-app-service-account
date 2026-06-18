#Requires -Version 7.0
<#
.SYNOPSIS
  EVL-04d-TeamsNotify のテスト送信

.PARAMETER Target
  送信先ユーザーの UPN（例: AdilE@contoso.onmicrosoft.com）
  または表示名のキーワード（例: Adil）

.PARAMETER Message
  送信するメッセージ本文（HTML 可）

.PARAMETER Subject
  メッセージ件名
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$Target,

    [string]$Message = "<p>This is a test notification from Logic App EVL-04d.</p>",
    [string]$Subject = "Teams Notification (Test)"
)

$callbackFile = "$PSScriptRoot/callback-url.txt"
if (-not (Test-Path $callbackFile)) {
    Write-Error "callback-url.txt が見つかりません。先に deploy.ps1 を実行してください。"
    exit 1
}

$callbackUrl = Get-Content $callbackFile -Raw | ForEach-Object { $_.Trim() }

# Target が UPN 形式でない場合は .env.local の M365 ドメインから補完
if ($Target -notmatch "@") {
    . "$PSScriptRoot/../../scripts/load-env.ps1"
    $domain = ($env:SERVICE_ACCOUNT_UPN -split "@")[1]
    $recipient = "$Target@$domain"
} else {
    $recipient = $Target
}

Write-Host "=== Test: EVL-04d-TeamsNotify ===" -ForegroundColor Cyan
Write-Host "Target   : $recipient"
Write-Host "Subject  : $Subject"

$body = @{
    recipient = $recipient
    subject   = $Subject
    message   = $Message
} | ConvertTo-Json

Write-Host "Sending request..." -ForegroundColor Yellow
$response = Invoke-WebRequest -Uri $callbackUrl -Method Post -Body $body `
    -ContentType "application/json" -UseBasicParsing

Write-Host "Status: $($response.StatusCode)"

# run-id を取得
$runId = $response.Headers["x-ms-workflow-run-id"]
if (-not $runId) {
    # body から試みる
    try { $runId = ($response.Content | ConvertFrom-Json).runId } catch {}
}

if ($runId) {
    Write-Host "Run ID: $runId"
    Write-Host ""
    Write-Host "Waiting for completion (max 60s)..." -ForegroundColor Yellow

    . "$PSScriptRoot/../../scripts/load-env.ps1"
    $resourceId = "/subscriptions/$env:AZURE_SUBSCRIPTION_ID/resourceGroups/$env:RESOURCE_GROUP_NAME/providers/Microsoft.Web/sites/$env:LOGIC_APP_NAME"
    $token = (az account get-access-token --resource https://management.azure.com --query accessToken -o tsv)
    $statusUri = "https://management.azure.com$resourceId/hostruntime/runtime/webhooks/workflow/api/management/workflows/EVL-04d-TeamsNotify/runs/$($runId)?api-version=2023-12-01"

    $elapsed = 0
    do {
        Start-Sleep -Seconds 5
        $elapsed += 5
        $run = Invoke-RestMethod -Uri $statusUri -Method Get `
            -Headers @{ Authorization = "Bearer $token" }
        $status = $run.properties.status
        Write-Host "  [$elapsed s] $status"
    } while ($status -in @("Running","Waiting") -and $elapsed -lt 60)

    if ($status -eq "Succeeded") {
        Write-Host ""
        Write-Host "✓ Succeeded" -ForegroundColor Green
    } else {
        Write-Host ""
        Write-Host "✗ $status" -ForegroundColor Red
        Write-Host "Run detail: pwsh ./check-run-arm.ps1 -RunId $runId"
    }
} else {
    Write-Host "✓ Request accepted (202). Run ID not returned in header." -ForegroundColor Green
    Write-Host "Use check-run-arm.ps1 to inspect the latest run."
}
