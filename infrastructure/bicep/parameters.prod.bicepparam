// =============================================================================
// parameters.prod.bicepparam
// 本番 (prod) パラメーター — main.bicep 用
//
// 使い方:
//   az deployment group create \
//     -g rg-dir \
//     -f infrastructure/bicep/main.bicep \
//     -p infrastructure/bicep/parameters.prod.bicepparam
// =============================================================================

using './main.bicep'

// デプロイ先リージョン (Linux WS1 不可、Windows のみ。westus2 / japaneast / eastus2 等)
param location = 'westus2'

// 環境識別子 / リソース名プレフィックス
param namePrefix = 'dir'

// Logic App Standard
param logicAppName = 'la-dir-m365-connector'

// Key Vault (グローバル一意)
param keyVaultName = 'kv-dirm365-3647'

// Storage Account 名は uniqueString で自動採番されるため未指定 (上書きしたい場合のみ設定)
// param storageAccountName = 'stdirm365xxxxxx'

// App Service Plan (WS1)
param appServicePlanName = 'asp-dir-workflow'

// ネットワーク
param vnetName = 'vnet-dir'
param vnetAddressPrefix = '10.0.0.0/16'
param subnetLogicAppPrefix = '10.0.1.0/27'
param subnetPepPrefix = '10.0.2.0/27'
param subnetFirewallPrefix = '10.0.3.0/26'
param subnetJumpboxPrefix = '10.0.4.0/27'

// Firewall
param firewallName = 'afw-dir'
param firewallPolicyName = 'afwp-dir'

// Observability
param logAnalyticsName = 'log-dir'
param appInsightsName = 'appi-dir'

// タグ
param tags = {
  workload: 'logic-app-service-account'
  env: 'prod'
}
