# 設計書 - Logic App + Service Account 方式

このドキュメントは [logicappp_ServiceAccount方式.md](../../logicappp_ServiceAccount方式.md) からコピーしています。  
詳細な検証ログ・技術判断については元ファイルを参照してください。

## 0. 絶対条件

| # | 条件 | 実装方法 |
|---|---|---|
| 1 | Azure リソースは専用テナントのみ | Subscription を分離、リソースグループに集約 |
| 2 | Microsoft 365 側に Azure リソース 0 件 | Entra App Registration + Service Account user のみ |
| 3 | Inbound Public = 0 | Private Endpoint のみ許可、`publicNetworkAccess=Disabled` |
| 4 | Outbound 制御 | Azure Firewall で FQDN/宛先ルール限定 |
| 5 | Protected API 不要 | Delegated 権限で実装 |
| 6 | パスワード保管なし | OAuth Auth Code Flow + refresh_token rotation |

## 1. 全体アーキテクチャ

```
[呼び出し元]
    ↓ HTTPS + SAS
[Logic App Standard - pe-only]
    ├─→ [Key Vault PE] - refresh_token 保管
    ├─→ [Storage PE] - host state / File Share
    └─→ [Azure Firewall] ← 以下へ外向き
         ├─→ login.microsoftonline.com (OAuth)
         ├─→ graph.microsoft.com (Teams Chat API)
         └─→ *.vaultcore.azure.net (KV API)
```

## 2. リソース一覧

### 必須リソース (本当に使う分)

| リソース | 用途 | 配置 |
|---|---|---|
| **Logic App Standard** `la-dir-m365-connector` | Teams 通知本体 | snet-logicapp 10.0.1.0/27 |
| **Private Endpoint (Logic App)** `pe-la-dir` | Inbound PE のみ | snet-pep 10.0.2.9 |
| **Key Vault** `kv-dirm365-xxxx` | refresh_token 暗号化保管 | PE のみ |
| **Private Endpoint (KV)** `pe-kv-dir` | KV への PE | snet-pep 10.0.2.8 |
| **Storage Account** `stdirlam365conn` | Logic App host state | PE のみ |
| **Private Endpoints (Storage)** `pe-st-{file,blob,queue,table}` | Storage PE (file は必須) | snet-pep 10.0.2.4–7 |
| **VNet** `vnet-dir` | 10.0.0.0/16 | — |
| **Azure Firewall** `afw-dir` | Outbound 制御 | AzureFirewallSubnet 10.0.3.0/26 |
| **Route Table** `rt-snet-logicapp` | UDR: 0.0.0.0/0 → AFW | snet-logicapp 関連付け |
| **Private DNS Zone** (3 種類) | PE 名前解決 | global + vnet link |

### 旧 EVL-04c からの削除対象

以下は **Service Account 方式では不要**（旧 Bot Framework 構成の残骸）:

- `evl04c-bot` (Microsoft.BotService)
- `evl04c-func-sq4jpp` (Function App)
- `evl04cstsq4jpp` (旧 Storage)
- `evl04c-ai` (Application Insights)

Phase 8 (`la-evl04c-teardown.ps1`) で削除。

## 3. OAuth フロー

### Bootstrap (1 回だけ)

1. ローカル PC で `http://localhost:8400/callback` HTTP listener 起動
2. ブラウザ: `https://login.microsoftonline.com/{tenant}/oauth2/v2.0/authorize?...` (PKCE 付き)
3. Service Account でサインイン（**恒久パスワード必須、TAP 禁止**）
4. Authorization Code 取得
5. Token endpoint で Auth Code + code_verifier → access_token + **refresh_token** 取得
6. refresh_token を Key Vault `m365-system-notify-refresh-token` に保存

### ランタイム (每 run)

```
GET refresh_token from KV
    ↓
POST refresh_token → login.microsoftonline.com (新 access_token + 新 refresh_token 取得)
    ↓
UPDATE KV with 新 refresh_token (rotation)
    ↓
POST /chats/{chatId}/messages (Bearer: access_token)
    ↓
Response (202 Accepted)
```

### 長期維持 (EVL-99 6h health check)

- Trigger: Recurrence frequency=Hour, interval=6
- Actions: Get RT → Refresh → Update RT → (send なし、健全性確認のみ)
- Entra 既定の refresh_token max-age **90 日 sliding** を永久にリセット

## 4. ネットワーク経路

### Inbound

| 発信元 | 宛先 | 状態 | 理由 |
|---|---|---|---|
| Public Internet | Logic App | **403 Forbidden** | `publicNetworkAccess=Disabled` |
| 踏み台 VM (10.0.4.x) | PE (10.0.2.9) | ✅ 202 | PE のみ許可 |
| **Inbound Public ポート数** | | **0** | ✓ |

### Outbound

#### VNet 内で閉じてある（Private DNS → PE）

| 接続先 | Private DNS Zone |
|---|---|
| `kv-dirm365-xxxx.vault.azure.net` | `privatelink.vaultcore.azure.net` |
| `stdirlam365conn.blob.core.windows.net` 他 | `privatelink.{blob,file,queue,table}.core.windows.net` |
| Logic App callback | `privatelink.azurewebsites.net` |

#### Azure Firewall で明示的に許可が必須

| # | FQDN / Service Tag | 種別 | 用途 |
|---|---|---|---|
| 1 | `login.microsoftonline.com` | Application Rule | Token endpoint |
| 2 | `graph.microsoft.com` | Application Rule | Microsoft Graph API |
| 3 | `AzureActiveDirectory` | Network Rule | OAuth 通信保険 |

## 5. Key Vault のシークレット

| Secret | 値の例 | 取得方法 |
|---|---|---|
| `m365-system-notify-refresh-token` | `0.AUoA...` (refresh_token) | Bootstrap 1 回で設定 |
| `m365-system-notify-tenant-id` | `655bd66a-5001-4cb3-...` | 手動設定 |
| `m365-system-notify-client-id` | `d53202ed-f6ba-4ba3-...` | 手動設定 |
| `m365-system-notify-chat-id` | `19:...thread.v2` | Bootstrap で発見 |

## 6. Logic App Application Settings

| キー | 値 |
|---|---|
| `KV_NAME` | `kv-dirm365-3647` |
| `KV_VAULT_URI` | `https://kv-dirm365-3647.vault.azure.net/` |
| `ENTRA_TENANT_ID` | M365 tenant ID |
| `ENTRA_CLIENT_ID` | App Registration client ID |
| `SYSTEM_NOTIFY_OID` | Service Account OID |
| `REFRESH_TOKEN_SECRET_NAME` | `m365-system-notify-refresh-token` |

## 7. 権限 (RBAC)

| Identity | リソース | ロール | 理由 |
|---|---|---|---|
| Logic App SAMI | Key Vault | **Key Vault Secrets Officer** | GET / SET secret |
| Bootstrap 実行者 | KV | (一時 IP 許可) | 初回投入 |

## 8. Microsoft 365 テナント側

| 種類 | 値 |
|---|---|
| App Registration | `d53202ed-...` (公開クライアント、PKCE) |
| Delegated 権限 | `User.Read` / `Chat.ReadWrite` / `ChatMessage.Send` / `offline_access` |
| Service Account | `system-notify@M365CPI65139919.onmicrosoft.com` |
| ライセンス | **Microsoft 365 E3/E5 (Teams 含む)** |
| パスワード | **恒久パスワード** (TAP ❌) |

### Service Account の種別 (重要!)

本案件の `system-notify` は **Shared Mailbox ではなく、専用ユーザーアカウント (Dedicated User Account)**：

| 観点 | Shared Mailbox | **専用ユーザー（本案件）** |
|---|---|---|
| Teams 利用 | ❌ 不可 | ✅ 可 |
| OAuth サインイン | ❌ ブロック | ✅ 可 |
| ライセンス | 不要 | **必須** (Teams) |
| パスワード | 無し | 有り (恒久) |

**Shared Mailbox が使えない理由**:
- サインイン拒否 → refresh_token が発行されない
- Teams API (Chat.ReadWrite) 実行不可
- TAP も TAP として動作しない

## 9. コスト概算

| コンポーネント | 月額 (USD) | 根拠 |
|---|---:|---|
| Logic App Standard WS1 | $179 | plan 固定 |
| Private Endpoints (6) | $44 | @$7.3/個 |
| Key Vault | <$1 | secret 低 operation |
| Storage Account | $2 | 数 GB 以下 |
| Private DNS Zone (6) | $3 | @$0.50 zone |
| **ランタイム合計** | **~$230/月** | |
| （踏み台 VM 別計算） | | |

**Azure Firewall 追加** (新構築の場合):
- **Standard** SKU: +$912/月 (本番推奨)
- **Basic** SKU: +$295/月 (テスト向け)

詳細は [05-Cost-Analysis.md](05-Cost-Analysis.md) を参照。

## 10. 運用上の注意

### refresh_token の永続性条件

「Bootstrap 1 回で半永久」が成立する前提：

1. ✅ Service Account: **恒久パスワード** (TAP 禁止)
2. ✅ Conditional Access: SA を **除外グループに追加**
3. ✅ EVL-99: **6 時間ごと自動 rotation** (90 日 max-age をリセット)
4. ✅ ライセンス・アカウント維持

失効トリガーと対策:
- **CA Sign-in Frequency**: SA 除外
- **CA Risk-based**: SA 除外  
- **パスワード変更**: 同時に再 Bootstrap
- **アカウント削除**: 再 Bootstrap 不可

### タブー (絶対禁止)

| 禁止事項 | 理由 | 結果 |
|---|---|---|
| TAP でサインイン | TAP 期限 = refresh_token 有効期限 | AADSTS130504 |
| Shared Mailbox に変換 | サインイン自体ブロック | 全 workflow 失敗 |
| ライセンス剥奪 | Teams API 実行不可 | 401/403 |
| Admin revoke (`Revoke-MgUserSignInSession`) | session 全 revoke | 全失敗 |

---

**参照**: [logicappp_ServiceAccount方式.md](../../logicappp_ServiceAccount方式.md) (マスター設計書)
