# Quick Start Guide

## 前提条件チェックリスト

- [ ] Azure subscription (Enterprise / Dev / Test 可)
- [ ] Microsoft 365 テナント (Teams ライセンス付き)
- [ ] Azure CLI (`az --version`)
- [ ] PowerShell 7.0+ (`pwsh --version`)
- [ ] Git
- [ ] ローカル PC: Windows / macOS / Linux

## セットアップステップ (所要時間: 約 2 時間)

### Phase 0: 環境変数の設定 (5 分)

#### 方法 1: 対話スクリプトを使用（推奨）

```powershell
# Azure にログイン
az login

# リポジトリをクローン
git clone https://github.com/YOUR-ORG/logic-app-service-account.git
cd logic-app-service-account

# 対話形式でセットアップ
pwsh ./setup-env.ps1
```

このスクリプトは以下を自動的に行います：
- ✅ Azure コンテキストの検証
- ✅ 必須環境変数を対話的に入力
- ✅ `scripts/.env.local` ファイルを自動生成
- ✅ 環境変数の検証

補足:
- `SERVICE_ACCOUNT_UPN` は未作成なら空でスキップ可能
- ただし、Phase 3 (OAuth bootstrap) 前には必ず設定

その後、環境変数をロード：
```powershell
. ./scripts/load-env.ps1
```

#### 方法 2: 手動で環境変数を設定

```powershell
# Azure にログイン
az login

# リポジトリをクローン
git clone https://github.com/YOUR-ORG/logic-app-service-account.git
cd logic-app-service-account

# 環境変数を設定 (.env.local ファイルまたはシェル環境)
$env:AZURE_SUBSCRIPTION_ID = "<AZURE_SUBSCRIPTION_ID>"
$env:AZURE_TENANT_ID = "<AZURE_TENANT_ID>"                       # Azure tenant
$env:M365_TENANT_ID = "<M365_TENANT_ID>"                         # Microsoft 365 tenant
# Service Account 未作成なら後で設定可（Phase 3 前には必須）
$env:SERVICE_ACCOUNT_UPN = "<service-account>@<your-m365-tenant>.onmicrosoft.com"
$env:RESOURCE_GROUP_NAME = "<RESOURCE_GROUP_NAME>"
$env:LOCATION = "<LOCATION>"                                      # 例: westus2, japaneast, eastus2
$env:LOGIC_APP_NAME = "la-sendmsg-m365-connector"                 # la-<workload>-<purpose>
$env:KEY_VAULT_NAME = "kv-sendmsg-001"                            # kv-<workload>-001 (グローバル一意)
$env:STORAGE_ACCOUNT_NAME = "stsendmsg001"                        # st<workload>001 (英小文字/数字のみ)
$env:APP_SERVICE_PLAN_NAME = "asp-sendmsg-workflow"               # asp-<workload>-workflow
$env:VNET_NAME = "vnet-sendmsg"                                   # vnet-<workload>
$env:FIREWALL_NAME = "afw-sendmsg"                                # afw-<workload>
$env:FIREWALL_POLICY_NAME = "afwp-sendmsg"                        # afwp-<workload>
$env:LOG_ANALYTICS_NAME = "log-sendmsg"                           # log-<workload>
$env:APP_INSIGHTS_NAME = "appi-sendmsg"                           # appi-<workload>

# ↓ Phase 2 で App Registration を作成すると発行される値 (Phase 0 ではまだ未確定)
#   Phase 2 ステップ 3 完了後に設定する。利用は Phase 3 (OAuth bootstrap)。
# $env:ENTRA_APP_CLIENT_ID = "<ENTRA_APP_CLIENT_ID>"
```

> **推奨**: `pwsh ./setup-env.ps1` を使用して環境変数を設定することを強くお勧めします。詳細は [README.md](README.md#-環境変数セットアップ) を参照。

### Phase 1: インフラストラクチャの新規作成とデプロイ (45 分)

クローズドネットワーク基盤一式を Bicep でデプロイする。

```powershell
# パラメータファイルをカスタマイズ
# infrastructure/bicep/parameters.prod.bicepparam を編集
#   - location は Windows WS1 が使えるリージョンを指定 (例: westus2 / japaneast / eastus2)
#     ※ Linux WS1 は westus2 で利用不可、Windows 一択
#   - keyVaultName / logicAppName 等のグローバル一意名を必要に応じて変更

# リソースグループを作成
az group create -n $env:RESOURCE_GROUP_NAME -l $env:LOCATION

# デプロイ前に検証 (what-if)
az deployment group what-if `
    -g $env:RESOURCE_GROUP_NAME `
    --template-file infrastructure/bicep/main.bicep `
    --parameters infrastructure/bicep/parameters.prod.bicepparam

# デプロイ
az deployment group create `
    -n logic-app-deployment-$(Get-Date -Format 'yyyyMMddHHmmss') `
    -g $env:RESOURCE_GROUP_NAME `
    --template-file infrastructure/bicep/main.bicep `
    --parameters infrastructure/bicep/parameters.prod.bicepparam `
        location=$env:LOCATION `
        logicAppName=$env:LOGIC_APP_NAME `
        keyVaultName=$env:KEY_VAULT_NAME `
        storageAccountName=$env:STORAGE_ACCOUNT_NAME `
        appServicePlanName=$env:APP_SERVICE_PLAN_NAME `
        vnetName=$env:VNET_NAME `
        firewallName=$env:FIREWALL_NAME `
        firewallPolicyName=$env:FIREWALL_POLICY_NAME `
        logAnalyticsName=$env:LOG_ANALYTICS_NAME `
        appInsightsName=$env:APP_INSIGHTS_NAME
```

作成されるリソース (所要時間: 30〜45 分):
- VNet + 4 Subnets (snet-logicapp / snet-pep / AzureFirewallSubnet / snet-jumpbox)
- Route Table `rt-sendmsg-egress` (0.0.0.0/0 → Azure Firewall)
- Public IP + Azure Firewall + Firewall Policy `afwp-sendmsg` (OAuth / Graph 許可ルール)
- Log Analytics + Application Insights
- Key Vault (`publicNetworkAccess=Disabled`、RBAC 認可)
- Storage Account (Logic App host state)
- App Service Plan (WS1) + Logic App Standard (System-Assigned Managed Identity)
- 6 Private Endpoints + 6 Private DNS Zones (+ VNet link)
- RBAC: Logic App SAMI → Key Vault Secrets Officer + Storage ロール

> **ポリシー準拠メモ**: `allowSharedKeyAccess=false` のままデプロイ可能。
> `AzureWebJobsStorage` は Managed Identity 接続（`AzureWebJobsStorage__*`）を使用し、
> `WEBSITE_CONTENTAZUREFILECONNECTIONSTRING` は使わない構成。

> **補足**: VNet 統合後に `vnetRouteAllEnabled` を再適用したい場合は
> [scripts/la-vnetroute.ps1](scripts/la-vnetroute.ps1) を使用する。
> ARM テンプレート版 (`infrastructure/arm-templates/`) は現時点では未提供。
> ARM が必要な場合は `az bicep build` で main.bicep から `deploy.json` を生成できる:
>
> ```powershell
> az bicep build --file infrastructure/bicep/main.bicep `
>     --outfile infrastructure/arm-templates/deploy.json
> ```

### Phase 2: Service Account の準備 (5 分)

Microsoft 365 テナント管理者が以下を実施:

1. **Service Account ユーザーを作成**
   - UPN: `system-notify@<your-m365-tenant>.onmicrosoft.com`
   - ユーザータイプ: **標準ユーザー** (Shared Mailbox ❌)
   - ライセンス: **Microsoft 365 E3/E5 (Teams 含む)**

2. **恒久パスワードを設定**
   ```
   Azure AD > Users > system-notify
   → Reset Password (Temporary password ではなく、恒久パスワード)
   → 「Change password on next sign-in」= OFF
   → TAP (Temporary Access Pass) ❌ 絶対禁止
   ```

3. **Entra App Registration を作成**
    ```
    Entra ID > アプリの登録 > 新規登録
    名前: Logic App Service Account Auth
    サポートされているアカウントの種類: シングル テナントのみ
    リダイレクト URI: 未設定のままで可
    ```

4. **登録後に Redirect URI を追加**
    ```
    概要 > リダイレクト URI を追加する
    または Authentication (Preview)
    > リダイレクト URI の構成
    > リダイレクト URI の追加
    > プラットフォームを追加 > モバイルとデスクトップのアプリケーション
    Redirect URI: http://localhost:8400/callback

    → アプリケーション (クライアント) ID をメモ
    → 環境変数に設定: $env:ENTRA_APP_CLIENT_ID = "<発行された Client ID>"
    ```

5. **Delegated 権限を付与**
   ```
   API permissions:
   - Microsoft Graph → Delegated
     - User.Read
     - Chat.ReadWrite
     - ChatMessage.Send
     - offline_access
   
   → Admin consent を付与
   ```

6. **(オプション) Conditional Access 除外グループを作成**
   ```
   Entra ID > Groups > New group
   Name: grp-automation-accounts
   Members: system-notify
   
   CA ポリシー > Sign-in Frequency / Risk-based
   → User exclusions = grp-automation-accounts
   ```

### Phase 3: OAuth Bootstrap (20 分)

bootstrap スクリプトはローカル PC から Key Vault へ `refresh_token` を直接書き込む。
Key Vault は `publicNetworkAccess=Disabled` のため一時開放が必要。

> **代替案**: VNet 内の Jumpbox や Azure DevOps Self-hosted Runner など  
> Private Endpoint 経由で Key Vault にアクセスできる実行環境があれば、  
> 下記の「一時開放 → 閉鎖」手順は不要。

Key Vault を一時的に開放（ローカル PC から実行する場合のみ）:

```powershell
$kvName = "<KEY_VAULT_NAME>"  # 実際の名称に置き換え

# Public access を enabled (実行者 PC からのアクセスのみ許可推奨)
az keyvault update -n $kvName -g $env:RESOURCE_GROUP_NAME `
    --public-network-access Enabled `
    --default-action Allow `
    --bypass AzureServices
```

Bootstrap スクリプト実行:

```powershell
pwsh ./scripts/la-oauth-bootstrap.ps1 `
    -TenantId $env:M365_TENANT_ID `
    -ClientId $env:ENTRA_APP_CLIENT_ID `
    -KeyVaultName $kvName `
    -ServiceAccountUPN $env:SERVICE_ACCOUNT_UPN
```

ブラウザが開く → Service Account でサインイン (恒久パスワード) → Authorization Code 取得 → refresh_token が KV に自動保存

成功時:
```
Service Account: <service-account>@<your-m365-tenant>.onmicrosoft.com
Object ID: <SERVICE_ACCOUNT_OBJECT_ID>
refresh_token stored in: <KEY_VAULT_NAME>/m365-system-notify-refresh-token

Results saved to bootstrap-results.json
```

Key Vault を完全に閉鎖:

```powershell
az keyvault update -n $kvName -g $env:RESOURCE_GROUP_NAME `
    --public-network-access Disabled `
    --default-action Deny `
    --bypass AzureServices
```

### Phase 4: ワークフローのデプロイ (10 分)

EVL-04d (Teams 通知送信):

```powershell
cd workflows/EVL-04d-TeamsNotify
pwsh ./deploy.ps1
```

出力:
```
✓ Workflow deployed: EVL-04d-TeamsNotify
Callback URL: https://<LOGIC_APP_NAME>.azurewebsites.net/api/Team...
callback-url.txt に保存済み
```

EVL-99 (トークンヘルスチェック):

```powershell
cd ../EVL-99-TokenHealthCheck
pwsh ./deploy.ps1
```

### Phase 5: テスト実行 (15 分)

テストメッセージを送信:

```powershell
cd workflows/EVL-04d-TeamsNotify

# 特定ユーザーへ
pwsh ./test.ps1 -Target "Adil"

# 複数ユーザーへ
pwsh ./test.ps1 -Target "Both"
```

Teams で通知を確認:

```
[Logic App Service Account]
Subject: Teams Notification from Logic App

This is a test message sent via Service Account auth flow.
----
Sent: 2026-06-12T03:46:20Z
run-id: 08584203709072358571743386284CU00
```

### Phase 6: Logic App のネットワーク設定確認（5 分)

このテンプレートでは Logic App は初期デプロイ時点で `publicNetworkAccess=Disabled`。以下は確認用:

```powershell
# Logic App を確認
az resource show \
    --ids "/subscriptions/$env:AZURE_SUBSCRIPTION_ID/resourceGroups/$env:RESOURCE_GROUP_NAME/providers/Microsoft.Web/sites/<LOGIC_APP_NAME>" \
    --query properties.publicNetworkAccess

# 必要時のみ（手動で Enabled にした場合）Public access を disable
az resource update \
    --ids "/subscriptions/$env:AZURE_SUBSCRIPTION_ID/resourceGroups/$env:RESOURCE_GROUP_NAME/providers/Microsoft.Web/sites/<LOGIC_APP_NAME>" \
    --api-version 2023-12-01 \
    --set properties.publicNetworkAccess=Disabled
```

### Phase 7: 踏み台 VM の作成 (PE テスト用 - オプション）

```powershell
pwsh ./scripts/la-jumpbox-create.ps1 `
    -ResourceGroupName $env:RESOURCE_GROUP_NAME `
    -VnetName $env:VNET_NAME
```

注記:
- 実行時に管理者パスワードの対話入力が求められる。
- 既定イメージは Windows 11 Pro, version 24H2、ライセンスは BYOL (`Windows_Client`)。

### Phase 8: 本番運用開始

これで setup 完了！本番へ。

## よくある質問

### Q1: bootstrap-results.json には何が入ってますか？

```json
{
  "timestamp": "2026-06-12T03:42:10Z",
  "userPrincipalName": "<service-account>@<your-m365-tenant>.onmicrosoft.com",
  "objectId": "<SERVICE_ACCOUNT_OBJECT_ID>",
  "tenantId": "<M365_TENANT_ID>",
  "clientId": "<ENTRA_APP_CLIENT_ID>",
  "keyVaultName": "<KEY_VAULT_NAME>",
  "refreshTokenSecretName": "m365-system-notify-refresh-token"
}
```

監査ログ / 管理記録として保存。Secret は含まれません（安全）。

### Q2: refresh_token はどのくらい持つんですか？

- Entra ID 既定: **90 日 (sliding)**
- EVL-99: **6 時間ごと自動 rotation** で 90 日カウンタをリセット
- 結果: **ほぼ無期限** (Logic App が動いている限り)

### Q3: パスワード変更したら どうなりますか？

Service Account が自分でパスワード変更: ✅ 影響なし

Admin が reset: ❌ session revoke で refresh_token 失効

→ 再 bootstrap が必要 (Key Vault 開放 → bootstrap → 閉鎖)

### Q4: Teams メッセージが送信されない

確認項目:

```powershell
# 1. Logic App run をチェック
pwsh ./check-run.ps1 -RunId "<runId>"

# 2. 詳細ログを確認
az logicapp workflow show-run \
    -g $env:RESOURCE_GROUP_NAME \
    -n <LOGIC_APP_NAME> \
    -r EVL-04d-TeamsNotify \
    --run-name <runId>
```

一般的な原因:
- **Token_Refresh 403**: Service Account が TAP でサインイン → 再 bootstrap
- **Create_Chat BadRequest**: recipient OID が間違っている
- **Send_Message 403**: delegated 権限が不足 → admin consent 確認

### Q5: 費用はいくらぐらい？

月額概算 (westus2, Pay-as-you-go):

| コンポーネント | 月額 |
|---|---:|
| Logic App Standard WS1 | $235 |
| Private Endpoints (6) | $44 |
| その他 (KV, Storage, DNS) | $5 |
| **合計** | **$284/月** |
| + Azure Firewall (新規の場合) | +$900-1200/月 |

## トラブルシューティング

問題が発生した場合:

1. Logic App run history を確認 (`check-run.ps1`)
3. Key Vault secret が存在しているか確認
4. Conditional Access policy が SA をブロックしていないか確認

## 次のステップ

- ✅ インフラ完成
- ✅ OAuth bootstrap 完了
- ✅ ワークフロー動作確認済み

以下を検討:

1. **Integration**: callback URL を 業務アプリに統合
2. **Monitoring**: Application Insights を有効化 → ログ収集
3. **Automation**: EVL-04c のリソース削除 (Phase 8)
4. **Scalability**: 複数 SA 対応、multi-tenant 拡張

---

**ドキュメント**: [README.md](../README.md) / [docs/](../docs/)
