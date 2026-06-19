# 貢献ガイドライン

このプロジェクトへのバグ報告・機能提案・コード改善をお待ちしています。

## Issue の報告

### バグ報告

```
Title: [BUG] 簡潔な説明

## 再現手順
1. ...
2. ...

## 期待動作
...

## 実際の動作
...

## 環境
- Azure subscription: (e.g., Enterprise Dev)
- Azure region: (e.g., westus2)
- Logic App SKU: (e.g., Standard WS1)
- PowerShell: (pwsh --version)
- Azure CLI: (az --version)
- OS: (Windows / Linux / macOS)
```

### 機能提案

```
Title: [FEATURE] 簡潔な説明

## 背景
...

## 提案
...

## メリット
- ...
- ...
```

## Pull Request の手順

### 1. Fork → Clone

```bash
git clone https://github.com/YOUR-USERNAME/logic-app-service-account.git
cd logic-app-service-account
```

### 2. Feature branch を作成

```bash
git checkout -b feature/your-feature-name
```

### 3. 変更を加える

- コード変更
- ドキュメント更新
- テストコード追加

### 4. Commit

```bash
git add .
git commit -m "feat: brief description

Longer description if needed.
- bullet point 1
- bullet point 2

Fixes #123
"
```

Commit message format:
- `feat:` 新機能
- `fix:` バグ修正
- `docs:` ドキュメント
- `test:` テスト追加
- `refactor:` リファクタリング
- `chore:` ビルド・依存関係など

### 5. Push → Pull Request

```bash
git push origin feature/your-feature-name
```

GitHub UI で Pull Request を開く。

### PR のチェックリスト

- [ ] コードが動作することを確認
- [ ] ドキュメント (README / comments) を更新
- [ ] テストコードを追加 (該当する場合)
- [ ] `.gitignore` に秘密情報がないか確認
- [ ] Commit message が明確か確認

## コード規約

### PowerShell Scripts

```powershell
#Requires -Version 7.0

<#
.SYNOPSIS
Brief description

.DESCRIPTION
Longer description with context

.PARAMETER ParamName
Parameter description

.EXAMPLE
pwsh ./script.ps1 -ParamName "value"

.NOTES
Additional notes if needed
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$ParamName,
    
    [Parameter(Mandatory=$false)]
    [string]$OptionalParam = "default"
)

# Function naming: Verb-Noun (e.g., New-PKCEChallenge)
function New-PKCEChallenge {
    [CmdletBinding()]
    param()
    
    # Implementation
}

# Error handling
try {
    # Do something
} catch {
    Write-Error "Error occurred: $_"
    exit 1
}

# Verbose logging
Write-Host "Progress message" -ForegroundColor Yellow
Write-Host "✓ Success" -ForegroundColor Green
Write-Error "Error message" -ForegroundColor Red
```

### JSON (Logic App Workflows)

```json
{
  "definition": {
    "$schema": "https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#",
    "actions": {
      "ActionName": {
        "type": "Http",
        "inputs": {},
        "runAfter": {},
        "description": "Brief description of what this action does"
      }
    }
  }
}
```

### Markdown Documentation

```markdown
# Heading 1

## Heading 2 (Section)

### Heading 3 (Subsection)

**Bold** for emphasis
`code snippet` for inline code

```
code block
```

- Bullet list
  - Nested item

| Table | Header |
|---|---|
| Cell | Value |

[Link text](url)
```

### Bicep / ARM Templates

```bicep
param location string = 'westus2'
param environment string = 'prod'

var resourceNamePrefix = 'my-app-${environment}'

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: 'st${uniqueString(resourceGroup().id)}'
  location: location
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    accessTier: 'Hot'
  }
}
```

## テスト方法

### Manual Testing

```powershell
# 1. Bootstrap
pwsh ./scripts/la-oauth-bootstrap.ps1

# 2. Deploy workflows
cd workflows/wf-TeamsNotify
pwsh ./deploy.ps1

# 3. Test
pwsh ./test.ps1 -Target "Adil"

# 4. Verify results
pwsh ./check-run.ps1 -RunId "<runId>"
```

### Validation Checklist

- [ ] Callback URL が取得できるか
- [ ] Teams メッセージが送信されるか
- [ ] Logic App の全 action が Succeeded か
- [ ] Key Vault の refresh_token が更新されているか
- [ ] EVL-99 が 6 時間ごと自動実行されるか

## ドキュメント更新

新機能 / 変更を加えた場合は対応ドキュメントも更新してください：

| 変更内容 | 更新ドキュメント |
|---|---|
| 新 workflow 追加 | 当該 workflow の README |
| インフラ変更 | bicep template |

## GitHub Actions / CI/CD

現在設定なし。以下を検討中:

- [ ] PowerShell Linting (PSScriptAnalyzer)
- [ ] Bicep validation (`bicep build`)
- [ ] Markdown linting (markdownlint)
- [ ] Secret scanning (detect-secrets)

プロジェクト成長に応じて段階的に導入予定。

## セキュリティに関する報告

**セキュリティ脆弱性を発見した場合**は GitHub Issue ではなく、以下の方法で報告してください:

1. Maintainer に直接 email (security sensitive)
2. GitHub Security Advisory を使用

公開 Issue での報告は避けてください。

## ライセンス

このプロジェクトは **MIT License** の下で公開されています。
PR を submit することで、MIT License での利用に同意したものとします。

## 質問・相談

- General questions → GitHub Discussions
- 技術的質問 → Issue として報告
- 重大なバグ / セキュリティ → direct contact

---

ご協力ありがとうございます！

