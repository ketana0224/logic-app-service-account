<#
.SYNOPSIS
  踏み台 VM 上で Azure に対話ログインする（Az.Accounts ベース）。

.DESCRIPTION
  - Az.Accounts モジュールが無ければ CurrentUser スコープで自動インストール
  - Connect-AzAccount で対話ログイン（ブラウザが開かない場合は -UseDeviceAuthentication にフォールバック）
  - 既に同じテナント / サブスクリプションに接続済みならスキップ
  - 完了後、Logic App への RBAC を表示

.EXAMPLE
  pwsh -File C:\scripts\la-jumpbox-login.ps1

.EXAMPLE
  # 強制的に再ログインしたい場合
  pwsh -File C:\scripts\la-jumpbox-login.ps1 -Force

.NOTES
  ログイン後は同じ PowerShell プロセスで `la-evl04d-test.ps1` を実行すれば
  Get-AzAccessToken でトークンを取り直して使えます。
#>

[CmdletBinding()]
param(
    [string]$TenantId       = $(if ($env:AZURE_TENANT_ID)      { $env:AZURE_TENANT_ID }      else { "<azure-tenant-id>" }),
    [string]$SubscriptionId = $(if ($env:AZURE_SUBSCRIPTION_ID) { $env:AZURE_SUBSCRIPTION_ID } else { "<azure-subscription-id>" }),
    [string]$ResourceGroup  = $(if ($env:AZURE_RESOURCE_GROUP)  { $env:AZURE_RESOURCE_GROUP }  else { "<resource-group>" }),
    [string]$SiteName       = $(if ($env:LOGIC_APP_NAME)        { $env:LOGIC_APP_NAME }        else { "<logic-app-name>" }),
    [switch]$Force
)

$ErrorActionPreference = "Stop"

function Write-Section($title) { Write-Host ""; Write-Host "==== $title ====" -ForegroundColor Cyan }

# ---- 1) Az.Accounts 準備 ----
Write-Section "1) Az.Accounts module"
if (-not (Get-Module -ListAvailable Az.Accounts)) {
    "Installing Az.Accounts (CurrentUser scope)..."
    if (-not (Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -Force -Scope CurrentUser | Out-Null
    }
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction SilentlyContinue
    Install-Module Az.Accounts -Scope CurrentUser -Force -AllowClobber
}
Import-Module Az.Accounts -ErrorAction Stop
"Module : Az.Accounts $((Get-Module Az.Accounts).Version)"

# ---- 2) 既存コンテキスト確認 ----
Write-Section "2) Current context"
$ctx = Get-AzContext -ErrorAction SilentlyContinue
if ($ctx -and -not $Force -and $ctx.Tenant.Id -eq $TenantId -and $ctx.Subscription.Id -eq $SubscriptionId) {
    "✅ 既にログイン済み (skip):"
    "  Account      : $($ctx.Account.Id)"
    "  Tenant       : $($ctx.Tenant.Id)"
    "  Subscription : $($ctx.Subscription.Name) ($($ctx.Subscription.Id))"
} else {
    if ($ctx) { "Re-login (current: $($ctx.Account.Id) / $($ctx.Subscription.Name))" }
    Write-Section "3) Connect-AzAccount"
    try {
        Connect-AzAccount -Tenant $TenantId -Subscription $SubscriptionId -ErrorAction Stop | Out-Null
    } catch {
        Write-Warning "通常ログイン失敗。デバイスコード認証にフォールバックします。理由: $($_.Exception.Message)"
        Connect-AzAccount -Tenant $TenantId -Subscription $SubscriptionId -UseDeviceAuthentication | Out-Null
    }
    $ctx = Get-AzContext
    "✅ Logged in:"
    "  Account      : $($ctx.Account.Id)"
    "  Tenant       : $($ctx.Tenant.Id)"
    "  Subscription : $($ctx.Subscription.Name) ($($ctx.Subscription.Id))"
}

# ---- 4) ARM トークン取得テスト ----
Write-Section "4) ARM token test"
$t = Get-AzAccessToken -ResourceUrl "https://management.azure.com/" -WarningAction SilentlyContinue
if ($t.Token -is [System.Security.SecureString]) {
    $tok = [System.Net.NetworkCredential]::new("", $t.Token).Password
} else {
    $tok = [string]$t.Token
}
"Token type : $($t.Token.GetType().Name)"
"Token head : $($tok.Substring(0,20))..."
"Expires    : $($t.ExpiresOn)"

# ---- 5) Logic App への RBAC 確認 ----
Write-Section "5) RBAC on $SiteName"
$scope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Web/sites/$SiteName"
$H = @{ Authorization = "Bearer $tok" }
try {
    $meUri  = "https://graph.microsoft.com/v1.0/me"
    # ARM の signed-in user は ARM だけでは取りにくいので、ロール割当を scope+assignee で問い合わせ
    # → assignee 解決を省くため、role assignments を scope で全件取って自分のものを抽出
    $raUri  = "https://management.azure.com$scope/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=atScope()"
    $ra     = Invoke-RestMethod -Method GET -Uri $raUri -Headers $H
    $myObj  = $ctx.Account.ExtendedProperties.HomeAccountId.Split('.')[0]
    $mine   = $ra.value | Where-Object { $_.properties.principalId -eq $myObj }
    if ($mine) {
        $mine | ForEach-Object {
            $defId = $_.properties.roleDefinitionId
            $defNm = (Invoke-RestMethod -Method GET -Uri "https://management.azure.com$defId`?api-version=2022-04-01" -Headers $H).properties.roleName
            "  Role: $defNm"
        }
    } else {
        Write-Warning "  この scope (atScope) に直接の role assignment は見つかりません（親 scope からの継承で動く可能性あり）。"
    }
} catch {
    Write-Warning "RBAC 取得に失敗（実行には影響しません）: $($_.Exception.Message)"
}

Write-Section "Done"
"次のコマンドでテスト実行できます:"
"  pwsh -File C:\scripts\la-evl04d-test.ps1"
