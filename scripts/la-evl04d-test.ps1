<#
.SYNOPSIS
  Service Account 方式 (EVL-04d-TeamsNotify) を踏み台 VM から再テストする。

.DESCRIPTION
  処理フロー:
    1. ARM トークン取得（Az.Accounts セッション利用）
    2. ワークフロー health 確認
    3. DNS が PE (10.0.2.x) に解決されることを確認
    4. callbackUrl 取得 → UTF-8 byte で POST（日本語文字化け対策）
    5. 直近 3 run の status を取得（失敗時は action 詳細）

.PARAMETER WorkflowName
  実行するワークフロー名。既定: EVL-04d-TeamsNotify

.PARAMETER RecipientAadObjectId
  通知先ユーザーの Entra Object ID。既定: AmberR

.PARAMETER Title
  通知タイトル。

.PARAMETER Message
  通知本文（HTML 可、<br/> 使用可）。

.EXAMPLE
  # 事前に la-jumpbox-login.ps1 でログイン済みの同セッションで実行
  pwsh -File C:\scripts\la-evl04d-test.ps1

.EXAMPLE
  pwsh -File C:\scripts\la-evl04d-test.ps1 -RecipientAadObjectId "<other-user-objid>"

.EXAMPLE
  pwsh -File C:\scripts\la-evl04d-test.ps1 -WorkflowName EVL-99-TokenHealthCheck

.NOTES
  - 事前に la-jumpbox-login.ps1 が必要（Connect-AzAccount 済みであること）
  - 踏み台 (VNet 内 / snet-jumpbox) からのみ動作する（Logic App は publicNetworkAccess=Disabled）
#>

[CmdletBinding()]
param(
    [string]$SubscriptionId       = "571e49d7-d4d6-4cb5-884f-2e14bfaa662c",
    [string]$ResourceGroup        = "rg-dir",
    [string]$SiteName             = "la-dir-m365-connector",
    [string]$WorkflowName         = "EVL-04d-TeamsNotify",
    [string]$RecipientAadObjectId = "c52ed26f-8811-4d7e-95d7-dd65b8c8dbc1",  # AmberR
    [string]$Title                = "[定期テスト] EVL-04d Service Account 動作確認",
    [string]$Message              = $null
)

$ErrorActionPreference = "Stop"

function Write-Section($title) { Write-Host ""; Write-Host "==== $title ====" -ForegroundColor Cyan }

# hostruntime API は時に配列直返し / 時に { value: [...] } を返すため吸収
function Get-CollectionItems($resp) {
    if ($null -eq $resp) { return @() }
    if ($resp -is [System.Array]) { return $resp }
    if ($resp.PSObject.Properties.Name -contains 'value') { return @($resp.value) }
    return @($resp)
}

if (-not $Message) {
    $Message = "EVL-04d-TeamsNotify Service Account 方式 再テスト<br/>" +
               "送信時刻: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')<br/>" +
               "経路: jumpbox(10.0.4.x) -&gt; PE(10.0.2.9) -&gt; Logic App"
}

# ---- 1) ARM トークン取得 ----
Write-Section "1) ARM token"
if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
    throw "Az にログインしていません。先に la-jumpbox-login.ps1 を実行してください。"
}
$t = Get-AzAccessToken -ResourceUrl "https://management.azure.com/" -WarningAction SilentlyContinue
$tok = if ($t.Token -is [System.Security.SecureString]) {
    [System.Net.NetworkCredential]::new("", $t.Token).Password
} else { [string]$t.Token }
$H = @{ Authorization = "Bearer $tok" }
"Token head : $($tok.Substring(0,20))..."
"Expires    : $($t.ExpiresOn)"

# ---- 2) ワークフロー health ----
Write-Section "2) Workflow health: $WorkflowName"
$wfListUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$SiteName/hostruntime/runtime/webhooks/workflow/api/management/workflows?api-version=2022-03-01"
$wfs = Invoke-RestMethod -Method GET -Uri $wfListUri -Headers $H
$wfItems = Get-CollectionItems $wfs
$target = $wfItems | Where-Object { $_.name -eq $WorkflowName }
if (-not $target) {
    throw "Workflow '$WorkflowName' が見つかりません。利用可能: $(($wfItems.name) -join ', ')"
}
"{0,-30}  kind={1,-10}  health={2}" -f $target.name, $target.kind, $target.health.state
if ($target.health.state -ne "Healthy") {
    Write-Warning "Workflow health が Healthy ではありません: $($target.health.state)"
}

# ---- 3) DNS / PE 解決確認 ----
Write-Section "3) DNS check (must resolve to PE 10.0.2.x)"
try {
    $dns = Resolve-DnsName -Name "$SiteName.azurewebsites.net" -Type A -ErrorAction Stop |
           Where-Object { $_.Type -in 'A','CNAME' }
    $dns | Format-Table Name,Type,IP4Address,NameHost -AutoSize | Out-String | Write-Host
    $a = $dns | Where-Object { $_.Type -eq 'A' } | Select-Object -First 1
    if ($a -and $a.IP4Address -like "10.0.2.*") {
        Write-Host "✅ PE private IP に解決: $($a.IP4Address)" -ForegroundColor Green
    } elseif ($a) {
        Write-Warning "⚠️ PE 以外の IP に解決: $($a.IP4Address)"
    }
} catch {
    Write-Warning "DNS 解決に失敗: $_"
}

# ---- 4) callback URL 取得 + POST ----
Write-Section "4) Get callback URL & POST"
$cbUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$SiteName/hostruntime/runtime/webhooks/workflow/api/management/workflows/$WorkflowName/triggers/manual/listCallbackUrl?api-version=2022-03-01"
$cb = Invoke-RestMethod -Method POST -Uri $cbUri -Headers $H
"Callback host: $(([uri]$cb.value).Host)"
"Callback path: $(([uri]$cb.value).AbsolutePath)"

# body 構築（EVL-04d-TeamsNotify のスキーマに準拠: recipientAadObjectId / title / message）
$body = @{
    recipientAadObjectId = $RecipientAadObjectId
    title                = $Title
    message              = $Message
} | ConvertTo-Json -Compress

Write-Host ""
"Request body:"
"  $body"
Write-Host ""

# 日本語文字化け対策: UTF-8 byte で送信
$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($body)

$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $r = Invoke-RestMethod -Method POST -Uri $cb.value `
            -ContentType "application/json; charset=utf-8" `
            -Body $bodyBytes -TimeoutSec 90
    $sw.Stop()
    "Elapsed: {0:N1} s" -f $sw.Elapsed.TotalSeconds
    Write-Host ""
    Write-Host "✅ SUCCESS" -ForegroundColor Green
    $r | ConvertTo-Json -Depth 8
} catch {
    $sw.Stop()
    "Elapsed: {0:N1} s" -f $sw.Elapsed.TotalSeconds
    Write-Host ""
    Write-Host "❌ FAILED: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.Exception.Response) {
        "Status: $([int]$_.Exception.Response.StatusCode) $($_.Exception.Response.StatusCode)"
        try {
            "Body  : $((New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd())"
        } catch {}
    }
}

# ---- 5) 直近 run 確認 ----
Write-Section "5) Recent runs (top 3)"
Start-Sleep -Seconds 3
$runsUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$SiteName/hostruntime/runtime/webhooks/workflow/api/management/workflows/$WorkflowName/runs?api-version=2022-03-01&" + '$top=3'
$runs = Invoke-RestMethod -Method GET -Uri $runsUri -Headers $H
$runItems = Get-CollectionItems $runs
$runItems | ForEach-Object {
    [pscustomobject]@{
        Name   = $_.name
        Status = $_.properties.status
        Code   = $_.properties.code
        Start  = $_.properties.startTime
        End    = $_.properties.endTime
    }
} | Format-Table -AutoSize | Out-String | Write-Host

$last = $runItems | Select-Object -First 1
if ($last -and $last.properties.status -ne 'Succeeded') {
    Write-Section "6) Failed actions detail (run = $($last.name))"
    $actsUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$SiteName/hostruntime/runtime/webhooks/workflow/api/management/workflows/$WorkflowName/runs/$($last.name)/actions?api-version=2022-03-01"
    $acts = Invoke-RestMethod -Method GET -Uri $actsUri -Headers $H
    $actItems = Get-CollectionItems $acts
    $actItems | Where-Object { $_.properties.status -ne 'Succeeded' } | ForEach-Object {
        Write-Host "--- $($_.name)  [$($_.properties.status) / $($_.properties.code)]" -ForegroundColor Yellow
        if ($_.properties.error) {
            $_.properties.error | ConvertTo-Json -Depth 6
        }
        # outputs を SAS URL から（ヘッダ無しで）取得
        if ($_.properties.outputsLink) {
            "  outputs:"
            try {
                Invoke-RestMethod -Method GET -Uri $_.properties.outputsLink.uri | ConvertTo-Json -Depth 6
            } catch {
                "  (取得失敗: $($_.Exception.Message))"
            }
        }
    }
}

Write-Section "Done"
"Workflow  : $WorkflowName"
"Recipient : $RecipientAadObjectId"
