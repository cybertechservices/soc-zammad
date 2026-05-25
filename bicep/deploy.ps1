# ============================================================================
# Zammad Azure VM Deployment Script (PowerShell)
# ============================================================================
# Usage: .\deploy.ps1 -ResourceGroupName "rg-soc-itsm" -Location "westeurope" -SshPublicKeyPath "~/.ssh/id_rsa.pub"
# ============================================================================

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ResourceGroupName,

    [Parameter(Mandatory = $false)]
    [string]$Location = "westeurope",

    [Parameter(Mandatory = $true)]
    [string]$SshPublicKeyPath,

    [Parameter(Mandatory = $false)]
    [string]$ParametersFile = "parameters.json",

    [Parameter(Mandatory = $false)]
    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " Zammad Azure VM Deployment" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# Check if Azure CLI is installed
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Error "Azure CLI is not installed. Please install it from https://docs.microsoft.com/cli/azure/install-azure-cli"
    exit 1
}

# Check if logged in
$account = az account show 2>$null | ConvertFrom-Json
if (-not $account) {
    Write-Host "Not logged in to Azure. Running 'az login'..." -ForegroundColor Yellow
    az login
    $account = az account show | ConvertFrom-Json
}

Write-Host "Logged in as: $($account.user.name)" -ForegroundColor Green
Write-Host "Subscription: $($account.name) ($($account.id))" -ForegroundColor Green
Write-Host ""

# Read SSH public key
if (-not (Test-Path $SshPublicKeyPath)) {
    Write-Error "SSH public key not found at: $SshPublicKeyPath"
    exit 1
}
$sshPublicKey = Get-Content $SshPublicKeyPath -Raw
$sshPublicKey = $sshPublicKey.Trim()
Write-Host "SSH public key loaded from: $SshPublicKeyPath" -ForegroundColor Green

# Create resource group if it doesn't exist
Write-Host ""
Write-Host "Checking resource group..." -ForegroundColor Yellow
$rgExists = az group exists --name $ResourceGroupName | ConvertFrom-Json
if (-not $rgExists) {
    Write-Host "Creating resource group: $ResourceGroupName in $Location" -ForegroundColor Yellow
    if (-not $WhatIf) {
        az group create --name $ResourceGroupName --location $Location | Out-Null
    }
    Write-Host "Resource group created." -ForegroundColor Green
} else {
    Write-Host "Resource group already exists." -ForegroundColor Green
}

# Deploy Bicep template
Write-Host ""
Write-Host "Deploying Bicep template..." -ForegroundColor Yellow
Write-Host "This may take 5-10 minutes..." -ForegroundColor Yellow
Write-Host ""

$deploymentName = "zammad-deployment-$(Get-Date -Format 'yyyyMMddHHmmss')"
$bicepFile = Join-Path $PSScriptRoot "main.bicep"

$deploymentArgs = @(
    "deployment", "group", "create",
    "--resource-group", $ResourceGroupName,
    "--name", $deploymentName,
    "--template-file", $bicepFile,
    "--parameters", "@$ParametersFile",
    "--parameters", "sshPublicKey=$sshPublicKey"
)

if ($WhatIf) {
    $deploymentArgs += "--what-if"
}

$result = az @deploymentArgs 2>&1

if ($LASTEXITCODE -ne 0) {
    Write-Error "Deployment failed: $result"
    exit 1
}

if (-not $WhatIf) {
    $outputs = az deployment group show `
        --resource-group $ResourceGroupName `
        --name $deploymentName `
        --query "properties.outputs" | ConvertFrom-Json

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Green
    Write-Host " Deployment Complete!" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "VM Name:        $($outputs.vmName.value)" -ForegroundColor White
    Write-Host "Public IP:      $($outputs.publicIpAddress.value)" -ForegroundColor White
    Write-Host "FQDN:           $($outputs.fqdn.value)" -ForegroundColor White
    Write-Host ""
    Write-Host "SSH Command:    $($outputs.sshCommand.value)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "URLs (after SSL setup - requires DNS configuration):" -ForegroundColor Yellow
    Write-Host "  Zammad:       $($outputs.zammadUrl.value)" -ForegroundColor White
    Write-Host "  Grafana:      $($outputs.grafanaUrl.value)" -ForegroundColor White
    Write-Host "  Prometheus:   $($outputs.prometheusUrl.value)" -ForegroundColor White
    Write-Host "  Traefik:      $($outputs.traefikUrl.value)" -ForegroundColor White
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Green
    Write-Host " Next Steps" -ForegroundColor Green
    Write-Host "============================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "1. Create DNS A records pointing to: $($outputs.publicIpAddress.value)" -ForegroundColor White
    Write-Host "   - zammad.yourdomain.com" -ForegroundColor Gray
    Write-Host "   - grafana.yourdomain.com" -ForegroundColor Gray
    Write-Host "   - prometheus.yourdomain.com" -ForegroundColor Gray
    Write-Host "   - traefik.yourdomain.com" -ForegroundColor Gray
    Write-Host ""
    Write-Host "2. Wait 2-3 minutes for cloud-init to complete" -ForegroundColor White
    Write-Host ""
    Write-Host "3. SSH into the VM and run initial setup:" -ForegroundColor White
    Write-Host "   $($outputs.sshCommand.value)" -ForegroundColor Cyan
    Write-Host "   sudo /opt/zammad/bicep/initial-setup.sh <repo-url> <domain> <email>" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "   Or manually:" -ForegroundColor White
    Write-Host "   sudo git clone <your-repo-url> /opt/zammad" -ForegroundColor Cyan
    Write-Host "   cd /opt/zammad && sudo cp .env.dist .env" -ForegroundColor Cyan
    Write-Host "   sudo nano .env  # Set DOMAIN and ACME_EMAIL" -ForegroundColor Cyan
    Write-Host "   sudo docker compose -f docker-compose.yml -f docker-compose.ssl.yml up -d" -ForegroundColor Cyan
    Write-Host ""
} else {
    Write-Host ""
    Write-Host "What-If mode: No changes were made." -ForegroundColor Yellow
}
