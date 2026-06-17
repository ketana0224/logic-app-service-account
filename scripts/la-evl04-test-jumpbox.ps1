<#
.SYNOPSIS
  踏み台 VM (vm-jump-dir) 上で Service Account 方式 (EVL-04-TeamsChatSend) を再テストする。

.DESCRIPTION
  Logic App は publicNetworkAccess=Disabled のため、
  本スクリプトは VNet 内 (snet-jumpbox) からのみ動作する。

  処理フロー:
    1. ARM 経由でワークフロー一覧を取得し、health=Healthy を確認
    2. ARM 経由で manual トリガーの callbackUrl を取得
       (callbackUrl のホスト名は *.azurewebsites.net だが、Private DNS Zone により PE の private IP に解決される)
    3. callbackUrl に POST して 1:1 チャット送信を実行
    4. 直近 run の status を ARM 経由で取得して表示

.PARAMETER WorkflowName
  実行するワークフロー名。既定: EVL-04-TeamsChatSend
  EVL-02-SendMail / EVL-99-TokenHealthCheck 等にも切替可。

.PARAMETER UserAObjectId
  1:1 チャットの A 側ユーザーの Entra Object ID (M365 テナント)。

.PARAMETER UserBObjectId
  1:1 チャットの B 側ユーザーの Entra Object ID。

.PARAMETER MessageContent
  送信メッセージ本文。既定でタイムスタンプ入り再テスト文言。

.EXAMPLE
  # 踏み台 VM (vm-jump-dir) に RDP / Bastion 接続後、PowerShell で:
  pwsh -File C:\scripts\la-evl04-test-jumpbox.ps1

.EXAMPLE
  pwsh -File C:\scripts\la-evl04-test-jumpbox.ps1 -WorkflowName EVL-99-TokenHealthCheck

.NOTES
  前提:
    - 踏み台 VM に Azure CLI (az) と PowerShell 7 (pwsh) がインストール済み
    - az login 済み (subscription = <azure-subscription-id> にアクセスできる Entra アカウント)
    - 実行アカウントが Logic App に対して以下いずれかの RBAC を持つ
        * Logic App Standard Contributor (推奨)
        * Contributor / Owner
#>

[CmdletBinding()]
param(
    [string]$SubscriptionId  = $(if ($env:AZURE_SUBSCRIPTION_ID) { $env:AZURE_SUBSCRIPTION_ID } else { "<azure-subscription-id>" }),
    [string]$ResourceGroup   = $(if ($env:AZURE_RESOURCE_GROUP)  { $env:AZURE_RESOURCE_GROUP }  else { "<resource-group>" }),
    [string]$SiteName        = $(if ($env:LOGIC_APP_NAME)        { $env:LOGIC_APP_NAME }        else { "<logic-app-name>" }),
    [string]$WorkflowName    = "EVL-04-TeamsChatSend",
    [string]$UserAObjectId   = $(if ($env:USER_A_OBJECT_ID)     { $env:USER_A_OBJECT_ID }     else { "<user-a-object-id>" }),
    [string]$UserBObjectId   = $(if ($env:USER_B_OBJECT_ID)     { $env:USER_B_OBJECT_ID }     else { "<user-b-object-id>" }),
    [string]$MessageContent  = "[再テスト] EVL-04 Service Account Teams 1:1 送信  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Section($title) {
    Write-Host ""
    Write-Host "==== $title ====" -ForegroundColor Cyan
}

function Invoke-Arm {
    param(
        [Parameter(Mandatory)] [string]$Method,
        [Parameter(Mandatory)] [string]$Path,
        [string]$BodyFile
    )
    $uri = "https://management.azure.com$Path"
    if ($BodyFile) {
        $raw = az rest --method $Method --uri $uri --body "@$BodyFile" --headers "Content-Type=application/json" 2>&1
    } else {
        $raw = az rest --method $Method --uri $uri 2>&1
    }
    if ($LASTEXITCODE -ne 0) {
        throw "az rest failed (exit $LASTEXITCODE):`n$raw"
    }
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    return $raw | ConvertFrom-Json
}

# ---- 0) サブスクリプション切替 ----
Write-Section "0) Subscription context"
az account set --subscription $SubscriptionId | Out-Null
$ctx = az account show -o json | ConvertFrom-Json
"Subscription : {0} ({1})" -f $ctx.name, $ctx.id
"Account      : {0}"      -f $ctx.user.name

# ---- 1) ワークフロー一覧 + Health 確認 ----
Write-Section "1) Workflow list / health"
$wfPath  = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$SiteName/hostruntime/runtime/webhooks/workflow/api/management/workflows?api-version=2022-03-01"
$wfs     = Invoke-Arm -Method GET -Path $wfPath
$target  = $wfs | Where-Object { $_.name -eq $WorkflowName }
if (-not $target) {
    throw "Workflow '$WorkflowName' が見つかりません。デプロイ済みのワークフロー:`n$($wfs.name -join ', ')"
}
"{0,-30}  kind={1,-10}  health={2}" -f $target.name, $target.kind, $target.health.state
if ($target.health.state -ne "Healthy") {
    Write-Warning "Workflow health が Healthy ではありません: $($target.health.state)"
}

# ---- 2) callback URL 取得 ----
Write-Section "2) Get callback URL (ARM)"
$cbPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$SiteName/hostruntime/runtime/webhooks/workflow/api/management/workflows/$WorkflowName/triggers/manual/listCallbackUrl?api-version=2022-03-01"
$cb     = Invoke-Arm -Method POST -Path $cbPath
$cbUri  = [uri]$cb.value
"Host : {0}"     -f $cbUri.Host
"Path : {0}"     -f $cbUri.AbsolutePath
"SAS  : {0}..."  -f ($cbUri.Query.Substring(0, [Math]::Min(40, $cbUri.Query.Length)))

# ---- 2.5) DNS / PE 解決確認 ----
Write-Section "2.5) DNS resolution check (must resolve to PE private IP 10.0.2.9)"
try {
    $dns = Resolve-DnsName -Name $cbUri.Host -Type A -ErrorAction Stop |
           Where-Object { $_.Type -in 'A','CNAME' }
    $dns | Format-Table Name, Type, IP4Address, NameHost -AutoSize | Out-String | Write-Host
    $aRecord = $dns | Where-Object { $_.Type -eq 'A' } | Select-Object -First 1
    if ($aRecord) {
        if ($aRecord.IP4Address -like "10.0.2.*") {
            Write-Host "✅ PE private IP に解決されています ($($aRecord.IP4Address))" -ForegroundColor Green
        } else {
            Write-Warning "⚠️ PE 経由でない IP に解決されました: $($aRecord.IP4Address) — Private DNS Zone の設定を確認してください"
        }
    }
} catch {
    Write-Warning "DNS 解決に失敗: $_"
}

# ---- 3) callback URL に POST (実テスト) ----
Write-Section "3) POST to callback URL"
$body = @{
    userAObjectId  = $UserAObjectId
    userBObjectId  = $UserBObjectId
    messageContent = $MessageContent
} | ConvertTo-Json -Compress
Write-Host "Request body:"
Write-Host "  $body"
Write-Host ""

$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $response = Invoke-RestMethod -Method POST -Uri $cb.value -ContentType "application/json" -Body $body -TimeoutSec 90
    $sw.Stop()
    Write-Host ("Elapsed: {0:N1} s" -f $sw.Elapsed.TotalSeconds) -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Response:" -ForegroundColor Green
    $response | ConvertTo-Json -Depth 8
} catch {
    $sw.Stop()
    Write-Host ("Elapsed: {0:N1} s" -f $sw.Elapsed.TotalSeconds) -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "❌ POST failed" -ForegroundColor Red
    if ($_.Exception.Response) {
        $resp = $_.Exception.Response
        "  Status   : {0} {1}" -f [int]$resp.StatusCode, $resp.StatusCode
        try {
            $errBody = (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd()
            "  Body     :`n$errBody"
        } catch { }
    } else {
        "  Error    : $($_.Exception.Message)"
    }
    Write-Host ""
    Write-Host "→ 続けて run history を確認します（部分実行になっている可能性あり）" -ForegroundColor Yellow
}

# ---- 4) 直近 run 確認 ----
Write-Section "4) Recent runs (top 3)"
Start-Sleep -Seconds 2  # run が記録されるのを待つ
$runsPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$SiteName/hostruntime/runtime/webhooks/workflow/api/management/workflows/$WorkflowName/runs?api-version=2022-03-01&%24top=3"
$runs = Invoke-Arm -Method GET -Path $runsPath
$runs.value | ForEach-Object {
    [PSCustomObject]@{
        Name   = $_.name
        Status = $_.properties.status
        Code   = $_.properties.code
        Start  = $_.properties.startTime
        End    = $_.properties.endTime
    }
} | Format-Table -AutoSize | Out-String | Write-Host

# 直近 1 件が失敗していれば action 詳細を出力
$last = $runs.value | Select-Object -First 1
if ($last -and $last.properties.status -ne 'Succeeded') {
    Write-Section "5) Failed actions detail (last run = $($last.name))"
    $actionsPath = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$SiteName/hostruntime/runtime/webhooks/workflow/api/management/workflows/$WorkflowName/runs/$($last.name)/actions?api-version=2022-03-01"
    $acts = Invoke-Arm -Method GET -Path $actionsPath
    $acts.value | Where-Object { $_.properties.status -ne 'Succeeded' } | ForEach-Object {
        Write-Host "--- Action: $($_.name)  [$($_.properties.status) / $($_.properties.code)]" -ForegroundColor Yellow
        $_.properties.error | ConvertTo-Json -Depth 6
    }
}

Write-Section "Done"
"Workflow : $WorkflowName"
"Site     : $SiteName ($ResourceGroup)"
