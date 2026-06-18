# EVL-04d-TeamsNotify Workflow

Manual HTTP trigger で Teams 1:1 チャットに通知を送信するワークフロー。

## 概要

```
POST callback-url?code=XXX
  ↓
Logic App EVL-04d-TeamsNotify
  │
  ├→ [1] Get_Refresh_Token (HTTP GET + MSI)
  │       ↓ Key Vault から refresh_token 取得
  │
  ├→ [2] Token_Refresh (HTTP POST)
  │       ↓ login.microsoftonline.com でリフレッシュ
  │       → 新 access_token + 新 refresh_token
  │
  ├→ [3] Update_Refresh_Token (HTTP PUT + MSI)
  │       ↓ 新 token を KV に上書き (rotation)
  │
  ├→ [4] Create_Chat (POST /chats)
  │       ↓ SA と recipient の 1:1 chat 作成
  │
  ├→ [5] Send_Message (POST /chats/{id}/messages)
  │       ↓ メッセージ送信 (Bearer token)
  │
  ├→ [6] Build_Result (Compose)
  │       ↓ 送信結果を JSON で構成
  │
  └→ [7] Response (Asynchronous)
          ↓ 202 Accepted を非同期で返す
```

## ファイル

| ファイル | 説明 |
|---|---|
| `workflow.json` | Logic App 定義 (ARM template) |
| `deploy.ps1` | ワークフローをデプロイするスクリプト |
| `test.ps1` | テストメッセージを送信 |
| `check-run.ps1` | 実行結果を確認 (public 開放中) |
| `check-run-arm.ps1` | 実行結果を確認 (ARM proxy 経由、PE 後) |

## 操作

### デプロイ

```powershell
pwsh ./deploy.ps1
```

実行内容:
1. Logic App host runtime endpoint に workflow.json を PUT
2. Logic App を restart (∼30秒待機)
3. callback URL を取得・保存
4. Application Settings を更新

出力: `callback-url.txt` (callback URL 含む)

### テスト実行

```powershell
# 特定ユーザーにメッセージ送信
pwsh ./test.ps1 -Target "Adil"
pwsh ./test.ps1 -Target "Amber"
pwsh ./test.ps1 -Target "Both"
```

実行内容:
1. callback URL を callback-url.txt から読み込み
2. POST リクエスト送信 (recipient指定)
3. Logic App run ID を取得
4. Run completion を polling（最大 30 秒）
5. 送信成否をレポート

成功例:
```
Target: Adil
Message sent to: AdilE@M365CPI65139919.onmicrosoft.com
Sent: 2026-06-12T03:46:20.1234567Z
run-id: 08584203709072358571743386284CU00

Status: Succeeded ✓
All actions succeeded
  - Get_Refresh_Token: Succeeded
  - Token_Refresh: Succeeded
  - Update_Refresh_Token: Succeeded
  - Create_Chat: Succeeded (19:abcd...@unq.gbl.spaces)
  - Send_Message: Succeeded (msg-id-xxx)
  - Build_Result: Succeeded
```

### 実行結果確認

#### Public access 開放中

```powershell
pwsh ./check-run.ps1 -RunId "08584203709072358571743386284CU00"
```

直接 Logic App host runtime endpoint にアクセス。

#### Logic App PE 化後

```powershell
pwsh ./check-run-arm.ps1 -RunId "08584203709072358571743386284CU00"
```

ARM proxy (`/hostruntime/admin/vfs/...`) 経由で間接アクセス。

## Trigger: Manual HTTP

```json
{
  "type": "Request",
  "kind": "Http",
  "inputs": {
    "schema": {
      "type": "object",
      "properties": {
        "recipient": {
          "type": "string",
          "description": "M365 user UPN (e.g., AdilE@...)"
        },
        "subject": {
          "type": "string",
          "default": "Teams Notification"
        },
        "message": {
          "type": "string",
          "description": "Message body (plain text or HTML)"
        }
      }
    }
  }
}
```

### リクエスト例

```json
{
  "recipient": "AdilE@M365CPI65139919.onmicrosoft.com",
  "subject": "Alert from Logic App",
  "message": "<p>This is a test notification.</p>"
}
```

## Actions

### [1] Get_Refresh_Token

```
HTTP GET
URI: @{concat(variables('kvUri'), '/secrets/m365-system-notify-refresh-token?api-version=7.0')}
Authentication: Managed Identity (System)
```

→ KV から最新 refresh_token を取得。

### [2] Token_Refresh

```
HTTP POST
URI: @{concat('https://login.microsoftonline.com/', variables('tenantId'), '/oauth2/v2.0/token')}
Body: (form-urlencoded)
  - grant_type: refresh_token
  - client_id: (from app settings)
  - refresh_token: (from step 1)
  - scope: User.Read Chat.ReadWrite ChatMessage.Send offline_access
```

→ 新 access_token + 新 refresh_token を取得。

### [3] Update_Refresh_Token

```
HTTP PUT
URI: @{concat(variables('kvUri'), '/secrets/m365-system-notify-refresh-token?api-version=7.0')}
Body: (JSON)
  {
    "value": "new-refresh-token-from-step2"
  }
Authentication: Managed Identity (System)
```

→ rotation: 古 token を新 token で置換。

### [4] Create_Chat

```
HTTP POST
URI: https://graph.microsoft.com/v1.0/chats
Body: (JSON, string concatenation 方式)
@{concat(
  '{',
  '"chatType":"oneOnOne",',
  '"members":[',
    '{"@odata.type":"#microsoft.graph.aadUserConversationMember","roles":["owner"],"user@odata.bind":"https://graph.microsoft.com/v1.0/users/',
    body('variables_systemNotifyOid'),
    '"}',
    ',{"@odata.type":"#microsoft.graph.aadUserConversationMember","roles":["owner"],"user@odata.bind":"https://graph.microsoft.com/v1.0/users/',
    outputs('Lookup_Recipient_OID'),
    '"}',
  ']',
  '}'
)}
```

→ System-notify SA と recipient の 1:1 chat を作成。

### [5] Send_Message

```
HTTP POST
URI: https://graph.microsoft.com/v1.0/chats/@{outputs('Create_Chat_ID')}/messages
Body: (JSON)
{
  "body": {
    "contentType": "html",
    "content": "<p><strong>@{triggerBody()['subject']}</strong></p><p>@{triggerBody()['message']}</p>"
  }
}
Headers:
  - Authorization: Bearer @{outputs('Token_Response')['access_token']}
  - Content-Type: application/json
```

→ メッセージを 1:1 chat に送信。

### [6] Build_Result

```
Compose (複数の式を集約)
{
  "evaluation": "EVL-04d",
  "status": "completed",
  "timestamp": "@{utcNow()}",
  "recipient": "@{triggerBody()['recipient']}",
  "chatId": "@{outputs('Create_Chat_ID')}",
  "messageId": "@{outputs('Send_Message')['id']}",
  "tokenRotationTime": "@{outputs('Update_Refresh_Token_Time')}",
  "allActionsSucceeded": true
}
```

### [7] Response

```
HTTP Response
statusCode: 202
body: (from Build_Result)
operationOptions: "Asynchronous"
```

→ 202 Accepted を非同期で返す (trigger concurrency=1 のため)。

## 既知の制限

### action K2: Create_Chat の JSON 構築

Logic Apps の built-in JSON object 表現では `@odata.type` / `user@odata.bind` の escape が正しく機能しないため、**string concatenation 方式** で body を構築。

❌ 不可:
```json
{
  "@odata.type": "#microsoft.graph.aadUserConversationMember",
  "user@odata.bind": "..."
}
```

✅ 可:
```
@{concat('{...@odata.type...user@odata.bind...}')}
```

### K1: Concurrency

trigger の `runtimeConfiguration.concurrency = 1` と同期 Response を併用不可。対策: `operationOptions: "Asynchronous"`

## トラブルシューティング

### Token_Refresh が 403 (Forbidden)

**原因**: Service Account が TAP でサインインしていた → TAP 期限切れで refresh_token 失効 (AADSTS130504)

**対策**: Service Account に**恒久パスワード** を設定して再 bootstrap

```powershell
# KV 開放
az keyvault update -n kv-sendmsg-001 -g rg-sendmsg-app `
    --public-network-access Enabled --default-action Allow

# 再 bootstrap
pwsh ../../scripts/la-oauth-bootstrap.ps1

# KV 閉鎖
az keyvault update -n kv-sendmsg-001 -g rg-sendmsg-app `
    --public-network-access Disabled --default-action Deny
```

### Create_Chat が BadRequest

**原因**: JSON 内の `@odata.type` / `user@odata.bind` が graph に正しく届かない

**対策**: workflow.json の Create_Chat action が string concat 方式になっていることを確認。JSON object 表現に戻していないか check。

### Logic App が host unavailable (30秒後に自動復旧)

**原因**: restart 後 warmup に 60 秒前後必要

**対策**: deploy.ps1 で 60 秒待機を実装。手動 restart した場合も 60 秒待つ。

### Test 実行が 403 (Logic App public disabled後)

**原因**: Logic App の callback URL が public endpoint なので `publicNetworkAccess=Disabled` では呼べない

**対策**: 踏み台 VM (jumpbox subnet) から test.ps1 を実行するか、ARM endpoint 経由の間接実行に切り替え。

---

**参照**: [docs/01-Design.md](../../docs/01-Design.md)
