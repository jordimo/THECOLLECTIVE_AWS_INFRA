#!/bin/bash
# =============================================================================
# Bootstrap THECOLLECTIVE_AWS01 — Run on a fresh Ubuntu EC2
# =============================================================================
# This script installs everything needed on a blank VM:
#   1. System updates
#   2. Docker + Docker Compose
#   3. Git
#   4. Clone this repo to /app
#   5. Run setup.sh
#
# Usage (from corporate laptop):
#   ssh ubuntu@52.72.211.242 'bash -s' < bootstrap.sh
#
# Or copy it to the VM and run:
#   scp bootstrap.sh ubuntu@52.72.211.242:~
#   ssh ubuntu@52.72.211.242 'chmod +x bootstrap.sh && ./bootstrap.sh'
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

REPO_URL="${REPO_URL:-https://github.com/jordimo/THECOLLECTIVE_AWS_INFRA.git}"
APP_DIR="/app"

echo -e "${CYAN}=== THECOLLECTIVE_AWS01 Bootstrap ===${NC}"
echo ""

# ---- System updates ----
echo -e "${CYAN}[1/5] Updating system packages...${NC}"
sudo apt-get update -y
sudo apt-get upgrade -y

# ---- Install Docker ----
echo ""
echo -e "${CYAN}[2/5] Installing Docker...${NC}"
if command -v docker &> /dev/null; then
    echo -e "  ${GREEN}Docker already installed: $(docker --version)${NC}"
else
    # Install prerequisites
    sudo apt-get install -y ca-certificates curl gnupg

    # Add Docker GPG key
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg

    # Add Docker repo
    echo \
      "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
      sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Install Docker
    sudo apt-get update -y
    sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    # Add current user to docker group (avoids sudo for docker commands)
    sudo usermod -aG docker "$USER"

    echo -e "  ${GREEN}Docker installed: $(docker --version)${NC}"
fi

# ---- Install Git ----
echo ""
echo -e "${CYAN}[3/5] Installing Git...${NC}"
if command -v git &> /dev/null; then
    echo -e "  ${GREEN}Git already installed: $(git --version)${NC}"
else
    sudo apt-get install -y git
    echo -e "  ${GREEN}Git installed: $(git --version)${NC}"
fi

# ---- Clone repo ----
echo ""
echo -e "${CYAN}[4/5] Setting up ${APP_DIR}...${NC}"
if [ -d "${APP_DIR}/Deployer" ]; then
    echo -e "  ${GREEN}${APP_DIR}/Deployer already exists, pulling latest...${NC}"
    cd "${APP_DIR}/Deployer" && git pull
else
    sudo mkdir -p "$APP_DIR"
    sudo chown "$USER:$USER" "$APP_DIR"
    git clone "$REPO_URL" "${APP_DIR}/Deployer"
    echo -e "  ${GREEN}Cloned to ${APP_DIR}/Deployer${NC}"
fi

# ---- Run setup ----
echo ""
echo -e "${CYAN}[5/5] Running infrastructure setup...${NC}"
cd "${APP_DIR}/Deployer"
# Use newgrp to pick up docker group without re-login
sg docker -c "./setup.sh"

echo ""
echo -e "${GREEN}=== Bootstrap Complete ===${NC}"
echo ""
echo "  Next steps:"
echo "    1. Edit ${APP_DIR}/Deployer/traefik/.env (set POSTGRES_PASSWORD)"
echo "    2. cd ${APP_DIR}/Deployer && ./start.sh"
echo ""
echo "  NOTE: If 'docker' commands fail with permission errors,"
echo "  log out and back in so the docker group takes effect."
echo ""
