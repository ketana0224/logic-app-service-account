// =============================================================================
// parameters.prod.bicepparam
// 本番 (prod) パラメーター — main.bicep 用
//
// 使い方:
//   az deployment group create \
//     -g rg-sendmsg-app \
//     -f infrastructure/bicep/main.bicep \
//     -p infrastructure/bicep/parameters.prod.bicepparam
// =============================================================================

using './main.bicep'

// デプロイ先リージョン (Linux WS1 不可、Windows のみ。westus2 / japaneast / eastus2 等)
param location = 'eastus2'

// 環境識別子 / リソース名プレフィックス
param namePrefix = 'sendmsg'

// Logic App Standard
param logicAppName = 'la-sendmsg-m365-connector'

// Key Vault (グローバル一意)
param keyVaultName = 'kv-sendmsg-001'

// Storage Account 名は uniqueString で自動採番されるため未指定 (上書きしたい場合のみ設定)
// param storageAccountName = 'stsendmsg001'

// App Service Plan (WS1)
param appServicePlanName = 'asp-sendmsg-workflow'

// ネットワーク
param vnetName = 'vnet-sendmsg'
param vnetAddressPrefix = '10.0.0.0/16'
param subnetLogicAppPrefix = '10.0.1.0/27'
param subnetPepPrefix = '10.0.2.0/27'
param subnetFirewallPrefix = '10.0.3.0/26'
param subnetJumpboxPrefix = '10.0.4.0/27'

// Firewall
param firewallName = 'afw-sendmsg'
param firewallPolicyName = 'afwp-sendmsg'

// Observability
param logAnalyticsName = 'log-sendmsg'
param appInsightsName = 'appi-sendmsg'

// ワークフロー OAuth (M365 サービスアカウント / Entra アプリ)
// 値は環境ごとに設定してください (scripts/.env.local の M365_TENANT_ID / ENTRA_APP_CLIENT_ID)
param m365TenantId = '655bd66a-5001-4cb3-9aad-ce54a27d5d95'
param entraAppClientId = '6c8fb6bd-cc96-4a2e-86b5-450b3a0dc196'

// タグ
param tags = {
  workload: 'logic-app-service-account'
  env: 'prod'
}
