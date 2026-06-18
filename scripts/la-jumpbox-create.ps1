#Requires -Version 7.0
<#
.SYNOPSIS
Jumpbox VM creation script for PE-based Logic App testing

.DESCRIPTION
Creates a Windows 11 Pro VM for testing Logic App callback URL via Private Endpoint
- VM placed in jumpbox subnet
- RDP access with NSG rule
- Azure Hybrid Benefit (Windows Client BYOL) applied
- Auto-Shutdown at 21:00 JST (12:00 UTC) for cost optimization

.PARAMETER ResourceGroupName
Azure resource group name

.PARAMETER VnetName
VNet name containing jumpbox subnet

.PARAMETER SubnetName
Jumpbox subnet name (created if not exists)

.PARAMETER VmName
Virtual Machine name

.PARAMETER VmSize
VM size (default: Standard_D2s_v3)

.EXAMPLE
pwsh ./la-jumpbox-create.ps1 -ResourceGroupName "<resource-group>" -VnetName "<vnet-name>" -VmName "<vm-name>"

#>

param(
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory=$true)]
    [string]$VnetName,
    
    [Parameter(Mandatory=$false)]
    [string]$SubnetName = "snet-jumpbox",
    
    [Parameter(Mandatory=$false)]
    [string]$VmName = "vm-jump-sendmsg",
    
    [Parameter(Mandatory=$false)]
    [string]$VmSize = "Standard_D2s_v3",
    
    [Parameter(Mandatory=$false)]
    [string]$Location
)

$ErrorActionPreference = 'Stop'

function Invoke-AzCommand {
    param(
        [Parameter(Mandatory=$true)]
        [scriptblock]$Command,
        [Parameter(Mandatory=$true)]
        [string]$FailureMessage
    )

    $output = & $Command 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "$FailureMessage`n$output"
    }
    return $output
}

Write-Host "=== Jumpbox VM Creation ===" -ForegroundColor Cyan
Write-Host "Resource Group: $ResourceGroupName"
Write-Host "VNet: $VnetName"
Write-Host "Subnet: $SubnetName"
Write-Host "VM Name: $VmName"
Write-Host "Preferred VM Size: $VmSize"
Write-Host ""

# Resolve location from VNet when not explicitly provided.
$vnetLocation = (Invoke-AzCommand -FailureMessage "Failed to get VNet location for '$VnetName'." -Command {
    az network vnet show -g $ResourceGroupName -n $VnetName --query location -o tsv
}).Trim()

if ([string]::IsNullOrWhiteSpace($Location)) {
    $Location = $vnetLocation
} elseif ($Location -ne $vnetLocation) {
    throw "Location mismatch: provided '$Location' but VNet '$VnetName' is in '$vnetLocation'. Use -Location $vnetLocation or omit -Location."
}

Write-Host "Location: $Location"
Write-Host ""

# Create jumpbox subnet if not exists
Write-Host "Checking jumpbox subnet..." -ForegroundColor Yellow

$subnetJson = az network vnet subnet show `
    -g $ResourceGroupName `
    -n $SubnetName `
    --vnet-name $VnetName `
    -o json 2>$null

$subnet = $null
if ($LASTEXITCODE -eq 0 -and $subnetJson) {
    $subnet = $subnetJson | ConvertFrom-Json
}

if (-not $subnet) {
    Write-Host "Creating jumpbox subnet $SubnetName..." -ForegroundColor Yellow
    Invoke-AzCommand -FailureMessage "Failed to create jumpbox subnet '$SubnetName'." -Command {
        az network vnet subnet create `
            -g $ResourceGroupName `
            -n $SubnetName `
            --vnet-name $VnetName `
            --address-prefixes "10.0.4.0/27" `
            -o none
    } | Out-Null
    Write-Host "✓ Subnet created"

    $subnet = (Invoke-AzCommand -FailureMessage "Failed to retrieve jumpbox subnet after creation." -Command {
        az network vnet subnet show `
            -g $ResourceGroupName `
            -n $SubnetName `
            --vnet-name $VnetName `
            -o json
    }) | ConvertFrom-Json
} else {
    Write-Host "✓ Subnet already exists: $($subnet.addressPrefix)"
}

$subnetId = $subnet.id

# Create NSG for jumpbox (RDP only)
Write-Host "Setting up Network Security Group..." -ForegroundColor Yellow

$nsgName = "nsg-$SubnetName"
$nsgJson = az network nsg show -g $ResourceGroupName -n $nsgName -o json 2>$null
$nsgExists = $null
if ($LASTEXITCODE -eq 0 -and $nsgJson) {
    $nsgExists = $nsgJson | ConvertFrom-Json
}

if (-not $nsgExists) {
    Invoke-AzCommand -FailureMessage "Failed to create NSG '$nsgName'." -Command {
        az network nsg create `
            -g $ResourceGroupName `
            -n $nsgName `
            -l $Location `
            -o none
    } | Out-Null
    Write-Host "✓ NSG created: $nsgName"
} else {
    Write-Host "✓ NSG already exists: $nsgName"
}

# Add RDP inbound rule
Invoke-AzCommand -FailureMessage "Failed to create/update NSG rule AllowRDP." -Command {
    az network nsg rule create `
        -g $ResourceGroupName `
        --nsg-name $nsgName `
        -n "AllowRDP" `
        --priority 100 `
        --source-address-prefixes '*' `
        --source-port-ranges '*' `
        --destination-address-prefixes '*' `
        --destination-port-ranges 3389 `
        --access Allow `
        --protocol Tcp `
        --description "Allow RDP from anywhere" `
        -o none
} | Out-Null
Write-Host "✓ RDP rule added"

# Create public IP
Write-Host "Creating public IP address..." -ForegroundColor Yellow

$pipName = "pip-$VmName"
$pipJson = az network public-ip show -g $ResourceGroupName -n $pipName -o json 2>$null
$pipExists = $null
if ($LASTEXITCODE -eq 0 -and $pipJson) {
    $pipExists = $pipJson | ConvertFrom-Json
}

if (-not $pipExists) {
    Invoke-AzCommand -FailureMessage "Failed to create Public IP '$pipName'." -Command {
        az network public-ip create `
            -g $ResourceGroupName `
            -n $pipName `
            -l $Location `
            --sku Standard `
            --allocation-method Static `
            -o none
    } | Out-Null
    Write-Host "✓ Public IP created: $pipName"
} else {
    Write-Host "✓ Public IP already exists: $pipName"
}

# Create NIC
Write-Host "Creating network interface..." -ForegroundColor Yellow

$nicName = "nic-$VmName"
$nicJson = az network nic show -g $ResourceGroupName -n $nicName -o json 2>$null
$nicExists = $null
if ($LASTEXITCODE -eq 0 -and $nicJson) {
    $nicExists = $nicJson | ConvertFrom-Json
}

if (-not $nicExists) {
    Invoke-AzCommand -FailureMessage "Failed to create NIC '$nicName'." -Command {
        az network nic create `
            -g $ResourceGroupName `
            -n $nicName `
            -l $Location `
            --subnet $subnetId `
            --public-ip-address $pipName `
            --network-security-group $nsgName `
            -o none
    } | Out-Null
    Write-Host "✓ NIC created: $nicName"
} else {
    Write-Host "✓ NIC already exists: $nicName"
}

# Create VM
    Write-Host "Creating Windows 11 Pro VM..." -ForegroundColor Yellow

$vmJson = az vm show -g $ResourceGroupName -n $VmName -o json 2>$null
$vmExists = $null
if ($LASTEXITCODE -eq 0 -and $vmJson) {
    $vmExists = $vmJson | ConvertFrom-Json
}

if (-not $vmExists) {
    $vmSizeCandidates = @(
        $VmSize
        'Standard_D2s_v4'
        'Standard_D2s_v3'
        'Standard_D2s_v2'
        'Standard_D2as_v5'
        'Standard_B2ms'
        'Standard_DS1_v2'
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

    $selectedVmSize = $null
    $lastVmError = $null

    foreach ($sizeCandidate in $vmSizeCandidates) {
        Write-Host "Trying VM size: $sizeCandidate" -ForegroundColor Yellow

        $vmCreateOutput = az vm create `
            -g $ResourceGroupName `
            -n $VmName `
            -l $Location `
            --nics $nicName `
            --image "MicrosoftWindowsDesktop:windows-11:win11-24h2-pro:latest" `
            --size $sizeCandidate `
            --license-type "Windows_Client" `
            --os-disk-name "osdisk-$VmName" `
            --public-ip-sku Standard `
            --security-type TrustedLaunch `
            --enable-secure-boot true `
            --enable-vtpm true `
            --admin-username "azureuser" `
            -o none 2>&1

        if ($LASTEXITCODE -eq 0) {
            $selectedVmSize = $sizeCandidate
            break
        }

        $lastVmError = $vmCreateOutput
        $errorText = ($vmCreateOutput | Out-String)

        if ($errorText -match 'SkuNotAvailable|Capacity Restrictions|not available in location') {
            Write-Host "⚠ VM size $sizeCandidate is not currently available in $Location. Trying next size..." -ForegroundColor Yellow
            continue
        }

        throw "Failed to create VM '$VmName' with size '$sizeCandidate'.`n$errorText"
    }

    if (-not $selectedVmSize) {
        $candidateList = $vmSizeCandidates -join ', '
        throw "Failed to create VM '$VmName'. Tried sizes: $candidateList`n$($lastVmError | Out-String)"
    }

    Write-Host "✓ VM created: $VmName (Windows 11 Pro 24H2 BYOL, size=$selectedVmSize)"
} else {
    Write-Host "✓ VM already exists: $VmName"
}

# Get public IP
$publicIp = Invoke-AzCommand -FailureMessage "Failed to retrieve Public IP address '$pipName'." -Command {
    az network public-ip show `
        -g $ResourceGroupName `
        -n $pipName `
        --query ipAddress -o tsv
}

Write-Host ""
Write-Host "=== Jumpbox Ready ===" -ForegroundColor Green
Write-Host "VM Name: $VmName"
Write-Host "Public IP: $publicIp"
Write-Host "RDP Port: 3389"
Write-Host "Username: azureuser"
Write-Host ""
Write-Host "Next steps:"
Write-Host "1. Connect via RDP: mstsc /v:$publicIp"
Write-Host "2. Inside VM, run test.ps1 from workflows/EVL-04d-TeamsNotify/"
Write-Host "3. For cost optimization, enable Auto-Shutdown: 21:00 JST (12:00 UTC)"
Write-Host ""

# Set Auto-Shutdown (optional, requires resource group automation account)
Write-Host "Configuring Auto-Shutdown..." -ForegroundColor Yellow
try {
    Invoke-AzCommand -FailureMessage "Failed to query VM id for '$VmName'." -Command {
        az vm show -g $ResourceGroupName -n $VmName --query id -o tsv
    } | Out-Null
    
    $shutdownBody = @{
        location = $Location
        properties = @{
            enabled = $true
            shutdownTime = "12:00"
            timeZone = "UTC"
            notificationSettings = @{
                status = "Disabled"
            }
        }
    } | ConvertTo-Json

    Invoke-AzCommand -FailureMessage "Failed to configure Auto-Shutdown schedule for '$VmName'." -Command {
        az resource create `
            --resource-type "microsoft.devtestlab/schedules" `
            -n "shutdown-computevm-$VmName" `
            -g $ResourceGroupName `
            -l $Location `
            --properties $shutdownBody `
            -o none
    } | Out-Null
    
    Write-Host "✓ Auto-Shutdown scheduled for 12:00 UTC (21:00 JST)"
} catch {
    Write-Host "⚠ Auto-Shutdown setup failed (optional): $_" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "✓ Jumpbox setup complete"
Write-Host ""

# Save reference to file
$vmInfo = @{
    timestamp = (Get-Date -AsUTC).ToString('yyyy-MM-ddTHH:mm:ssZ')
    vmName = $VmName
    resourceGroupName = $ResourceGroupName
    publicIp = $publicIp
    username = "azureuser"
    rdpCommand = "mstsc /v:$publicIp"
}

$vmInfo | ConvertTo-Json | Out-File "jumpbox-info.json"
Write-Host "VM info saved to jumpbox-info.json"
