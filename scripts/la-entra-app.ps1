$ErrorActionPreference = "Stop"
$appName = if ($env:ENTRA_APP_NAME)     { $env:ENTRA_APP_NAME }     else { "app-system-notify-broker" }
$redirectUri = if ($env:OAUTH_REDIRECT_URI) { $env:OAUTH_REDIRECT_URI } else { "http://localhost:8400/callback" }
$tenantId = if ($env:M365_TENANT_ID) { $env:M365_TENANT_ID } else { "<m365-tenant-id>" }
$resourceGroup = if ($env:AZURE_RESOURCE_GROUP) { $env:AZURE_RESOURCE_GROUP } else { "<resource-group>" }
$logicAppName  = if ($env:LOGIC_APP_NAME)       { $env:LOGIC_APP_NAME }       else { "<logic-app-name>" }

# Microsoft Graph delegated permission IDs (公式定数)
$graphAppId = "00000003-0000-0000-c000-000000000000"
$permUserRead       = "e1fe6dd8-ba31-4d61-89e7-88639da4683d"  # User.Read
$permOfflineAccess  = "7427e0e9-2fba-42fe-b0c0-848c9e6a8182"  # offline_access
$permChatReadWrite  = "9ff7295e-131b-4d94-90e1-69fde507ac11"  # Chat.ReadWrite
$permChatMsgSend    = "116b7235-7cc6-461e-b163-8e55691d839e"  # ChatMessage.Send

Write-Host "=== 1) Entra App 作成: $appName ===" -ForegroundColor Cyan
$existing = az ad app list --display-name $appName --query "[0].appId" -o tsv
if ($existing) {
  Write-Host "既存 App を再利用: appId=$existing" -ForegroundColor Gray
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
  $rraPath = "$env:TEMP\rra.json"
  [System.IO.File]::WriteAllText($rraPath, $rraJson, [System.Text.UTF8Encoding]::new($false))
  $appId = az ad app create --display-name $appName --sign-in-audience AzureADMyOrg --required-resource-accesses "@$rraPath" --query appId -o tsv
  Write-Host "作成成功: appId=$appId" -ForegroundColor Green
}

Write-Host "`n=== 2) Public Client + Redirect URI 設定 ===" -ForegroundColor Cyan
$objectId = az ad app show --id $appId --query id -o tsv
$patchBody = @{
  isFallbackPublicClient = $true
  publicClient = @{
    redirectUris = @($redirectUri)
  }
} | ConvertTo-Json -Depth 5 -Compress
$bodyPath = "$env:TEMP\app-patch.json"
[System.IO.File]::WriteAllText($bodyPath, $patchBody, [System.Text.UTF8Encoding]::new($false))
az rest --method patch --uri "https://graph.microsoft.com/v1.0/applications/$objectId" --body "@$bodyPath" --headers "Content-Type=application/json"
Write-Host "Public client + redirect URI 設定完了" -ForegroundColor Green

Write-Host "`n=== 3) Service Principal 作成 (admin consent の前提) ===" -ForegroundColor Cyan
$sp = az ad sp list --filter "appId eq '$appId'" --query "[0].id" -o tsv
if (-not $sp) {
  $sp = az ad sp create --id $appId --query id -o tsv
  Write-Host "SP 作成: id=$sp" -ForegroundColor Green
} else {
  Write-Host "既存 SP を再利用: id=$sp" -ForegroundColor Gray
}

Write-Host "`n=== 4) Admin consent (tenant-wide) ===" -ForegroundColor Cyan
az ad app permission admin-consent --id $appId
Write-Host "admin-consent 投入完了 (反映に数十秒かかる場合あり)" -ForegroundColor Green

Write-Host "`n=== 5) Logic App に App ID と Tenant ID を App Setting で登録 ===" -ForegroundColor Cyan
az functionapp config appsettings set -g $resourceGroup -n $logicAppName --settings `
  "ENTRA_TENANT_ID=$tenantId" `
  "ENTRA_CLIENT_ID=$appId" `
  "OAUTH_REDIRECT_URI=$redirectUri" `
  -o table | Out-Null
Write-Host "App Settings 設定完了" -ForegroundColor Green

Write-Host "`n=== 結果サマリ ===" -ForegroundColor Cyan
Write-Host "App name : $appName" -ForegroundColor Green
Write-Host "App ID   : $appId" -ForegroundColor Green
Write-Host "Tenant   : $tenantId" -ForegroundColor Green
Write-Host "Redirect : $redirectUri" -ForegroundColor Green
Write-Host "Scopes   : User.Read, offline_access, Chat.ReadWrite, ChatMessage.Send" -ForegroundColor Green
