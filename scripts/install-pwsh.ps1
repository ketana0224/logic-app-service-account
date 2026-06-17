<#
.SYNOPSIS
  PowerShell 7 (pwsh) を踏み台 VM にインストールする。

.DESCRIPTION
  インストール優先順:
    1. すでに pwsh が入っていれば skip（-Force で強制再インストール）
    2. winget が使えれば winget で導入（Microsoft.PowerShell）
    3. 失敗したら GitHub Release から MSI を直接ダウンロードして msiexec で導入

  完了後、現在の powershell.exe セッションから `pwsh -v` を実行して確認する。

.PARAMETER Version
  MSI フォールバック時のバージョン。既定: 7.4.6 (LTS)

.PARAMETER Force
  既に入っていても再インストールする。

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File C:\scripts\install-pwsh.ps1

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File C:\scripts\install-pwsh.ps1 -Force

.NOTES
  - 管理者権限で実行すること（msiexec / winget 両方で必要）
  - 完了後は新しいウィンドウで `pwsh` と入力すれば起動可能
#>

[CmdletBinding()]
param(
    [string]$Version = "7.4.6",
    [switch]$Force
)

$ErrorActionPreference = "Stop"

function Write-Section($t) { Write-Host ""; Write-Host "==== $t ====" -ForegroundColor Cyan }

# ---- 管理者チェック ----
Write-Section "0) 管理者権限チェック"
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw "管理者権限で実行してください。(PowerShell を『管理者として実行』で起動)"
}
"OK: Administrator"

# ---- 既存確認 ----
Write-Section "1) 既存 pwsh 確認"
$existing = Get-Command pwsh -ErrorAction SilentlyContinue
if ($existing -and -not $Force) {
    $v = & $existing.Source -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
    Write-Host "✅ 既にインストール済み: $($existing.Source)  (v$v)" -ForegroundColor Green
    Write-Host "再インストールしたい場合は -Force を付けて再実行してください。" -ForegroundColor Yellow
    return
}
if ($existing -and $Force) {
    Write-Host "既存検出だが -Force 指定のため再インストールします: $($existing.Source)" -ForegroundColor Yellow
}

# ---- winget 経由 ----
$installed = $false
Write-Section "2) winget でインストール試行"
$winget = Get-Command winget -ErrorAction SilentlyContinue
if ($winget) {
    "winget 検出: $($winget.Source)"
    try {
        $args = @(
            "install","--id","Microsoft.PowerShell",
            "--source","winget",
            "--silent",
            "--accept-package-agreements","--accept-source-agreements",
            "--scope","machine"
        )
        if ($Force) { $args += "--force" }
        & winget @args
        if ($LASTEXITCODE -eq 0) {
            Write-Host "✅ winget でのインストール成功" -ForegroundColor Green
            $installed = $true
        } else {
            Write-Warning "winget インストール失敗 (exit=$LASTEXITCODE)。MSI フォールバックへ。"
        }
    } catch {
        Write-Warning "winget 実行で例外: $_。MSI フォールバックへ。"
    }
} else {
    Write-Warning "winget が見つかりません。MSI フォールバックへ。"
}

# ---- MSI フォールバック ----
if (-not $installed) {
    Write-Section "3) MSI 直接ダウンロードでインストール"
    $arch = if ([Environment]::Is64BitOperatingSystem) { "x64" } else { "x86" }
    $msiName = "PowerShell-$Version-win-$arch.msi"
    $url = "https://github.com/PowerShell/PowerShell/releases/download/v$Version/$msiName"
    $dest = Join-Path $env:TEMP $msiName

    "URL  : $url"
    "Dest : $dest"

    # TLS 1.2 強制 (Windows Server 2016/2019 の古い既定対策)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    if (Test-Path $dest) { Remove-Item $dest -Force }

    Write-Host "ダウンロード中..." -ForegroundColor Yellow
    Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
    if (-not (Test-Path $dest)) { throw "MSI ダウンロード失敗" }
    "Size: $([math]::Round((Get-Item $dest).Length / 1MB, 2)) MB"

    Write-Host "msiexec 実行中..." -ForegroundColor Yellow
    $log = Join-Path $env:TEMP "pwsh-install.log"
    $msiArgs = @(
        "/package", "`"$dest`"",
        "/quiet",
        "/norestart",
        "/log", "`"$log`"",
        "ADD_PATH=1",
        "ENABLE_PSREMOTING=0",
        "REGISTER_MANIFEST=1",
        "USE_MU=1",
        "ENABLE_MU=1"
    )
    $p = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        Write-Warning "msiexec exit=$($p.ExitCode)。ログ: $log"
        throw "MSI インストール失敗"
    }
    Write-Host "✅ MSI インストール成功" -ForegroundColor Green
    $installed = $true
}

# ---- 動作確認 ----
Write-Section "4) インストール確認"
# 新しい PATH を反映
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")

$pwshPath = (Get-Command pwsh -ErrorAction SilentlyContinue).Source
if (-not $pwshPath) {
    # 既定インストール先を直接探す
    $candidates = @(
        "$env:ProgramFiles\PowerShell\7\pwsh.exe",
        "${env:ProgramFiles(x86)}\PowerShell\7\pwsh.exe"
    )
    $pwshPath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $pwshPath) {
    throw "インストール後も pwsh.exe が見つかりません。"
}

$v = & $pwshPath -NoProfile -Command '$PSVersionTable.PSVersion.ToString()'
Write-Host ""
Write-Host "✅ Installed: $pwshPath" -ForegroundColor Green
Write-Host "✅ Version  : $v" -ForegroundColor Green

Write-Section "5) 次のステップ"
@"
新しい PowerShell ウィンドウを開いて、以下で 7 系セッションを起動できます:
    pwsh

または明示的にパス指定:
    & "$pwshPath"

Logic App テスト実行例:
    & "$pwshPath" -File C:\scripts\la-jumpbox-login.ps1
    & "$pwshPath" -File C:\scripts\la-evl04d-test.ps1
"@
