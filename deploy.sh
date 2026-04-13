#!/bin/bash
# =============================================================================
# Deploy to THECOLLECTIVE_AWS01
# =============================================================================
# Run from the corporate laptop (VPN connected).
#
# Usage:
#   ./deploy.sh infra              # Deploy infra (pull + restart)
#   ./deploy.sh <project-name>     # Pull latest + rebuild project
#   ./deploy.sh --all              # Deploy infra + all projects
#
# Examples:
#   ./deploy.sh infra
#   ./deploy.sh marie
#
# Prerequisites:
#   - VPN connected
#   - SSH alias 'aws01' configured in ~/.ssh/config:
#
#       Host aws01
#           HostName 10.251.8.172
#           User ubuntu
#           IdentityFile ~/.ssh/AWSNMTNAPP001-keypair.pem
#
#   - Deploy keys configured on the VM for each private repo
#
# =============================================================================

set -e

VM="${VM:-aws01}"
VM_APP_DIR="/app"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ssh_cmd() {
    ssh "$VM" "$@"
}

deploy_infra() {
    echo -e "${CYAN}[infra] Pulling latest...${NC}"
    ssh_cmd "cd ${VM_APP_DIR}/Deployer && git pull"

    echo -e "${CYAN}[infra] Starting infrastructure...${NC}"
    ssh_cmd "cd ${VM_APP_DIR}/Deployer && ./start.sh"

    echo -e "${GREEN}[infra] Done${NC}"
}

deploy_project() {
    local name="$1"
    local project_dir="${VM_APP_DIR}/${name}"

    echo -e "${CYAN}[${name}] Pulling latest...${NC}"
    ssh_cmd "cd ${project_dir} && git pull"

    echo -e "${CYAN}[${name}] Rebuilding containers...${NC}"
    ssh_cmd "cd ${project_dir} && docker compose -f docker-compose.vm.yml up -d --build"

    echo -e "${GREEN}[${name}] Done — http://52.72.211.242/${name}${NC}"
}

deploy_all() {
    deploy_infra

    echo ""
    local projects
    projects=$(ssh_cmd "find ${VM_APP_DIR} -maxdepth 2 -name 'docker-compose.vm.yml' -exec dirname {} \;" 2>/dev/null)

    for project_dir in $projects; do
        local name=$(basename "$project_dir")
        echo ""
        deploy_project "$name"
    done
}

# ---- Main ----
case "${1:-}" in
    ""|infra)
        deploy_infra
        ;;
    --all)
        deploy_all
        ;;
    *)
        deploy_project "$1"
        ;;
esac

echo ""
echo -e "${GREEN}Deploy complete.${NC}"
