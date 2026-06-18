# Logic App + Service Account 方式 (Built-in HTTP)

**別テナントの Azure から、Microsoft 365 (Teams) テナントへ 1:1 チャットを作成・通知する**ためのアーキテクチャ実装プロジェクト。

Azure リソースをホストするテナントと、Teams チャットを送る相手が所属する Microsoft 365 テナントが**異なる**構成を主旨としています。Service Account の delegated 権限 + refresh_token rotation により、M365 テナント側に Azure リソースを一切置かずにクロステナントで Teams チャットを自動作成します。

## 🎯 プロジェクト目標

- ✅ **クロステナント** (Azure ホストテナント ≠ M365/Teams テナント) で Teams 1:1 チャットを作成
- ✅ **Inbound Public ポート = 0** (Private Endpoint 経由のみ)
- ✅ **Microsoft 365 テナント側に Azure リソース不要**
- ✅ **refresh_token rotation** で 90 日無期限運用
- ✅ **Protected API 不要** (delegated 権限で実装)

> [!NOTE]
> **本実装はワークアラウンドです。**  
> Microsoft は Teams Bot 通知に **Azure Bot Service** の利用を公式推奨しています。  
> 本プロジェクトは、クロステナント構成・Inbound Public ポート 0・M365 側への Azure リソース不要・Protected API 回避という制約を満たすための代替実装です。  
> 制約が緩和された場合、またはアーキテクチャを見直す際は **Bot Service 方式への移行を強く推奨します**。

## 📁 プロジェクト構成

```
logic-app-service-account/
├── README.md                                     ← このファイル
├── .env.example                                  ← 環境変数テンプレート
├── setup-env.ps1                                 ← 環境変数セットアップスクリプト
├── .gitignore                                    ← 秘密情報除外
├── scripts/
│   ├── .env.local                               ← ローカル環境変数（秘密情報、.gitignore）
│   ├── load-env.ps1                             ← .env.local を PowerShell に読み込む
│   ├── la-oauth-bootstrap.ps1                   ← 初回 OAuth 取得
│   ├── la-jumpbox-create.ps1                    ← 踏み台 VM 作成
│   └── la-vnetroute.ps1                         ← VNet ルート再適用（オプション）
├── workflows/
│   ├── EVL-04d-TeamsNotify/
│   │   ├── workflow.json                        ← Logic App 定義
│   │   ├── deploy.ps1                           ← デプロイスクリプト
│   │   ├── test.ps1                             ← テストスクリプト
│   │   ├── check-run.ps1                        ← 実行結果確認
│   │   ├── check-run-arm.ps1                    ← ARM 経由確認（PE後）
│   │   └── README.md                            ← ワークフロー説明
│   └── EVL-99-TokenHealthCheck/
│       ├── workflow.json
│       ├── deploy.ps1
│       └── README.md
├── infrastructure/
│   ├── bicep/
│   │   ├── main.bicep                           ← メインテンプレート
│   │   ├── modules/
│   │   │   ├── vnet.bicep
│   │   │   ├── logicapp.bicep
│   │   │   ├── keyvault.bicep
│   │   │   ├── storage.bicep
│   │   │   ├── firewall.bicep
│   │   │   ├── privateendpoint.bicep
│   │   │   └── dns.bicep
│   │   ├── parameters.dev.bicepparam
│   │   └── parameters.prod.bicepparam
│   ├── arm-templates/
│   │   └── deploy.json                         ← ARM テンプレート版
│   └── terraform/ (オプション)
│       └── main.tf
├── evaluation/
│   ├── EVL-04-comparison.md                     ← 案 G1-G4' 検討表
│   └── EVL-04-test-results.md                   ← 実装検証ログ
└── CONTRIBUTING.md                              ← 開発ガイドライン
```

## 🚀 クイックスタート

### 前提条件

- Azure CLI (`az`) & PowerShell 7.x
- Microsoft 365 テナント管理者権限
- Service Account (システム通知用ユーザーアカウント)

### ステップ 1: リポジトリのクローン

```bash
git clone https://github.com/YOUR-ORG/logic-app-service-account.git
cd logic-app-service-account
```

### ステップ 2: 環境変数の設定

#### オプション A: 対話スクリプトで設定（推奨）

```powershell
# Azure にログイン
az login

# 対話形式でセットアップ
pwsh ./setup-env.ps1
```

このスクリプトは以下を自動的に行います：
- ✅ Azure コンテキストの検証
- ✅ Phase 0～4 の環境変数を対話的に入力
- ✅ `scripts/.env.local` ファイルを自動生成
- ✅ 環境変数の検証

補足:
- `SERVICE_ACCOUNT_UPN` は未作成なら空でスキップ可能です。
- ただし、Phase 3 (OAuth bootstrap) 実行前には必ず設定してください。

その後、環境変数をロード：
```powershell
. ./scripts/load-env.ps1
```

#### オプション B: 手動で設定

`setup-env.ps1` 実行済みの場合は、生成済みの `scripts/.env.local` を編集して値を設定：

```powershell
# 生成済みファイルを編集
notepad scripts/.env.local
```

`setup-env.ps1` 未実行で `scripts/.env.local` がない場合:

```powershell
Copy-Item .env.example scripts/.env.local
notepad scripts/.env.local
```

> **注**: 通常は [setup-env.ps1](setup-env.ps1) で自動生成し、必要箇所だけ手動編集してください。

**初期セットアップ時の必須環境変数:**
| 変数 | 説明 |
|------|------|
| `AZURE_SUBSCRIPTION_ID` | Azure サブスクリプション ID |
| `AZURE_TENANT_ID` | Azure AD / Entra テナント ID |
| `M365_TENANT_ID` | Microsoft 365 テナント ID |
| `RESOURCE_GROUP_NAME` | リソースグループ名 |
| `LOCATION` | Azure リージョン（`westus2`, `japaneast`, `eastus2`） |
| `LOGIC_APP_NAME` | Logic App 名（例: `la-sendmsg-m365-connector`） |
| `KEY_VAULT_NAME` | Key Vault 名（例: `kv-sendmsg-001`, グローバル一意） |
| `STORAGE_ACCOUNT_NAME` | Storage Account 名（例: `stsendmsg001`, 英小文字/数字のみ） |
| `APP_SERVICE_PLAN_NAME` | App Service Plan 名（例: `asp-sendmsg-workflow`） |
| `VNET_NAME` | VNet 名（例: `vnet-sendmsg`） |
| `FIREWALL_NAME` | Azure Firewall 名（例: `afw-sendmsg`） |
| `FIREWALL_POLICY_NAME` | Firewall Policy 名（例: `afwp-sendmsg`） |
| `LOG_ANALYTICS_NAME` | Log Analytics 名（例: `log-sendmsg`） |
| `APP_INSIGHTS_NAME` | Application Insights 名（例: `appi-sendmsg`） |

**Phase 3 (OAuth bootstrap) 前に必須:**
| 変数 | 説明 |
|------|------|
| `SERVICE_ACCOUNT_UPN` | サービスアカウント UPN（`system-notify@...`） |
| `ENTRA_APP_CLIENT_ID` | Entra App Registration の Client ID |

詳細は [.env.example](.env.example) を参照。

### ステップ 3: リソースグループ作成とインフラストラクチャのデプロイ

```powershell
# リソースグループを作成
az group create -n $env:RESOURCE_GROUP_NAME -l $env:LOCATION

# Bicep を使用したデプロイ
az deployment group create `
  -n logic-app-deployment `
  -g $env:RESOURCE_GROUP_NAME `
  -f infrastructure/bicep/main.bicep `
  -p infrastructure/bicep/parameters.prod.bicepparam `
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

### ステップ 3.5: Jumpbox VM の作成（オプション）

VNet 内に踏み台 VM を作成しておくと、**ステップ 4 の Key Vault 一時開放が不要**になる。  
また、`publicNetworkAccess=Disabled` な Logic App へのテスト実行 (`test.ps1`) にも使える。

```powershell
pwsh ./scripts/la-jumpbox-create.ps1 `
    -ResourceGroupName $env:RESOURCE_GROUP_NAME `
    -VnetName $env:VNET_NAME
```

> **注**: 実行時に、ターミナルで **管理者パスワード入力を求められる**（対話入力）。
> **注**: Jumpbox の既定イメージは **Windows 11 Pro, version 24H2**、ライセンスは **BYOL (`Windows_Client`)**。

#### Jumpbox セットアップ（RDP 接続後）

> **注**: Azure Run Command は SYSTEM アカウントで実行されるため `winget` が使えません。  
> RDP 接続後に VM 内で直接セットアップしてください。

まず RDP で接続：

```powershell
$jumpboxIp = (Get-Content jumpbox-info.json | ConvertFrom-Json).publicIp
mstsc /v:$jumpboxIp
```

ユーザー名: `azureuser`

RDP セッション内で以下を実行（PowerShell）：

```powershell
# Git と PowerShell をインストール
winget install --id Git.Git --exact --silent --accept-source-agreements --accept-package-agreements
winget install --id Microsoft.PowerShell --exact --silent --accept-source-agreements --accept-package-agreements

# 新しいターミナルを開くか、PATH を更新
$env:Path += ";C:\Program Files\Git\cmd"

# リポジトリ clone
git clone https://github.com/ketana0224/logic-app-service-account.git C:\logic-app-service-account

# 確認
ls C:\
```

clone が完了したら、ステップ 4（OAuth Bootstrap）に進んでください。

---  
このテンプレートでは Logic App は初期デプロイ時点から `publicNetworkAccess=Disabled` のため、`test.ps1` 実行は Jumpbox など VNet 内から行う（または ARM endpoint 経由の間接実行を使う）。

### ステップ 4: OAuth Bootstrap（初回のみ）

bootstrap スクリプトが `refresh_token` を Key Vault に書き込む。  
Key Vault は `publicNetworkAccess=Disabled` のため、**実行環境によって手順が異なる**。

#### パターン A: Jumpbox あり（ステップ 3.5 を実施済み）

Jumpbox VM の RDP セッション内から bootstrap を実行します。

```powershell
# RDP セッション内で実行
Set-Location "C:\logic-app-service-account"
pwsh ./scripts/la-oauth-bootstrap.ps1
```

#### パターン B: ローカル PC から実行（Jumpbox なし）

KV を一時開放してからスクリプトを実行し、完了後すぐに閉鎖する。

```powershell
# Key Vault を一時開放
az keyvault update -n $env:KEY_VAULT_NAME -g $env:RESOURCE_GROUP_NAME `
    --public-network-access Enabled --default-action Allow

# Bootstrap スクリプト実行（ブラウザでサインイン）
pwsh ./scripts/la-oauth-bootstrap.ps1

# Key Vault を即時閉鎖
az keyvault update -n $env:KEY_VAULT_NAME -g $env:RESOURCE_GROUP_NAME `
    --public-network-access Disabled --default-action Deny
```

### ステップ 5: ワークフローのデプロイ

```powershell
# EVL-04d-TeamsNotify（Teams 通知送信）
cd workflows/EVL-04d-TeamsNotify
pwsh ./deploy.ps1

# EVL-99-TokenHealthCheck（6時間ごとの refresh_token rotation）
cd ../EVL-99-TokenHealthCheck
pwsh ./deploy.ps1
```

### ステップ 6: テスト実行

```powershell
cd workflows/EVL-04d-TeamsNotify

# 特定ユーザーへのテスト送信
pwsh ./test.ps1 -Target "Adil"
pwsh ./test.ps1 -Target "Amber"

# 実行結果確認
pwsh ./check-run.ps1 <runId>

# このテンプレートでは Logic App は PublicNetworkAccess=Disabled
pwsh ./check-run-arm.ps1 <runId>
```

## ⚙️ 環境変数セットアップ

### 環境変数ファイル

このプロジェクトは以下のファイルで環境変数を管理します：

| ファイル | 用途 | 保護 |
|---------|------|------|
| [.env.example](.env.example) | テンプレート / リファレンス | ✅ リポジトリに含まれる |
| [setup-env.ps1](setup-env.ps1) | セットアップスクリプト | ✅ リポジトリに含まれる |
| `scripts/.env.local` | ローカル環境変数（秘密情報） | ❌ .gitignore で保護 |

### Phase 別の必須環境変数

**Phase 0: Azure & Microsoft 365 認証 (初期デプロイに必須)**
```
AZURE_SUBSCRIPTION_ID     # az account list で取得
AZURE_TENANT_ID           # az account show --query tenantId
M365_TENANT_ID            # M365 管理センター > 組織プロファイル > 組織 ID
```

**Phase 1: インフラストラクチャ**
```
RESOURCE_GROUP_NAME       # リソースグループ名
LOCATION                  # リージョン: westus2 / japaneast / eastus2
LOGIC_APP_NAME            # 例: la-sendmsg-m365-connector
KEY_VAULT_NAME            # 例: kv-sendmsg-001 (グローバル一意)
STORAGE_ACCOUNT_NAME      # 例: stsendmsg001 (英小文字/数字のみ)
APP_SERVICE_PLAN_NAME     # 例: asp-sendmsg-workflow
VNET_NAME                 # 例: vnet-sendmsg
FIREWALL_NAME             # 例: afw-sendmsg
FIREWALL_POLICY_NAME      # 例: afwp-sendmsg
LOG_ANALYTICS_NAME        # 例: log-sendmsg
APP_INSIGHTS_NAME         # 例: appi-sendmsg
```

**Phase 1: ネットワーク（オプション、デフォルト値あり）**
```
VNET_NAME                 # VNet 名
VNET_ADDRESS_PREFIX       # VNet アドレス範囲（デフォルト: 10.0.0.0/16）
SUBNET_LOGICAPP_PREFIX    # Logic App サブネット（デフォルト: 10.0.1.0/27）
SUBNET_PEP_PREFIX         # Private Endpoint サブネット（デフォルト: 10.0.2.0/27）
SUBNET_FIREWALL_PREFIX    # Firewall サブネット（デフォルト: 10.0.3.0/26）
SUBNET_JUMPBOX_PREFIX     # Jumpbox サブネット（デフォルト: 10.0.4.0/27）
```

**Phase 2: Entra App Registration**
```
ENTRA_APP_CLIENT_ID       # Phase 2 完了後に入力
```

**Phase 3: OAuth bootstrap 前に必須**
```
SERVICE_ACCOUNT_UPN       # 形式: system-notify@<tenant>.onmicrosoft.com
ENTRA_APP_CLIENT_ID       # Entra App Registration の Client ID
```

**タグ（オプション）**
```
TAG_ENVIRONMENT           # dev / test / prod
TAG_OWNER                 # オーナーメール
TAG_COST_CENTER           # コスト分析用
```

詳細は [.env.example](.env.example) を参照。

## 🔐 セキュリティ機能

### ネットワーク

- **Inbound**: Private Endpoint のみ (Inbound Public = 0)
- **Outbound**: Azure Firewall で FQDN/宛先制御
  - `login.microsoftonline.com` (OAuth)
  - `graph.microsoft.com` (Microsoft Graph)
  - `vault.azure.net` (Key Vault)
- **DNS**: Private DNS Zone で名前解決を VNet 内に閉鎖

### 認証

- **Auth Code Flow + PKCE**: パスワード不要、セキュアな OAuth
- **refresh_token rotation**: 各実行時に新しい token を取得・保管 (90 日 sliding)
- **Key Vault**: refresh_token/tenant ID/client ID を暗号化保管
- **Managed Identity**: Logic App が MSI で Key Vault にアクセス

### 運用

- **Health Check**: EVL-99 で 6 時間ごと自動監視
- **暗号化**: 転送中は TLS 1.2、保管時は Key Vault
- **監査**: Logic App 実行履歴 + Microsoft Entra Sign-in logs

## 💰 コスト概算 (月額 USD)

> 以下は westus2、Pay-as-you-go list price (2026-06 基準)

| コンポーネント | 月額目安 |
|---|---:|
| Logic App Standard (WS1) | $179 |
| Private Endpoints (6 個) | $44 |
| Key Vault | <$1 |
| Storage Account | $2 |
| Private DNS Zone (6) | $3 |
| **ランタイム必須の合計** | **~$230/月** |
| （踏み台 VM 除く） | |

**Azure Firewall** 既設の場合は追加なし。新規構築の場合は **+$900～1,200/月** (SKU 次第)。

## 🧪 テスト・検証

このプロジェクトは以下を実装検証済み：

| 項目 | 状態 | 日付 |
|---|---|---|
| ネットワーク基盤 (VNet/AFW/PE) | ✅ | 2026-06-11 |
| OAuth Bootstrap | ✅ | 2026-06-12 03:42 UTC |
| EVL-04d ワークフロー | ✅ | 2026-06-12 |
| Public Disabled 後の PE テスト | ✅ | 2026-06-12 03:46 UTC |
| Token Health Check (6h rotation) | ✅ | 2026-06-12 |

詳細は [evaluation/EVL-04-test-results.md](evaluation/EVL-04-test-results.md) を参照。

## 📋 運用ガイドラインス

### refresh_token の永続性

以下の条件下で「Bootstrap 1 回で半永久運用」が成立：

1. ✅ Service Account に **恒久パスワード** を設定 (TAP 禁止)
2. ✅ Conditional Access で SA を **除外グループに追加**
3. ✅ EVL-99 で **6 時間ごと自動 rotation**
4. ✅ ライセンス・アカウント種別を維持

### Service Account の要件

| 属性 | 値 |
|---|---|
| アカウント種別 | **専用ユーザーアカウント** (Shared Mailbox ❌) |
| パスワード | **恒久パスワード** (TAP ❌) |
| ライセンス | **Microsoft 365 (Teams 含む)** |
| Delegated 権限 | `User.Read` / `Chat.ReadWrite` / `ChatMessage.Send` / `offline_access` |

## 🔄 関連プロジェクト

- [Bot Service 方式](../logicappp_BotService方式.md) — 比較対案 (非推奨)
- [2 ソリューション比較説明書](../logicappp_2solutions説明資料.md) — 対案との選択判断資料

## 📝 貢献ガイドライン

バグ報告・機能追加は Issue / Pull Request でお願いします。

詳細は [CONTRIBUTING.md](CONTRIBUTING.md) を参照。

 RBAC: Logic App SAMI → Key Vault Secrets Officer + Storage ロール

[MIT License](LICENSE) - このテンプレートをベースに派生実装を許可します。

---

**最終更新**: 2026-06-17  
**著者**: Logic App Service Account 実装チーム  
**ステータス**: ✅ 本番検証完了 (EVL-04d / EVL-99)
