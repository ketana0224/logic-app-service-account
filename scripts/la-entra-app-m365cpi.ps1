$ErrorActionPreference = "Stop"

# G4' Phase 1d (修正版): Entra App を M365 テナントに作成し、
# Logic App (Azure サブスクリプション) の App Settings に値を登録する。
# 機密値はすべて環境変数で上書き可能。未設定時はプレースホルダのため実行前に設定すること。

$appName     = if ($env:ENTRA_APP_NAME)     { $env:ENTRA_APP_NAME }     else { "app-system-notify-broker" }
$redirectUri = if ($env:OAUTH_REDIRECT_URI) { $env:OAUTH_REDIRECT_URI } else { "http://localhost:8400/callback" }

# 2 テナントの subscription/tenant 識別子（環境変数で上書き可）
$m365cpiTenantId   = if ($env:M365_TENANT_ID)         { $env:M365_TENANT_ID }         else { "<m365-tenant-id>" }
$m365cpiSubName    = if ($env:M365_SUBSCRIPTION_NAME) { $env:M365_SUBSCRIPTION_NAME } else { "<m365-subscription-name>" }  # App 作成用に context として使う
$azureSubId        = if ($env:AZURE_SUBSCRIPTION_ID)  { $env:AZURE_SUBSCRIPTION_ID }  else { "<azure-subscription-id>" }  # Logic App 側
$azureRg           = if ($env:AZURE_RESOURCE_GROUP)   { $env:AZURE_RESOURCE_GROUP }   else { "<resource-group>" }
$azureLogicApp     = if ($env:LOGIC_APP_NAME)         { $env:LOGIC_APP_NAME }         else { "<logic-app-name>" }

# Microsoft Graph delegated permission IDs (公式定数)
$graphAppId         = "00000003-0000-0000-c000-000000000000"
$permUserRead       = "e1fe6dd8-ba31-4d61-89e7-88639da4683d"  # User.Read
$permOfflineAccess  = "7427e0e9-2fba-42fe-b0c0-848c9e6a8182"  # offline_access
$permChatReadWrite  = "9ff7295e-131b-4d94-90e1-69fde507ac11"  # Chat.ReadWrite
$permChatMsgSend    = "116b7235-7cc6-461e-b163-8e55691d839e"  # ChatMessage.Send

# ==== Step 0: 現在の context を退避し、M365CPI に切替 ====
Write-Host "=== 0) M365 テナント context に切替 ===" -ForegroundColor Cyan
$origSub = az account show --query id -o tsv
Write-Host "  退避: origSub=$origSub" -ForegroundColor Gray
az account set --subscription $m365cpiSubName | Out-Null
$ctx = az account show --query "{tenantId:tenantId, user:user.name, sub:name}" -o jsonc | ConvertFrom-Json
Write-Host "  切替後: tenant=$($ctx.tenantId) user=$($ctx.user) sub=$($ctx.sub)" -ForegroundColor Green
if ($ctx.tenantId -ne $m365cpiTenantId) {
  throw "context が M365CPI ($m365cpiTenantId) に切替わっていません。az login を確認してください。"
}

try {
  # ==== Step 1: App 作成 ====
  Write-Host "`n=== 1) Entra App 作成: $appName (M365CPI) ===" -ForegroundColor Cyan
  $existing = az ad app list --display-name $appName --query "[0].appId" -o tsv
  if ($existing) {
    Write-Host "  既存 App を再利用: appId=$existing" -ForegroundColor Gray
    $appId = $existing
  } else {
    $rraJson = @"
[
  {
    "resourceAppId": "$graphAppId",
    "resourceAccess": [
      { "id": "$permUserRead", "type": "Scope" },
      { "id": "$permOfflineAccess", "type": "Scope" },
      { "id": "$permChatReadWrite", "type": "Scope" },
      { "id": "$permChatMsgSend", "type": "Scope" }
    ]
  }
]
"@
    $rraPath = "$env:TEMP\rra-m365cpi.json"
    [System.IO.File]::WriteAllText($rraPath, $rraJson, [System.Text.UTF8Encoding]::new($false))
    $appId = az ad app create --display-name $appName --sign-in-audience AzureADMyOrg --required-resource-accesses "@$rraPath" --query appId -o tsv
    Write-Host "  作成成功: appId=$appId" -ForegroundColor Green
  }

  # ==== Step 2: Public Client + Redirect URI ====
  Write-Host "`n=== 2) Public Client + Redirect URI 設定 ===" -ForegroundColor Cyan
  $objectId = az ad app show --id $appId --query id -o tsv
  $patchBody = @{
    isFallbackPublicClient = $true
    publicClient = @{
      redirectUris = @($redirectUri)
    }
  } | ConvertTo-Json -Depth 5 -Compress
  $bodyPath = "$env:TEMP\app-patch-m365cpi.json"
  [System.IO.File]::WriteAllText($bodyPath, $patchBody, [System.Text.UTF8Encoding]::new($false))
  az rest --method patch --uri "https://graph.microsoft.com/v1.0/applications/$objectId" --body "@$bodyPath" --headers "Content-Type=application/json"
  Write-Host "  Public client + redirect URI 設定完了" -ForegroundColor Green

  # ==== Step 3: Service Principal ====
  Write-Host "`n=== 3) Service Principal 作成 (admin consent の前提) ===" -ForegroundColor Cyan
  $sp = az ad sp list --filter "appId eq '$appId'" --query "[0].id" -o tsv
  if (-not $sp) {
    $sp = az ad sp create --id $appId --query id -o tsv
    Write-Host "  SP 作成: id=$sp" -ForegroundColor Green
  } else {
    Write-Host "  既存 SP を再利用: id=$sp" -ForegroundColor Gray
  }

  # ==== Step 4: Admin consent ====
  Write-Host "`n=== 4) Admin consent (M365CPI tenant-wide) ===" -ForegroundColor Cyan
  az ad app permission admin-consent --id $appId
  Write-Host "  admin-consent 投入完了 (反映に数十秒かかる場合あり)" -ForegroundColor Green

  # 取得した値を保持
  $script:newAppId = $appId
}
finally {
  # ==== Step 5: Azure 側サブスクリプションに切戻 ====
  Write-Host "`n=== 5) Azure サブスクリプション context に切戻 ===" -ForegroundColor Cyan
  az account set --subscription $azureSubId | Out-Null
  $back = az account show --query "{tenantId:tenantId, user:user.name, sub:name}" -o jsonc | ConvertFrom-Json
  Write-Host "  切戻後: tenant=$($back.tenantId) user=$($back.user) sub=$($back.sub)" -ForegroundColor Green
}

# ==== Step 6: Logic App App Settings 上書き ====
Write-Host "`n=== 6) Logic App App Settings 上書き ===" -ForegroundColor Cyan
az functionapp config appsettings set -g $azureRg -n $azureLogicApp --settings `
  "ENTRA_TENANT_ID=$m365cpiTenantId" `
  "ENTRA_CLIENT_ID=$($script:newAppId)" `
  "OAUTH_REDIRECT_URI=$redirectUri" `
  -o table | Out-Null
Write-Host "  App Settings 設定完了" -ForegroundColor Green

# ==== 結果 ====
Write-Host "`n=== 結果サマリ ===" -ForegroundColor Cyan
Write-Host "App name      : $appName"                          -ForegroundColor Green
Write-Host "App ID (new)  : $($script:newAppId)"               -ForegroundColor Green
Write-Host "Tenant        : $m365cpiTenantId" -ForegroundColor Green
Write-Host "Redirect      : $redirectUri"                      -ForegroundColor Green
Write-Host "Scopes        : User.Read, offline_access, Chat.ReadWrite, ChatMessage.Send" -ForegroundColor Green
Write-Host "Logic App     : $azureLogicApp (rg=$azureRg, sub=$azureSubId)" -ForegroundColor Green
