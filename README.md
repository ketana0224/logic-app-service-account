# Logic App + Service Account 方式 (Built-in HTTP)

**別テナントの Azure から、Microsoft 365 (Teams) テナントへ 1:1 チャットを作成・通知する**ためのアーキテクチャ実装プロジェクト。

Azure リソースをホストするテナントと、Teams チャットを送る相手が所属する Microsoft 365 テナントが**異なる**構成を主旨としています。Service Account の delegated 権限 + refresh_token rotation により、M365 テナント側に Azure リソースを一切置かずにクロステナントで Teams チャットを自動作成します。

## 🎯 プロジェクト目標

- ✅ **クロステナント** (Azure ホストテナント ≠ M365/Teams テナント) で Teams 1:1 チャットを作成
- ✅ **Inbound Public ポート = 0** (Private Endpoint 経由のみ)
- ✅ **ROPC ゼロ** (パスワード保管なし)
- ✅ **Protected API 不要** (delegated 権限で実装)
- ✅ **Microsoft 365 テナント側に Azure リソース不要**
- ✅ **refresh_token rotation** で 90 日無期限運用

## 📁 プロジェクト構成

```
logic-app-service-account/
├── README.md                                     ← このファイル
├── .gitignore                                    ← 秘密情報除外
├── docs/
│   ├── 01-Design.md                            ← 設計書（メイン）
│   ├── 02-Architecture.md                       ← アーキテクチャ図解
│   ├── 03-OAuth-Flow.md                         ← OAuth 詳細
│   ├── 04-Troubleshooting.md                    ← トラブルシューティング
│   └── 05-Cost-Analysis.md                      ← コスト分析
├── scripts/
│   ├── la-oauth-bootstrap.ps1                   ← 初回 OAuth 取得
│   ├── la-jumpbox-create.ps1                    ← 踏み台 VM 作成
│   ├── la-evl04c-teardown.ps1                   ← 旧リソース削除
│   └── utils/                                   ← ヘルパー関数
│       ├── Deploy-Helper.ps1
│       └── Config-Helper.ps1
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

```powershell
$env:AZURE_SUBSCRIPTION_ID = "YOUR-SUBSCRIPTION-ID"
$env:AZURE_TENANT_ID = "YOUR-AZURE-TENANT-ID"
$env:M365_TENANT_ID = "YOUR-M365-TENANT-ID"
$env:SERVICE_ACCOUNT_UPN = "system-notify@yourtenant.onmicrosoft.com"
$env:ENTRA_APP_CLIENT_ID = "YOUR-APP-REGISTRATION-CLIENT-ID"
```

### ステップ 3: インフラストラクチャのデプロイ

```powershell
# Bicep を使用したデプロイ
az deployment group create `
  -n logic-app-deployment `
  -g rg-your-resource-group `
  -f infrastructure/bicep/main.bicep `
  -p infrastructure/bicep/parameters.prod.bicepparam
```

### ステップ 4: OAuth Bootstrap（初回のみ）

```powershell
# Key Vault を一時的に開放
az keyvault update -n kv-yourname-xxxx -g rg-your-resource-group `
    --public-network-access Enabled --default-action Allow

# Bootstrap スクリプト実行（ブラウザでサインイン）
pwsh ./scripts/la-oauth-bootstrap.ps1

# Key Vault を完全閉鎖
az keyvault update -n kv-yourname-xxxx -g rg-your-resource-group `
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

# Logic App が PublicNetworkAccess=Disabled の場合
pwsh ./check-run-arm.ps1 <runId>
```

## 📖 ドキュメント

| ドキュメント | 内容 |
|---|---|
| [01-Design.md](docs/01-Design.md) | 設計判断・全体構成・各リソースの役割 |
| [02-Architecture.md](docs/02-Architecture.md) | ネットワーク・セキュリティアーキテクチャ図解 |
| [03-OAuth-Flow.md](docs/03-OAuth-Flow.md) | OAuth 詳細・refresh_token rotation の仕組み |
| [04-Troubleshooting.md](docs/04-Troubleshooting.md) | 問題発生時のトラブルシューティング |
| [05-Cost-Analysis.md](docs/05-Cost-Analysis.md) | コスト見積もり・最適化 |

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

詳細は [05-Cost-Analysis.md](docs/05-Cost-Analysis.md) を参照。

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

失効トリガーの詳細は [docs/03-OAuth-Flow.md](docs/03-OAuth-Flow.md) を参照。

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

## 📄 ライセンス

[MIT License](LICENSE) - このテンプレートをベースに派生実装を許可します。

---

**最終更新**: 2026-06-17  
**著者**: Logic App Service Account 実装チーム  
**ステータス**: ✅ 本番検証完了 (EVL-04d / EVL-99)
