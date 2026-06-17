# EVL-04c teardown スクリプト (G4' 完成後の不要リソース削除)
#
# 対象: リソースグループに残っている evl04c-* リソース 6 件
#
# 削除順序 (依存関係考慮):
#   1. Bot Service              (Function App messaging endpoint 参照を切る)
#   2. Function App             (App Service Plan 依存)
#   3. App Service Plan         (Functions 削除後)
#   4. EventGrid System Topic   (Storage 連動)
#   5. Storage Account          (Function App 依存解除後)
#   6. Application Insights     (Function App から参照解除後)
#
# 使い方:
#   pwsh -File la-evl04c-teardown.ps1                 # dry-run (削除しない)
#   pwsh -File la-evl04c-teardown.ps1 -Confirm        # 実削除
#
# ⚠️ 削除は不可逆。事前に G4' (EVL-04d-TeamsNotify) が安定稼働していることを確認すること。

param(
  [Parameter(Mandatory = $false)]
  [switch]$Confirm,

  [string]$SubscriptionId    = $(if ($env:AZURE_SUBSCRIPTION_ID) { $env:AZURE_SUBSCRIPTION_ID } else { "<azure-subscription-id>" }),
  [string]$ResourceGroupName = $(if ($env:AZURE_RESOURCE_GROUP)  { $env:AZURE_RESOURCE_GROUP }  else { "<resource-group>" }),
  [string]$SiteName          = $(if ($env:LOGIC_APP_NAME)        { $env:LOGIC_APP_NAME }        else { "<logic-app-name>" })
)

$ErrorActionPreference = "Stop"

Write-Host "=== Pre-flight check ===" -ForegroundColor Cyan
Write-Host "Subscription: $SubscriptionId"
Write-Host "ResourceGroup: $ResourceGroupName"
$ctx = az account show --query "{name:name, id:id, tenantId:tenantId}" -o jsonc | ConvertFrom-Json
if ($ctx.id -ne $SubscriptionId) {
  Write-Host "WARNING: current context id=$($ctx.id) != target $SubscriptionId" -ForegroundColor Yellow
  Write-Host "Switching context..."
  az account set --subscription $SubscriptionId
}

Write-Host ""
Write-Host "=== Target resources ===" -ForegroundColor Cyan
$resources = az resource list -g $ResourceGroupName --query "[?starts_with(name, 'evl04c')].{name:name, type:type, id:id}" -o json | ConvertFrom-Json
if (-not $resources -or $resources.Count -eq 0) {
  Write-Host "  No evl04c-* resources found. Nothing to delete." -ForegroundColor Green
  return
}
$resources | Format-Table name, type -AutoSize

Write-Host ""
Write-Host "=== G4' (EVL-04d) sanity check ===" -ForegroundColor Cyan
$la = az functionapp show -g $ResourceGroupName -n $SiteName --query "{state:state, publicNetworkAccess:publicNetworkAccess}" -o jsonc | ConvertFrom-Json
Write-Host "  Logic App $SiteName: state=$($la.state)  publicNetworkAccess=$($la.publicNetworkAccess)"
if ($la.state -ne "Running") {
  Write-Host "  [ABORT] Logic App が Running ではありません。teardown は実行しません。" -ForegroundColor Red
  return
}

if (-not $Confirm) {
  Write-Host ""
  Write-Host "=== DRY-RUN (-Confirm 未指定なので削除しません) ===" -ForegroundColor Yellow
  Write-Host "実削除するには:" -ForegroundColor Yellow
  Write-Host "  pwsh -File la-evl04c-teardown.ps1 -Confirm" -ForegroundColor Yellow
  return
}

Write-Host ""
Write-Host "=== Deleting (-Confirm specified) ===" -ForegroundColor Red

# ---------- 1. Bot Service ----------
$bot = $resources | Where-Object { $_.type -eq "Microsoft.BotService/botServices" }
if ($bot) {
  Write-Host "[1/6] Bot Service: $($bot.name)" -ForegroundColor Cyan
  az resource delete --ids $bot.id --verbose
  Write-Host "  Deleted." -ForegroundColor Green
}

# ---------- 2. Function App ----------
$fa = $resources | Where-Object { $_.type -eq "Microsoft.Web/sites" }
if ($fa) {
  Write-Host "[2/6] Function App: $($fa.name)" -ForegroundColor Cyan
  az functionapp delete -g $ResourceGroupName -n $fa.name
  Write-Host "  Deleted." -ForegroundColor Green
}

# ---------- 3. App Service Plan ----------
$plan = $resources | Where-Object { $_.type -eq "Microsoft.Web/serverFarms" }
if ($plan) {
  Write-Host "[3/6] App Service Plan: $($plan.name)" -ForegroundColor Cyan
  az resource delete --ids $plan.id --verbose
  Write-Host "  Deleted." -ForegroundColor Green
}

# ---------- 4. EventGrid System Topic ----------
$egst = $resources | Where-Object { $_.type -eq "Microsoft.EventGrid/systemTopics" }
if ($egst) {
  Write-Host "[4/6] EventGrid System Topic: $($egst.name)" -ForegroundColor Cyan
  az resource delete --ids $egst.id --verbose
  Write-Host "  Deleted." -ForegroundColor Green
}

# ---------- 5. Storage Account ----------
$st = $resources | Where-Object { $_.type -eq "Microsoft.Storage/storageAccounts" }
if ($st) {
  Write-Host "[5/6] Storage Account: $($st.name)" -ForegroundColor Cyan
  az storage account delete -g $ResourceGroupName -n $st.name --yes
  Write-Host "  Deleted." -ForegroundColor Green
}

# ---------- 6. Application Insights ----------
$ai = $resources | Where-Object { $_.type -eq "Microsoft.Insights/components" }
if ($ai) {
  Write-Host "[6/6] Application Insights: $($ai.name)" -ForegroundColor Cyan
  az resource delete --ids $ai.id --verbose
  Write-Host "  Deleted." -ForegroundColor Green
}

Write-Host ""
Write-Host "=== Post-check ===" -ForegroundColor Cyan
$after = az resource list -g $ResourceGroupName --query "[?starts_with(name, 'evl04c')].name" -o tsv
if (-not $after) {
  Write-Host "  All evl04c-* resources deleted." -ForegroundColor Green
} else {
  Write-Host "  Remaining:" -ForegroundColor Yellow
  $after | ForEach-Object { Write-Host "    $_" }
}

Write-Host ""
Write-Host "=== Done. G4' (EVL-04d-TeamsNotify + EVL-99-TokenHealthCheck) のみが稼働中です ===" -ForegroundColor Green
