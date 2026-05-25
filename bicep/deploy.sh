#!/bin/bash
# ============================================================================
# Zammad Azure VM Deployment Script (Bash)
# ============================================================================
# Usage: ./deploy.sh -g rg-soc-itsm -l westeurope -k ~/.ssh/id_rsa.pub
# ============================================================================

set -e

# Default values
RESOURCE_GROUP="rg-soc-itsm"
LOCATION="westeurope"
SSH_KEY_PATH=""
PARAMETERS_FILE="parameters.json"
WHAT_IF=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Print usage
usage() {
    echo "Usage: $0 -k <ssh-public-key-path> [-g <resource-group>] [-l <location>] [-p <parameters-file>] [--what-if]"
    echo ""
    echo "Options:"
    echo "  -g, --resource-group   Resource group name (default: rg-soc-itsm)"
    echo "  -l, --location         Azure region (default: westeurope)"
    echo "  -k, --ssh-key          Path to SSH public key (required)"
    echo "  -p, --parameters       Parameters file (default: parameters.json)"
    echo "  --what-if              Preview changes without deploying"
    echo "  -h, --help             Show this help message"
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -g|--resource-group)
            RESOURCE_GROUP="$2"
            shift 2
            ;;
        -l|--location)
            LOCATION="$2"
            shift 2
            ;;
        -k|--ssh-key)
            SSH_KEY_PATH="$2"
            shift 2
            ;;
        -p|--parameters)
            PARAMETERS_FILE="$2"
            shift 2
            ;;
        --what-if)
            WHAT_IF=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "Unknown option: $1"
            usage
            ;;
    esac
done

# Validate required parameters
if [[ -z "$SSH_KEY_PATH" ]]; then
    echo -e "${RED}Error: SSH public key path is required${NC}"
    usage
fi

echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN} Zammad Azure VM Deployment${NC}"
echo -e "${CYAN}============================================${NC}"
echo ""

# Check if Azure CLI is installed
if ! command -v az &> /dev/null; then
    echo -e "${RED}Error: Azure CLI is not installed.${NC}"
    echo "Please install it from https://docs.microsoft.com/cli/azure/install-azure-cli"
    exit 1
fi

# Check if logged in
if ! az account show &> /dev/null; then
    echo -e "${YELLOW}Not logged in to Azure. Running 'az login'...${NC}"
    az login
fi

ACCOUNT_NAME=$(az account show --query "name" -o tsv)
ACCOUNT_USER=$(az account show --query "user.name" -o tsv)
echo -e "${GREEN}Logged in as: ${ACCOUNT_USER}${NC}"
echo -e "${GREEN}Subscription: ${ACCOUNT_NAME}${NC}"
echo ""

# Read SSH public key
if [[ ! -f "$SSH_KEY_PATH" ]]; then
    echo -e "${RED}Error: SSH public key not found at: ${SSH_KEY_PATH}${NC}"
    exit 1
fi
SSH_PUBLIC_KEY=$(cat "$SSH_KEY_PATH" | tr -d '\n')
echo -e "${GREEN}SSH public key loaded from: ${SSH_KEY_PATH}${NC}"

# Create resource group if it doesn't exist
echo ""
echo -e "${YELLOW}Checking resource group...${NC}"
if [[ $(az group exists --name "$RESOURCE_GROUP") == "false" ]]; then
    echo -e "${YELLOW}Creating resource group: ${RESOURCE_GROUP} in ${LOCATION}${NC}"
    if [[ "$WHAT_IF" == "false" ]]; then
        az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
    fi
    echo -e "${GREEN}Resource group created.${NC}"
else
    echo -e "${GREEN}Resource group already exists.${NC}"
fi

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
BICEP_FILE="${SCRIPT_DIR}/main.bicep"
PARAMS_FILE="${SCRIPT_DIR}/${PARAMETERS_FILE}"

# Deploy Bicep template
echo ""
echo -e "${YELLOW}Deploying Bicep template...${NC}"
echo -e "${YELLOW}This may take 5-10 minutes...${NC}"
echo ""

DEPLOYMENT_NAME="soc-itsm-deployment-$(date +%Y%m%d%H%M%S)"

DEPLOY_ARGS=(
    "deployment" "group" "create"
    "--resource-group" "$RESOURCE_GROUP"
    "--name" "$DEPLOYMENT_NAME"
    "--template-file" "$BICEP_FILE"
    "--parameters" "@${PARAMS_FILE}"
    "--parameters" "sshPublicKey=${SSH_PUBLIC_KEY}"
)

if [[ "$WHAT_IF" == "true" ]]; then
    DEPLOY_ARGS+=("--what-if")
fi

if ! az "${DEPLOY_ARGS[@]}"; then
    echo -e "${RED}Deployment failed!${NC}"
    exit 1
fi

if [[ "$WHAT_IF" == "false" ]]; then
    # Get outputs
    VM_NAME=$(az deployment group show --resource-group "$RESOURCE_GROUP" --name "$DEPLOYMENT_NAME" --query "properties.outputs.vmName.value" -o tsv)
    PUBLIC_IP=$(az deployment group show --resource-group "$RESOURCE_GROUP" --name "$DEPLOYMENT_NAME" --query "properties.outputs.publicIpAddress.value" -o tsv)
    FQDN=$(az deployment group show --resource-group "$RESOURCE_GROUP" --name "$DEPLOYMENT_NAME" --query "properties.outputs.fqdn.value" -o tsv)
    SSH_CMD=$(az deployment group show --resource-group "$RESOURCE_GROUP" --name "$DEPLOYMENT_NAME" --query "properties.outputs.sshCommand.value" -o tsv)
    ZAMMAD_URL=$(az deployment group show --resource-group "$RESOURCE_GROUP" --name "$DEPLOYMENT_NAME" --query "properties.outputs.zammadUrl.value" -o tsv)
    GRAFANA_URL=$(az deployment group show --resource-group "$RESOURCE_GROUP" --name "$DEPLOYMENT_NAME" --query "properties.outputs.grafanaUrl.value" -o tsv)
    PROMETHEUS_URL=$(az deployment group show --resource-group "$RESOURCE_GROUP" --name "$DEPLOYMENT_NAME" --query "properties.outputs.prometheusUrl.value" -o tsv)

    TRAEFIK_URL=$(az deployment group show --resource-group "$RESOURCE_GROUP" --name "$DEPLOYMENT_NAME" --query "properties.outputs.traefikUrl.value" -o tsv)

    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN} Deployment Complete!${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo -e "VM Name:        ${VM_NAME}"
    echo -e "Public IP:      ${PUBLIC_IP}"
    echo -e "FQDN:           ${FQDN}"
    echo ""
    echo -e "${CYAN}SSH Command:    ${SSH_CMD}${NC}"
    echo ""
    echo -e "${YELLOW}URLs (after SSL setup - requires DNS configuration):${NC}"
    echo -e "  Zammad:       ${ZAMMAD_URL}"
    echo -e "  Grafana:      ${GRAFANA_URL}"
    echo -e "  Prometheus:   ${PROMETHEUS_URL}"
    echo -e "  Traefik:      ${TRAEFIK_URL}"
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN} Next Steps${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo -e "1. Create DNS A records pointing to: ${PUBLIC_IP}"
    echo -e "   - zammad.yourdomain.com"
    echo -e "   - grafana.yourdomain.com"
    echo -e "   - prometheus.yourdomain.com"
    echo -e "   - traefik.yourdomain.com"
    echo ""
    echo -e "2. Wait 2-3 minutes for cloud-init to complete"
    echo ""
    echo -e "3. SSH into the VM and run initial setup:"
    echo -e "${CYAN}   ${SSH_CMD}${NC}"
    echo -e "${CYAN}   sudo /opt/zammad/bicep/initial-setup.sh <repo-url> <domain> <email>${NC}"
    echo ""
    echo -e "   Or manually:"
    echo -e "${CYAN}   sudo git clone <your-repo-url> /opt/zammad${NC}"
    echo -e "${CYAN}   cd /opt/zammad && sudo cp .env.dist .env${NC}"
    echo -e "${CYAN}   sudo nano .env  # Set DOMAIN and ACME_EMAIL${NC}"
    echo -e "${CYAN}   sudo docker compose -f docker-compose.yml -f docker-compose.ssl.yml up -d${NC}"
    echo ""
else
    echo ""
    echo -e "${YELLOW}What-If mode: No changes were made.${NC}"
fi
