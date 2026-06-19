#Requires -Version 7.0
<#
.SYNOPSIS
Load key/value pairs from scripts/.env.local into current PowerShell environment.

.DESCRIPTION
Reads .env style lines (KEY="VALUE") and sets them to Env: variables.
Use dot-sourcing to keep variables in the current shell:
  . ./scripts/load-env.ps1
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$EnvFile = "$PSScriptRoot/.env.local"
)

if (-not (Test-Path -Path $EnvFile)) {
    Write-Error "環境変数ファイルが見つかりません: $EnvFile"
    Write-Host "先に ./setup-env.ps1 を実行して生成してください。" -ForegroundColor Yellow
    exit 1
}

$loaded = 0

Get-Content -Path $EnvFile | ForEach-Object {
    $line = $_.Trim()

    if ([string]::IsNullOrWhiteSpace($line) -or $line.StartsWith('#')) {
        return
    }

    if ($line -notmatch '^\w+=') {
        return
    }

    $name, $value = $line -split '=', 2
    $name = $name.Trim()
    $value = $value.Trim()

    if ($value.Length -ge 2) {
        if (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'"))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
    }

    Set-Item -Path ("Env:{0}" -f $name) -Value $value
    $loaded++
}

Write-Host "$loaded 個の環境変数をロードしました: $EnvFile" -ForegroundColor Green
