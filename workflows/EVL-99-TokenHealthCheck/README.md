# EVL-99-TokenHealthCheck Workflow

6 時間ごとに refresh_token を自動 rotation し、90 日 sliding window を永遠にリセットするワークフロー。

## 概要

```
Recurrence (6h interval)
  ↓
[1] Get_Refresh_Token
  ↓
[2] Token_Refresh
  ↓
[3] Update_Refresh_Token
  ↓
[4] Build_Health_Result
  ↓
(send なし、健全性確認のみ)
```

## 目的

- ✅ refresh_token を 6 時間ごとに rotation
- ✅ Entra 既定の 90 日 max-age (sliding) を永遠にリセット
- ✅ token 失効を早期検知 (Failed run で通知)
- ✅ Service Account の MFA / CA 環境での健全性確保

## ファイル

| ファイル | 説明 |
|---|---|
| `workflow.json` | Logic App 定義 (ARM template) |
| `deploy.ps1` | ワークフローをデプロイするスクリプト |
| `README.md` | このファイル |

## Trigger: Recurrence

```json
{
  "type": "Recurrence",
  "recurrence": {
    "frequency": "Hour",
    "interval": 6
  }
}
```

毎 6 時間に自動実行。タイムゾーン: UTC (Application Settings の `WEBSITE_TIME_ZONE` で変更可)

## Actions

EVL-04d と同じ 3 アクション:

### [1] Get_Refresh_Token

Key Vault から最新 refresh_token を取得。

### [2] Token_Refresh

`login.microsoftonline.com` で token をリフレッシュ。

### [3] Update_Refresh_Token

新 token を KV に上書き (rotation)。

### [4] Build_Health_Result

実行結果を Compose で構成 (logging 目的)。

```json
{
  "evaluation": "EVL-99",
  "type": "TokenHealthCheck",
  "status": "completed",
  "timestamp": "@{utcNow()}",
  "tokenRefreshed": true,
  "nextRotation": "@{addHours(utcNow(), 6)}",
  "entraMaxAgeResetTime": "@{utcNow()}"
}
```

## 動作フロー

```
毎 6 時間
  │
  ├→ Get RT from KV
  │   (90 日カウントが start / reset されている)
  │
  ├→ Exchange: old RT → new RT
  │   (token endpoint で新 RT が issuing される)
  │
  ├→ Update KV: old RT ← new RT
  │   (Entra では新 RT の 90 日カウントが開始)
  │
  └→ success: 次の rotation まで 6 時間待機
    (または CA / MFA failure で Failed になる)
```

## 失効シナリオと検出

### シナリオ A: Token_Refresh が AADSTS130504

**原因**: Service Account が TAP でサインインしていた

**検出**: EVL-99 run Status = Failed

**対策**: Service Account に恒久パスワード再設定 + 再 bootstrap

### シナリオ B: Token_Refresh が 401/403 (Conditional Access block)

**原因**: CA の Sign-in Frequency が firing、または Risk-based policy が block

**検出**: EVL-99 run Status = Failed

**対策**: SA を CA 除外グループに追加（M365 admin による手動）

### シナリオ C: Logic App が 90 日停止

**原因**: Logic App 停止中は EVL-99 実行なし → 90 日経過 → token 失効

**検出**: 停止解除後の次 EVL-99 run で Failed

**対策**: 停止前に EVL-99 を 1 回手動 trigger、または再 bootstrap

## 監視方法

### Azure Portal

1. Logic App > Runs
2. EVL-99 の run history を眺める
3. **Succeeded** = token healthy
4. **Failed** = 即座に調査・対応

### PowerShell (定期確認)

```powershell
# 最後の EVL-99 run を確認
az logicapp workflow show \
    -g rg-your-group \
    -n la-dir-m365-connector \
    -o json | jq '.properties.definition.triggers.Recurrence'

# Run history (最新 10 件)
az logicapp workflow list-runs \
    -g rg-your-group \
    -n la-dir-m365-connector \
    -r EVL-99-TokenHealthCheck \
    --top 10 -o table
```

### Application Insights (リアルタイム)

Logic App に Application Insights を連携している場合:

```kql
traces
| where message contains "EVL-99"
| summarize by timestamp, customDimensions.runId, customDimensions.status
| order by timestamp desc
```

## 手動実行（テスト）

```powershell
# Logic App の Recurrence trigger を手動実行
az logicapp workflow run-trigger \
    -g rg-your-group \
    -n la-dir-m365-connector \
    -r EVL-99-TokenHealthCheck
```

## コスト影響

- Recurrence 6h × 24h = 4 run/日
- 月間: 約 120 run
- Logic App Standard: 従量課金 ($0.025/action 程度)
- 月額追加: < $1

## 関連ドキュメント

- [EVL-04d-TeamsNotify](../EVL-04d-TeamsNotify/README.md) — 通知送信ワークフロー
- [docs/03-OAuth-Flow.md](../../docs/03-OAuth-Flow.md) — OAuth refresh_token rotation の仕組み
- [docs/04-Troubleshooting.md](../../docs/04-Troubleshooting.md) — トラブルシューティング

---

**最終更新**: 2026-06-12  
**ステータス**: ✅ 本番稼働中
