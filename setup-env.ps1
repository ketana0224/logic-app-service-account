#Requires -Version 7.0
<#
.SYNOPSIS
環境変数セットアップスクリプト

.DESCRIPTION
このスクリプトは対話的に環境変数を設定し、.env.local ファイルに保存します。

.PARAMETER EnvFile
出力先の環境変数ファイル (デフォルト: scripts/.env.local)

.PARAMETER NonInteractive
非対話モード。既存の .env.local を読み込んで検証のみ実行

.EXAMPLE
pwsh ./setup-env.ps1
pwsh ./setup-env.ps1 -EnvFile ".env.local" -NonInteractive

.NOTES
実行前に以下を確認してください:
- Azure CLI がインストールされている (az --version)
- Azure にログイン済み (az login)
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$EnvFile = "scripts/.env.local",
    
    [Parameter(Mandatory=$false)]
    [switch]$NonInteractive = $false,
    
    [Parameter(Mandatory=$false)]
    [switch]$Validate = $false
)

# ============================================================================
# 関数定義
# ============================================================================

function Write-Header {
    param([string]$Title)
    Write-Host ""
    Write-Host ("=" * 80) -ForegroundColor Cyan
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ("=" * 80) -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "✓ $Message" -ForegroundColor Green
}

function Write-Warning {
    param([string]$Message)
    Write-Host "⚠ $Message" -ForegroundColor Yellow
}

function Write-Error {
    param([string]$Message)
    Write-Host "✗ $Message" -ForegroundColor Red
}

function Read-Input {
    param(
        [string]$Prompt,
        [string]$Default = "",
        [switch]$Required = $false,
        [switch]$Password = $false
    )
    
    $message = $Prompt
    if ($Default) {
        $message += " [$Default]"
    }
    if ($Required -and -not $Default) {
        $message += " (必須)"
    }
    
    do {
        if ($Password) {
            $value = Read-Host $message -AsSecureString | ConvertFrom-SecureString -AsPlainText
        } else {
            $value = Read-Host $message
        }
        
        if (-not $value -and $Default) {
            return $Default
        }
        
        if ($Required -and -not $value) {
            Write-Error "この項目は必須です"
            continue
        }
        
        return $value
    } while ($Required -and -not $value)
}

function Resolve-DefaultValue {
    param(
        [AllowNull()]
        [object]$Current,
        [AllowNull()]
        [object]$Fallback
    )

    $currentText = [string]$Current
    if (-not [string]::IsNullOrWhiteSpace($currentText)) {
        return $currentText
    }

    return [string]$Fallback
}

function Validate-AzureContext {
    Write-Header "Azure コンテキストの検証"
    
    try {
        $context = az account show --query "{ id: id, name: name, tenantId: tenantId }" -o json | ConvertFrom-Json
        Write-Success "Azure にログイン済み"
        Write-Host "Subscription: $($context.name) ($($context.id))" -ForegroundColor Gray
        Write-Host "Tenant ID: $($context.tenantId)" -ForegroundColor Gray
        return $context
    } catch {
        Write-Error "Azure にログインしていません。az login を実行してください。"
        exit 1
    }
}

function Load-EnvFile {
    param([string]$FilePath)
    
    $env_vars = @{}
    if (Test-Path $FilePath) {
        $lines = Get-Content -Path $FilePath
        foreach ($rawLine in $lines) {
            $line = $rawLine.Trim()
            if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) {
                continue
            }
            if ($line -notmatch '^\w+=') {
                continue
            }

            $key, $value = $line -split '=', 2
            $key = $key.Trim()
            $value = $value.Trim()

            # Strip surrounding single or double quotes from .env values.
            if ($value.Length -ge 2) {
                if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
                    $value = $value.Substring(1, $value.Length - 2)
                }
            }

            $env_vars[$key] = $value
        }
        Write-Success "$FilePath をロード済み"
    }
    return $env_vars
}

function Save-EnvFile {
    param(
        [hashtable]$Variables,
        [string]$FilePath
    )
    
    $dir = Split-Path $FilePath -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Write-Success "ディレクトリを作成: $dir"
    }
    
    $content = @"
# ============================================================================
# Environment Configuration (Local)
# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
# ============================================================================
# このファイルは .gitignore に含まれています。秘密情報は含めないでください。

"@
    
    foreach ($key in $Variables.Keys | Sort-Object) {
        $value = $Variables[$key]
        $content += "$key=`"$value`"`n"
    }
    
    Set-Content -Path $FilePath -Value $content -Encoding UTF8
    Write-Success "$FilePath に保存しました"
    Write-Host "ファイルパス: $(Resolve-Path $FilePath)" -ForegroundColor Gray
}

function Validate-EnvVariables {
    param([hashtable]$Variables)
    
    Write-Header "環境変数の検証"
    
    $required = @(
        'AZURE_SUBSCRIPTION_ID',
        'AZURE_TENANT_ID',
        'M365_TENANT_ID',
        'RESOURCE_GROUP_NAME',
        'LOCATION',
        'LOGIC_APP_NAME',
        'KEY_VAULT_NAME',
        'STORAGE_ACCOUNT_NAME',
        'APP_SERVICE_PLAN_NAME',
        'VNET_NAME',
        'FIREWALL_NAME',
        'FIREWALL_POLICY_NAME',
        'LOG_ANALYTICS_NAME',
        'APP_INSIGHTS_NAME'
    )
    
    $missing = @()
    $valid = 0
    
    foreach ($key in $required) {
        if ($Variables.ContainsKey($key) -and $Variables[$key]) {
            Write-Success "$key が設定されています"
            $valid++
        } else {
            Write-Error "$key が設定されていません"
            $missing += $key
        }
    }
    
    Write-Host ""
    Write-Host "検証結果: $valid/$($required.Count) 項目が設定されています" -ForegroundColor Cyan
    
    if ($missing.Count -gt 0) {
        Write-Warning "以下の項目が不足しています: $($missing -join ', ')"
        return $false
    }

    if (-not ($Variables.ContainsKey('SERVICE_ACCOUNT_UPN') -and $Variables['SERVICE_ACCOUNT_UPN'])) {
        Write-Warning "SERVICE_ACCOUNT_UPN は未設定です。Phase 2 で Service Account 作成後、Phase 3 (OAuth bootstrap) 前に設定してください。"
    }
    
    return $true
}

# ============================================================================
# メイン処理
# ============================================================================

try {
    if ($Validate) {
        # 検証モードのみ実行
        $variables = Load-EnvFile $EnvFile
        Validate-EnvVariables $variables
        exit 0
    }
    
    if ($NonInteractive) {
        # 非対話モード: 既存ファイルを検証
        Write-Header "非対話モード: 環境変数を検証"
        $variables = Load-EnvFile $EnvFile
        if (-not (Validate-EnvVariables $variables)) {
            Write-Error "環境変数の検証に失敗しました"
            exit 1
        }
        Write-Success "すべての環境変数が正しく設定されています"
        exit 0
    }
    
    # 対話モード: Azure コンテキスト検証
    $azContext = Validate-AzureContext
    
    # Phase 0: Azure & Microsoft 365 基本情報
    Write-Header "Phase 0: Azure & Microsoft 365 基本情報を入力"
    
    $variables = Load-EnvFile $EnvFile
    
    $variables['AZURE_SUBSCRIPTION_ID'] = Read-Input `
        "Azure Subscription ID" `
        -Default (Resolve-DefaultValue $variables['AZURE_SUBSCRIPTION_ID'] $azContext.id) `
        -Required
    
    $variables['AZURE_TENANT_ID'] = Read-Input `
        "Azure Tenant ID" `
        -Default (Resolve-DefaultValue $variables['AZURE_TENANT_ID'] $azContext.tenantId) `
        -Required
    
    $variables['M365_TENANT_ID'] = Read-Input `
        "Microsoft 365 Tenant ID" `
        -Default $variables['M365_TENANT_ID'] `
        -Required
    
    $variables['SERVICE_ACCOUNT_UPN'] = Read-Input `
        "Service Account UPN (未作成なら空でスキップ可。例: system-notify@your-tenant.onmicrosoft.com)" `
        -Default $variables['SERVICE_ACCOUNT_UPN']

    if (-not $variables['SERVICE_ACCOUNT_UPN']) {
        Write-Warning "Service Account UPN は未設定です。Phase 2 で作成後に setup-env.ps1 を再実行するか scripts/.env.local を更新してください。"
    }
    
    # Phase 1: インフラストラクチャ設定
    Write-Header "Phase 1: インフラストラクチャ設定を入力"
    
    $variables['RESOURCE_GROUP_NAME'] = Read-Input `
        "Resource Group 名" `
        -Default (Resolve-DefaultValue $variables['RESOURCE_GROUP_NAME'] "rg-sendmsg-app") `
        -Required
    
    Write-Host "利用可能なリージョン: westus2, japaneast, eastus2" -ForegroundColor Gray
    $variables['LOCATION'] = Read-Input `
        "Azure リージョン" `
        -Default (Resolve-DefaultValue $variables['LOCATION'] "eastus2") `
        -Required
    
    $variables['LOGIC_APP_NAME'] = Read-Input `
        "Logic App リソース名 (参考: la-sendmsg-m365-connector)" `
        -Default (Resolve-DefaultValue $variables['LOGIC_APP_NAME'] "la-sendmsg-m365-connector") `
        -Required
    
    $variables['KEY_VAULT_NAME'] = Read-Input `
        "Key Vault 名 (参考: kv-sendmsg-001, グローバル一意)" `
        -Default (Resolve-DefaultValue $variables['KEY_VAULT_NAME'] "kv-sendmsg-001") `
        -Required

    $variables['STORAGE_ACCOUNT_NAME'] = Read-Input `
        "Storage Account 名 (参考: stsendmsg001, 英小文字/数字のみ 3-24)" `
        -Default (Resolve-DefaultValue $variables['STORAGE_ACCOUNT_NAME'] "stsendmsg001") `
        -Required
    
    $variables['APP_SERVICE_PLAN_NAME'] = Read-Input `
        "App Service Plan 名 (参考: asp-sendmsg-workflow)" `
        -Default (Resolve-DefaultValue $variables['APP_SERVICE_PLAN_NAME'] "asp-sendmsg-workflow") `
        -Required

    $variables['VNET_NAME'] = Read-Input `
        "VNet 名 (参考: vnet-sendmsg)" `
        -Default (Resolve-DefaultValue $variables['VNET_NAME'] "vnet-sendmsg") `
        -Required

    $variables['FIREWALL_NAME'] = Read-Input `
        "Azure Firewall 名 (参考: afw-sendmsg)" `
        -Default (Resolve-DefaultValue $variables['FIREWALL_NAME'] "afw-sendmsg") `
        -Required

    $variables['FIREWALL_POLICY_NAME'] = Read-Input `
        "Firewall Policy 名 (参考: afwp-sendmsg)" `
        -Default (Resolve-DefaultValue $variables['FIREWALL_POLICY_NAME'] "afwp-sendmsg") `
        -Required

    $variables['LOG_ANALYTICS_NAME'] = Read-Input `
        "Log Analytics 名 (参考: log-sendmsg)" `
        -Default (Resolve-DefaultValue $variables['LOG_ANALYTICS_NAME'] "log-sendmsg") `
        -Required

    $variables['APP_INSIGHTS_NAME'] = Read-Input `
        "Application Insights 名 (参考: appi-sendmsg)" `
        -Default (Resolve-DefaultValue $variables['APP_INSIGHTS_NAME'] "appi-sendmsg") `
        -Required
    
    # Phase 1: ネットワーク設定
    Write-Host ""
    $configNetwork = Read-Host "ネットワーク設定をカスタマイズしますか？ (y/N)"
    
    if ($configNetwork -eq 'y') {
        Write-Host "VNet CIDR: " -ForegroundColor Gray
        $variables['VNET_ADDRESS_PREFIX'] = Read-Input `
            "VNet アドレス範囲" `
            -Default (Resolve-DefaultValue $variables['VNET_ADDRESS_PREFIX'] "10.0.0.0/16")
        
        $variables['SUBNET_LOGICAPP_PREFIX'] = Read-Input `
            "Logic App サブネット CIDR" `
            -Default (Resolve-DefaultValue $variables['SUBNET_LOGICAPP_PREFIX'] "10.0.1.0/27")
        
        $variables['SUBNET_PEP_PREFIX'] = Read-Input `
            "Private Endpoint サブネット CIDR" `
            -Default (Resolve-DefaultValue $variables['SUBNET_PEP_PREFIX'] "10.0.2.0/27")
        
        $variables['SUBNET_FIREWALL_PREFIX'] = Read-Input `
            "Azure Firewall サブネット CIDR" `
            -Default (Resolve-DefaultValue $variables['SUBNET_FIREWALL_PREFIX'] "10.0.3.0/26")
        
        $variables['SUBNET_JUMPBOX_PREFIX'] = Read-Input `
            "Jumpbox サブネット CIDR" `
            -Default (Resolve-DefaultValue $variables['SUBNET_JUMPBOX_PREFIX'] "10.0.4.0/27")
    } else {
        # デフォルト値を設定
        $variables['VNET_ADDRESS_PREFIX'] = Resolve-DefaultValue $variables['VNET_ADDRESS_PREFIX'] "10.0.0.0/16"
        $variables['SUBNET_LOGICAPP_PREFIX'] = Resolve-DefaultValue $variables['SUBNET_LOGICAPP_PREFIX'] "10.0.1.0/27"
        $variables['SUBNET_PEP_PREFIX'] = Resolve-DefaultValue $variables['SUBNET_PEP_PREFIX'] "10.0.2.0/27"
        $variables['SUBNET_FIREWALL_PREFIX'] = Resolve-DefaultValue $variables['SUBNET_FIREWALL_PREFIX'] "10.0.3.0/26"
        $variables['SUBNET_JUMPBOX_PREFIX'] = Resolve-DefaultValue $variables['SUBNET_JUMPBOX_PREFIX'] "10.0.4.0/27"
    }
    
    # Phase 2: Entra ID アプリ登録 (オプション)
    Write-Header "Phase 2: Entra ID アプリ登録情報"
    
    Write-Host "Entra App Registration はまだ作成されていない場合はスキップできます。" -ForegroundColor Gray
    $configEntra = Read-Host "Entra App Registration の情報を入力しますか？ (y/N)"
    
    if ($configEntra -eq 'y') {
        $variables['ENTRA_APP_CLIENT_ID'] = Read-Input `
            "Entra App Registration Client ID" `
            -Default $variables['ENTRA_APP_CLIENT_ID']
    }
    
    # タグ設定
    Write-Header "リソースタグ"
    
    $variables['TAG_ENVIRONMENT'] = Read-Input `
        "環境 (dev/test/prod)" `
        -Default (Resolve-DefaultValue $variables['TAG_ENVIRONMENT'] "dev")
    
    $variables['TAG_OWNER'] = Read-Input `
        "オーナーメール" `
        -Default $variables['TAG_OWNER']
    
    # ファイルに保存
    Write-Host ""
    Save-EnvFile $variables $EnvFile
    
    # 検証
    Write-Host ""
    if (Validate-EnvVariables $variables) {
        Write-Success "環境変数の設定が完了しました!"
        Write-Host ""
        Write-Host "次のステップ:" -ForegroundColor Cyan
        Write-Host "  1. 次のコマンドを実行して環境変数をロード:"
        Write-Host "     . ./scripts/load-env.ps1" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  2. Azure リソースグループを作成:"
        Write-Host "     az group create -n `$env:RESOURCE_GROUP_NAME -l `$env:LOCATION" -ForegroundColor Gray
        Write-Host ""
        Write-Host "  3. インフラストラクチャをデプロイ:"
        Write-Host "     az deployment group create \" -ForegroundColor Gray
        Write-Host "       -g `$env:RESOURCE_GROUP_NAME \" -ForegroundColor Gray
            Write-Host "       -p infrastructure/bicep/parameters.prod.bicepparam \" -ForegroundColor Gray
            Write-Host "         location=`$env:LOCATION \" -ForegroundColor Gray
            Write-Host "         logicAppName=`$env:LOGIC_APP_NAME \" -ForegroundColor Gray
            Write-Host "         keyVaultName=`$env:KEY_VAULT_NAME \" -ForegroundColor Gray
            Write-Host "         storageAccountName=`$env:STORAGE_ACCOUNT_NAME \" -ForegroundColor Gray
            Write-Host "         appServicePlanName=`$env:APP_SERVICE_PLAN_NAME \" -ForegroundColor Gray
            Write-Host "         vnetName=`$env:VNET_NAME \" -ForegroundColor Gray
            Write-Host "         firewallName=`$env:FIREWALL_NAME \" -ForegroundColor Gray
            Write-Host "         firewallPolicyName=`$env:FIREWALL_POLICY_NAME \" -ForegroundColor Gray
            Write-Host "         logAnalyticsName=`$env:LOG_ANALYTICS_NAME \" -ForegroundColor Gray
            Write-Host "         appInsightsName=`$env:APP_INSIGHTS_NAME" -ForegroundColor Gray
        Write-Host "       -p infrastructure/bicep/parameters.prod.bicepparam" -ForegroundColor Gray
    } else {
        Write-Warning "いくつかの環境変数が設定されていません。後で setup-env.ps1 を再度実行してください。"
    }
    
} catch {
    Write-Error ('エラーが発生しました: ' + $_)
    exit 1
}
