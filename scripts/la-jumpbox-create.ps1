#Requires -Version 7.0
<#
.SYNOPSIS
Jumpbox VM creation script for PE-based Logic App testing

.DESCRIPTION
Creates a Windows Server VM for testing Logic App callback URL via Private Endpoint
- VM placed in jumpbox subnet
- RDP access with NSG rule
- Azure Hybrid Benefit (Windows Server) applied
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
VM size (default: Standard_D2s_v5)

.EXAMPLE
pwsh ./la-jumpbox-create.ps1 -ResourceGroupName "rg-dir" -VnetName "vnet-dir" -VmName "vm-jump-dir"

#>

param(
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroupName,
    
    [Parameter(Mandatory=$true)]
    [string]$VnetName,
    
    [Parameter(Mandatory=$false)]
    [string]$SubnetName = "snet-jumpbox",
    
    [Parameter(Mandatory=$false)]
    [string]$VmName = "vm-jump-dir",
    
    [Parameter(Mandatory=$false)]
    [string]$VmSize = "Standard_D2s_v5",
    
    [Parameter(Mandatory=$false)]
    [string]$Location = "westus2"
)

Write-Host "=== Jumpbox VM Creation ===" -ForegroundColor Cyan
Write-Host "Resource Group: $ResourceGroupName"
Write-Host "VNet: $VnetName"
Write-Host "Subnet: $SubnetName"
Write-Host "VM Name: $VmName"
Write-Host "VM Size: $VmSize"
Write-Host ""

# Create jumpbox subnet if not exists
Write-Host "Checking jumpbox subnet..." -ForegroundColor Yellow

$subnet = az network vnet subnet show `
    -g $ResourceGroupName `
    -n $SubnetName `
    --vnet-name $VnetName `
    -o json 2>$null | ConvertFrom-Json

if (-not $subnet) {
    Write-Host "Creating jumpbox subnet $SubnetName..." -ForegroundColor Yellow
    az network vnet subnet create `
        -g $ResourceGroupName `
        -n $SubnetName `
        --vnet-name $VnetName `
        --address-prefixes "10.0.4.0/27" | Out-Null
    Write-Host "✓ Subnet created"
} else {
    Write-Host "✓ Subnet already exists: $($subnet.addressPrefix)"
}

# Create NSG for jumpbox (RDP only)
Write-Host "Setting up Network Security Group..." -ForegroundColor Yellow

$nsgName = "nsg-$SubnetName"
$nsgExists = az network nsg show -g $ResourceGroupName -n $nsgName -o json 2>$null | ConvertFrom-Json

if (-not $nsgExists) {
    az network nsg create `
        -g $ResourceGroupName `
        -n $nsgName `
        -l $Location | Out-Null
    Write-Host "✓ NSG created: $nsgName"
} else {
    Write-Host "✓ NSG already exists: $nsgName"
}

# Add RDP inbound rule
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
    --description "Allow RDP from anywhere" 2>$null | Out-Null
Write-Host "✓ RDP rule added"

# Create public IP
Write-Host "Creating public IP address..." -ForegroundColor Yellow

$pipName = "pip-$VmName"
$pipExists = az network public-ip show -g $ResourceGroupName -n $pipName -o json 2>$null | ConvertFrom-Json

if (-not $pipExists) {
    az network public-ip create `
        -g $ResourceGroupName `
        -n $pipName `
        -l $Location `
        --sku Standard `
        --allocation-method Static | Out-Null
    Write-Host "✓ Public IP created: $pipName"
} else {
    Write-Host "✓ Public IP already exists: $pipName"
}

# Create NIC
Write-Host "Creating network interface..." -ForegroundColor Yellow

$nicName = "nic-$VmName"
$nicExists = az network nic show -g $ResourceGroupName -n $nicName -o json 2>$null | ConvertFrom-Json

if (-not $nicExists) {
    az network nic create `
        -g $ResourceGroupName `
        -n $nicName `
        -l $Location `
        --subnet $SubnetName `
        --vnet-name $VnetName `
        --public-ip-address $pipName `
        --network-security-group $nsgName | Out-Null
    Write-Host "✓ NIC created: $nicName"
} else {
    Write-Host "✓ NIC already exists: $nicName"
}

# Create VM
Write-Host "Creating Windows Server VM..." -ForegroundColor Yellow

$vmExists = az vm show -g $ResourceGroupName -n $VmName -o json 2>$null | ConvertFrom-Json

if (-not $vmExists) {
    az vm create `
        -g $ResourceGroupName `
        -n $VmName `
        -l $Location `
        --nics $nicName `
        --image "Win2022Datacenter" `
        --size $VmSize `
        --license-type "Windows_Server" `
        --os-disk-name "osdisk-$VmName" `
        --public-ip-sku Standard `
        --security-type TrustedLaunch `
        --enable-secure-boot true `
        --enable-vtpm true `
        --admin-username "azureuser" `
        --generate-ssh-keys | Out-Null
    Write-Host "✓ VM created: $VmName (AHB applied)"
} else {
    Write-Host "✓ VM already exists: $VmName"
}

# Get public IP
$publicIp = az network public-ip show `
    -g $ResourceGroupName `
    -n $pipName `
    --query ipAddress -o tsv

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
    $vmId = az vm show -g $ResourceGroupName -n $VmName --query id -o tsv
    
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

    az resource create `
        --resource-type "microsoft.devtestlab/schedules" `
        -n "shutdown-computevm-$VmName" `
        -g $ResourceGroupName `
        -l $Location `
        --properties $shutdownBody | Out-Null
    
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
