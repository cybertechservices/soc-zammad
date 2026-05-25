#!/bin/bash
# ============================================================================
# Initial Setup Script for Azure VM
# ============================================================================
# Run this script on the Azure VM after Bicep deployment to:
# 1. Clone the repository
# 2. Configure environment
# 3. Start Zammad with SSL/HTTPS via Traefik
# ============================================================================
# Usage: sudo ./initial-setup.sh <repo-url> [domain] [acme-email]
# Example: sudo ./initial-setup.sh https://github.com/org/repo.git zammad.example.com admin@example.com
# ============================================================================

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

REPO_URL="${1:-}"
DOMAIN="${2:-}"
ACME_EMAIL="${3:-}"
DEPLOY_DIR="/opt/zammad"
DOCKER_ROOT_DIR="/data/docker"
SSL_ENABLED="true"

echo -e "${CYAN}============================================${NC}"
echo -e "${CYAN} Zammad Initial Setup${NC}"
echo -e "${CYAN}============================================${NC}"
echo ""

# Check if running as root or with sudo
if [[ $EUID -ne 0 ]]; then
    echo -e "${YELLOW}This script should be run with sudo${NC}"
    exit 1
fi

# Wait for cloud-init to complete
echo -e "${YELLOW}Waiting for cloud-init to complete...${NC}"
cloud-init status --wait || true
echo -e "${GREEN}Cloud-init complete.${NC}"
echo ""

# Verify Docker is installed
echo -e "${YELLOW}Verifying Docker installation...${NC}"
if ! command -v docker &> /dev/null; then
    echo -e "${RED}Docker is not installed. Please wait for cloud-init to complete.${NC}"
    exit 1
fi
docker --version
docker compose version
echo -e "${GREEN}Docker is ready.${NC}"
echo ""

# Verify data disk is mounted
echo -e "${YELLOW}Verifying data disk...${NC}"
if mountpoint -q /data; then
    echo -e "${GREEN}Data disk mounted at /data${NC}"
    df -h /data
else
    echo -e "${RED}Data disk not mounted. Attempting to mount...${NC}"
    if [ -b /dev/disk/azure/scsi1/lun0 ]; then
        mkfs.ext4 -F /dev/disk/azure/scsi1/lun0
        mkdir -p /data
        mount /dev/disk/azure/scsi1/lun0 /data
        echo '/dev/disk/azure/scsi1/lun0 /data ext4 defaults,nofail 0 2' >> /etc/fstab
        mkdir -p /data/docker
        echo '{"data-root": "/data/docker"}' > /etc/docker/daemon.json
        systemctl restart docker
        echo -e "${GREEN}Data disk mounted and Docker configured.${NC}"
    else
        echo -e "${RED}Data disk not found!${NC}"
        exit 1
    fi
fi
echo ""

# Clone repository
if [[ -z "$REPO_URL" ]]; then
    echo -e "${YELLOW}No repository URL provided.${NC}"
    echo -e "Please provide the repository URL as an argument:"
    echo -e "  ${CYAN}./initial-setup.sh https://github.com/your-org/your-repo.git${NC}"
    echo ""
    read -p "Enter repository URL: " REPO_URL
fi

echo -e "${YELLOW}Cloning repository...${NC}"
if [[ -d "$DEPLOY_DIR/.git" ]]; then
    echo -e "${YELLOW}Repository already exists. Pulling latest...${NC}"
    cd "$DEPLOY_DIR"
    git pull origin main
else
    rm -rf "$DEPLOY_DIR"
    git clone "$REPO_URL" "$DEPLOY_DIR"
fi
echo -e "${GREEN}Repository cloned to ${DEPLOY_DIR}${NC}"
echo ""

# Set permissions
SUDO_USER="${SUDO_USER:-zammadadmin}"
chown -R "$SUDO_USER:$SUDO_USER" "$DEPLOY_DIR"

# Configure environment
cd "$DEPLOY_DIR"
echo -e "${YELLOW}Configuring environment...${NC}"
if [[ ! -f .env ]]; then
    cp .env.dist .env
    echo -e "${GREEN}Created .env from .env.dist${NC}"
else
    echo -e "${GREEN}.env already exists${NC}"
fi

# Configure SSL domain
if [[ -z "$DOMAIN" ]]; then
    echo ""
    echo -e "${YELLOW}SSL Configuration Required${NC}"
    echo -e "Enter your domain name (e.g., zammad.example.com):"
    read -p "Domain: " DOMAIN
fi

if [[ -z "$ACME_EMAIL" ]]; then
    echo -e "Enter email for Let's Encrypt notifications:"
    read -p "Email: " ACME_EMAIL
fi

if [[ -n "$DOMAIN" ]] && [[ -n "$ACME_EMAIL" ]]; then
    # Update .env with SSL settings
    sed -i "s|^# DOMAIN=.*|DOMAIN=${DOMAIN}|" .env
    sed -i "s|^# ACME_EMAIL=.*|ACME_EMAIL=${ACME_EMAIL}|" .env

    # Add if not present
    grep -q "^DOMAIN=" .env || echo "DOMAIN=${DOMAIN}" >> .env
    grep -q "^ACME_EMAIL=" .env || echo "ACME_EMAIL=${ACME_EMAIL}" >> .env

    # Set default subdomains
    grep -q "^GRAFANA_DOMAIN=" .env || echo "GRAFANA_DOMAIN=grafana.${DOMAIN}" >> .env
    grep -q "^PROMETHEUS_DOMAIN=" .env || echo "PROMETHEUS_DOMAIN=prometheus.${DOMAIN}" >> .env
    grep -q "^TRAEFIK_DASHBOARD_DOMAIN=" .env || echo "TRAEFIK_DASHBOARD_DOMAIN=traefik.${DOMAIN}" >> .env

    echo -e "${GREEN}SSL configuration saved to .env${NC}"
    echo ""
    echo -e "${YELLOW}IMPORTANT: Make sure these DNS records point to this server:${NC}"
    PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || echo "your-ip")
    echo -e "  ${DOMAIN} -> ${PUBLIC_IP}"
    echo -e "  grafana.${DOMAIN} -> ${PUBLIC_IP}"
    echo -e "  prometheus.${DOMAIN} -> ${PUBLIC_IP}"
    echo -e "  traefik.${DOMAIN} -> ${PUBLIC_IP}"
else
    echo -e "${YELLOW}Skipping SSL configuration. Edit .env manually later.${NC}"
    SSL_ENABLED="false"
fi
echo ""

# Ask to start Zammad
echo -e "${YELLOW}Ready to start Zammad?${NC}"
read -p "Start Zammad now? [Y/n] " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]] || [[ -z $REPLY ]]; then
    if [[ "$SSL_ENABLED" == "true" ]]; then
        echo -e "${YELLOW}Starting Zammad with SSL (Traefik)...${NC}"
        docker compose -f docker-compose.yml -f docker-compose.ssl.yml pull
        docker compose -f docker-compose.yml -f docker-compose.ssl.yml up -d

        echo ""
        echo -e "${YELLOW}Starting monitoring stack with SSL...${NC}"
        DOCKER_ROOT_DIR="$DOCKER_ROOT_DIR" docker compose \
            -f monitoring/docker-compose.monitoring.yml \
            -f monitoring/docker-compose.monitoring.ssl.yml pull
        DOCKER_ROOT_DIR="$DOCKER_ROOT_DIR" docker compose \
            -f monitoring/docker-compose.monitoring.yml \
            -f monitoring/docker-compose.monitoring.ssl.yml up -d
    else
        echo -e "${YELLOW}Starting Zammad (non-SSL)...${NC}"
        docker compose pull
        docker compose up -d

        echo ""
        echo -e "${YELLOW}Starting monitoring stack...${NC}"
        DOCKER_ROOT_DIR="$DOCKER_ROOT_DIR" docker compose -f monitoring/docker-compose.monitoring.yml pull
        DOCKER_ROOT_DIR="$DOCKER_ROOT_DIR" docker compose -f monitoring/docker-compose.monitoring.yml up -d
    fi

    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN} Setup Complete!${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo -e "Services starting up. Wait 2-3 minutes for SSL certificates, then access:"
    echo ""

    if [[ "$SSL_ENABLED" == "true" ]] && [[ -n "$DOMAIN" ]]; then
        echo -e "  Zammad:     ${CYAN}https://${DOMAIN}${NC}"
        echo -e "  Grafana:    ${CYAN}https://grafana.${DOMAIN}${NC}"
        echo -e "  Prometheus: ${CYAN}https://prometheus.${DOMAIN}${NC}"
        echo -e "  Traefik:    ${CYAN}https://traefik.${DOMAIN}${NC}"
    else
        PUBLIC_IP=$(curl -s ifconfig.me 2>/dev/null || echo "your-ip")
        echo -e "  Zammad:     ${CYAN}http://${PUBLIC_IP}:8080${NC}"
        echo -e "  Grafana:    ${CYAN}http://${PUBLIC_IP}:3000${NC}"
        echo -e "  Prometheus: ${CYAN}http://${PUBLIC_IP}:9090${NC}"
    fi
    echo ""
    echo -e "Check container status with:"
    echo -e "  ${CYAN}docker compose ps${NC}"
    echo ""
else
    echo ""
    echo -e "${GREEN}Setup complete. Start Zammad manually with:${NC}"
    echo -e "  ${CYAN}cd ${DEPLOY_DIR}${NC}"
    if [[ "$SSL_ENABLED" == "true" ]]; then
        echo -e "  ${CYAN}docker compose -f docker-compose.yml -f docker-compose.ssl.yml up -d${NC}"
    else
        echo -e "  ${CYAN}docker compose up -d${NC}"
    fi
    echo ""
fi
