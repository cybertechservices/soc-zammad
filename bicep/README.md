# Azure VM Deployment for Zammad

This folder contains Bicep templates to deploy Zammad on an Azure VM with **SSL/HTTPS via Traefik**.

## Features

- **SSL/HTTPS** for all services via Traefik reverse proxy
- **Automatic Let's Encrypt** certificate provisioning and renewal
- **Secure by default** - only ports 22 (SSH), 80 (redirect), and 443 (HTTPS) exposed
- Docker pre-installed with data on separate disk

## Estimated Costs

| Configuration | VM Size | Monthly Cost |
|---------------|---------|--------------|
| Minimal | Standard_B2s (2 vCPU, 4GB) | ~$43 |
| **Recommended** | Standard_B2ms (2 vCPU, 8GB) | ~$73 |
| General Purpose | Standard_D2s_v3 (2 vCPU, 8GB) | ~$83 |
| Large | Standard_D4s_v3 (4 vCPU, 16GB) | ~$153 |

*Costs include VM + 128GB SSD + Static IP. Prices vary by region.*

## Prerequisites

- Azure CLI installed (`az --version`)
- Azure subscription
- SSH key pair (`ssh-keygen -t rsa -b 4096`)
- **Domain name** with ability to create DNS records

## Quick Start

### PowerShell (Windows)

```powershell
cd bicep
.\deploy.ps1 -ResourceGroupName "rg-soc-itsm" -Location "westeurope" -SshPublicKeyPath "~/.ssh/id_rsa.pub"
```

### Bash (Linux/macOS)

```bash
cd bicep
chmod +x deploy.sh
./deploy.sh -g rg-soc-itsm -l westeurope -k ~/.ssh/id_rsa.pub
```

### Azure CLI (Manual)

```bash
# Login
az login

# Create resource group
az group create --name rg-soc-itsm --location westeurope

# Deploy (replace SSH_KEY with your public key)
az deployment group create \
  --resource-group rg-soc-itsm \
  --template-file main.bicep \
  --parameters @parameters.json \
  --parameters sshPublicKey="$(cat ~/.ssh/id_rsa.pub)"
```

## What Gets Deployed

| Resource | Description |
|----------|-------------|
| Virtual Network | 10.0.0.0/16 with subnet 10.0.1.0/24 |
| Network Security Group | SSH (22), HTTP (80), HTTPS (443) only |
| Public IP | Static IP with DNS label |
| Virtual Machine | Ubuntu 22.04 LTS with Docker pre-installed |
| Data Disk | 128GB SSD mounted at /data for Docker volumes |

## Post-Deployment Setup

### 1. Create DNS Records

After deployment, create these DNS A records pointing to the VM's public IP:

| Record | Value |
|--------|-------|
| `zammad.yourdomain.com` | VM Public IP |
| `grafana.yourdomain.com` | VM Public IP |
| `prometheus.yourdomain.com` | VM Public IP |
| `traefik.yourdomain.com` | VM Public IP |

### 2. Run Initial Setup

```bash
# SSH into the VM
ssh zammadadmin@<public-ip>

# Run the setup script
sudo /opt/zammad/bicep/initial-setup.sh \
  https://github.com/your-org/soc-zammad.git \
  zammad.yourdomain.com \
  admin@yourdomain.com
```

### 3. Manual Setup (Alternative)

```bash
# SSH into the VM
ssh zammadadmin@<public-ip>

# Verify Docker is running
docker --version
docker compose version

# Clone this repository
sudo git clone <your-repo-url> /opt/zammad
cd /opt/zammad

# Configure environment
sudo cp .env.dist .env
sudo nano .env  # Set DOMAIN and ACME_EMAIL

# Start Zammad with SSL
sudo docker compose -f docker-compose.yml -f docker-compose.ssl.yml up -d

# Start monitoring with SSL
sudo DOCKER_ROOT_DIR=/data/docker docker compose \
  -f monitoring/docker-compose.monitoring.yml \
  -f monitoring/docker-compose.monitoring.ssl.yml up -d
```

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `baseName` | soc-itsm | Prefix for all resource names |
| `vmSize` | Standard_B2ms | VM size |
| `adminUsername` | zammadadmin | SSH username |
| `sshPublicKey` | (required) | Your SSH public key |
| `dataDiskSizeGB` | 128 | Data disk size |
| `enableAutoShutdown` | false | Auto-shutdown for dev/test |
| `autoShutdownTime` | 23:00 | Shutdown time (UTC) |
| `allowedSshCidr` | (empty) | Restrict SSH to specific IP range |
| `enableBackup` | false | Enable Azure Backup |

## Updating GitHub Actions for Azure Deployment

Update repository secrets in `Settings > Secrets > Actions`:

| Secret | Value | Description |
|--------|-------|-------------|
| `HOST` | VM Public IP | Azure VM IP address |
| `USERNAME` | `zammadadmin` | SSH username |
| `PRIVATE_KEY` | SSH private key | Matching the public key used in Bicep |
| `DOMAIN` | `zammad.yourdomain.com` | Main Zammad domain |
| `GRAFANA_DOMAIN` | `grafana.yourdomain.com` | Grafana subdomain |
| `PROMETHEUS_DOMAIN` | `prometheus.yourdomain.com` | Prometheus subdomain |
| `TRAEFIK_DOMAIN` | `traefik.yourdomain.com` | Traefik dashboard subdomain |

## Security Recommendations

1. **Restrict SSH access**: Set `allowedSshCidr` to your IP range
2. **Use Azure Bastion**: For production, consider Azure Bastion instead of public SSH
3. **Enable backups**: Set `enableBackup: true` for production
4. **Use managed identities**: For accessing other Azure services
5. **Enable HTTPS**: Use the nginx-proxy-manager scenario with Let's Encrypt

## Troubleshooting

### Check cloud-init status
```bash
sudo cloud-init status --wait
sudo cat /var/log/cloud-init-output.log
```

### Check Docker status
```bash
sudo systemctl status docker
sudo docker ps
```

### Check data disk
```bash
df -h /data
ls -la /data/docker
```
