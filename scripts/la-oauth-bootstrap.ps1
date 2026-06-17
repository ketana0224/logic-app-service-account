#Requires -Version 7.0
<#
.SYNOPSIS
OAuth Bootstrap script for Service Account (system-notify)
Initiates Auth Code Flow with PKCE to obtain initial refresh_token

.DESCRIPTION
This script:
1. Starts local HTTP listener on port 8400
2. Opens browser to Microsoft Entra login
3. Captures Authorization Code from callback
4. Exchanges code for access_token + refresh_token
5. Stores refresh_token in Key Vault

IMPORTANT: Service Account MUST have permanent password set (TAP is FORBIDDEN)

.PARAMETER TenantId
Microsoft 365 tenant ID (M365CPI65139919)

.PARAMETER ClientId
Entra App Registration client ID

.PARAMETER KeyVaultName
Key Vault resource name to store refresh_token

.PARAMETER ServiceAccountUPN
Service Account UPN (system-notify@...)

.EXAMPLE
pwsh ./la-oauth-bootstrap.ps1 -TenantId "655bd66a-..." -ClientId "d53202ed-..." -KeyVaultName "kv-dirm365-3647"

#>

param(
    [Parameter(Mandatory=$false)]
    [string]$TenantId = $env:M365_TENANT_ID,
    
    [Parameter(Mandatory=$false)]
    [string]$ClientId = $env:ENTRA_APP_CLIENT_ID,
    
    [Parameter(Mandatory=$false)]
    [string]$KeyVaultName = "kv-dirm365-3647",
    
    [Parameter(Mandatory=$false)]
    [string]$ServiceAccountUPN = "system-notify@M365CPI65139919.onmicrosoft.com"
)

# Configuration
$redirectUri = "http://localhost:8400/callback"
$scopes = @(
    "https://graph.microsoft.com/user.read",
    "https://graph.microsoft.com/chat.readwrite",
    "https://graph.microsoft.com/chatmessage.send",
    "offline_access"
)
$listenerPort = 8400

# PKCE Challenge
function New-PKCEChallenge {
    $codeVerifier = [System.Convert]::ToBase64String([System.Security.Cryptography.RandomNumberGenerator]::GetBytes(32)) -replace '\+','-' -replace '/','_' -replace '='
    
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($codeVerifier)
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    $codeChallenge = [System.Convert]::ToBase64String($hash) -replace '\+','-' -replace '/','_' -replace '='
    
    return @{
        CodeVerifier = $codeVerifier
        CodeChallenge = $codeChallenge
    }
}

Write-Host "=== OAuth Bootstrap for Service Account ===" -ForegroundColor Cyan
Write-Host "Tenant ID: $TenantId"
Write-Host "Client ID: $ClientId"
Write-Host "Service Account: $ServiceAccountUPN"
Write-Host ""

# Generate PKCE challenge
Write-Host "Generating PKCE challenge..." -ForegroundColor Yellow
$pkce = New-PKCEChallenge
Write-Host "✓ PKCE ready"

# Build authorization URL
$authUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/authorize?" + @(
    "client_id=$ClientId"
    "redirect_uri=$([System.Web.HttpUtility]::UrlEncode($redirectUri))"
    "response_type=code"
    "scope=$([System.Web.HttpUtility]::UrlEncode($scopes -join ' '))"
    "code_challenge=$($pkce.CodeChallenge)"
    "code_challenge_method=S256"
    "login_hint=$([System.Web.HttpUtility]::UrlEncode($ServiceAccountUPN))"
    "prompt=select_account"
) -join "&"

Write-Host "Authorization URL: $authUrl" -ForegroundColor DarkGray

# Start HTTP listener
Write-Host ""
Write-Host "Starting local HTTP listener on port $listenerPort..." -ForegroundColor Yellow

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$listenerPort/")

try {
    $listener.Start()
    Write-Host "✓ Listener started"
    
    # Open browser
    Write-Host ""
    Write-Host "Opening browser for login..." -ForegroundColor Yellow
    Start-Process $authUrl
    Write-Host "✓ Browser opened. Please sign in with Service Account."
    Write-Host "  Waiting for callback..."
    
    # Wait for callback
    $context = $listener.GetContext()
    $request = $context.Request
    $response = $context.Response
    
    # Extract authorization code
    $queryString = $request.Url.Query
    $code = [System.Web.HttpUtility]::ParseQueryString($queryString)["code"]
    $error = [System.Web.HttpUtility]::ParseQueryString($queryString)["error"]
    
    # Send response to browser
    if ($code) {
        $response.StatusCode = 200
        $body = [System.Text.Encoding]::UTF8.GetBytes("Authorization successful! You can close this window.")
    } else {
        $response.StatusCode = 400
        $body = [System.Text.Encoding]::UTF8.GetBytes("Authorization failed: $error")
    }
    
    $response.OutputStream.Write($body, 0, $body.Length)
    $response.Close()
    
    if (-not $code) {
        throw "Authorization failed: $error"
    }
    
    Write-Host "✓ Authorization code received: $($code.Substring(0, 20))..."
    
} finally {
    $listener.Stop()
    $listener.Close()
}

# Exchange code for tokens
Write-Host ""
Write-Host "Exchanging authorization code for tokens..." -ForegroundColor Yellow

$tokenUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
$tokenBody = @{
    client_id = $ClientId
    scope = $scopes -join " "
    code = $code
    redirect_uri = $redirectUri
    grant_type = "authorization_code"
    code_verifier = $pkce.CodeVerifier
}

try {
    $tokenResponse = Invoke-RestMethod -Uri $tokenUrl -Method Post -Body $tokenBody -ContentType "application/x-www-form-urlencoded"
    Write-Host "✓ Tokens received"
} catch {
    Write-Error "Token exchange failed: $_"
    exit 1
}

# Verify identity
Write-Host ""
Write-Host "Verifying Service Account identity..." -ForegroundColor Yellow

$meUrl = "https://graph.microsoft.com/v1.0/me"
$meHeaders = @{
    "Authorization" = "Bearer $($tokenResponse.access_token)"
    "Content-Type" = "application/json"
}

try {
    $meResponse = Invoke-RestMethod -Uri $meUrl -Headers $meHeaders
    $userPrincipalName = $meResponse.userPrincipalName
    $objectId = $meResponse.id
    Write-Host "✓ Identity verified"
    Write-Host "  User Principal Name: $userPrincipalName"
    Write-Host "  Object ID: $objectId"
} catch {
    Write-Error "Identity verification failed: $_"
    exit 1
}

# Store refresh token in Key Vault
Write-Host ""
Write-Host "Storing refresh_token in Key Vault..." -ForegroundColor Yellow

try {
    # Check if KV is accessible
    $kvExists = az keyvault show --name $KeyVaultName --query id -o tsv 2>$null
    if (-not $kvExists) {
        throw "Key Vault '$KeyVaultName' not found or inaccessible. Ensure you have access rights."
    }
    
    # Store refresh token
    az keyvault secret set `
        --vault-name $KeyVaultName `
        --name "m365-system-notify-refresh-token" `
        --value $tokenResponse.refresh_token | Out-Null
    
    Write-Host "✓ refresh_token stored in KV secret 'm365-system-notify-refresh-token'"
    
    # Store other useful values
    az keyvault secret set --vault-name $KeyVaultName --name "m365-system-notify-oid" --value $objectId | Out-Null
    Write-Host "✓ OID stored in KV secret 'm365-system-notify-oid'"
    
} catch {
    Write-Error "Failed to store refresh_token: $_"
    exit 1
}

# Summary
Write-Host ""
Write-Host "=== Bootstrap Complete ===" -ForegroundColor Green
Write-Host "Service Account: $userPrincipalName"
Write-Host "Object ID: $objectId"
Write-Host "refresh_token stored in: $KeyVaultName/m365-system-notify-refresh-token"
Write-Host ""
Write-Host "Next steps:"
Write-Host "1. Close and re-open Key Vault to complete security lockdown"
Write-Host "2. Deploy Logic App workflows (EVL-04d, EVL-99)"
Write-Host "3. Run test.ps1 in workflows/EVL-04d-TeamsNotify/"
Write-Host ""

# Save results to file for reference
$results = @{
    timestamp = (Get-Date -AsUTC).ToString('yyyy-MM-ddTHH:mm:ssZ')
    userPrincipalName = $userPrincipalName
    objectId = $objectId
    tenantId = $TenantId
    clientId = $ClientId
    keyVaultName = $KeyVaultName
    refreshTokenSecretName = "m365-system-notify-refresh-token"
}

$results | ConvertTo-Json | Out-File "bootstrap-results.json"
Write-Host "Results saved to bootstrap-results.json"
