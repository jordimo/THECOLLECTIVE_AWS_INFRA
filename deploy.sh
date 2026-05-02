#!/bin/bash
# =============================================================================
# Deploy a project or infra
# =============================================================================
# Usage:
#   ./deploy.sh --target <target> <project>   Deploy a project
#   ./deploy.sh --target <target> infra        Deploy infra (git pull + restart)
#   ./deploy.sh --target <target> --all        Deploy infra + all projects
#
# Examples:
#   ./deploy.sh --target do:zora marie
#   ./deploy.sh --target do:zora infra
#   ./deploy.sh --target do:zora --all
#   ./deploy.sh --target aws marie
#
# =============================================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
    echo "Usage: ./deploy.sh --target <target> <project|infra|--all>"
    echo ""
    echo "Targets:"
    echo "  do:<droplet>   DigitalOcean (e.g. do:zora)"
    echo "  aws            AWS (aws01)"
    echo ""
    echo "Examples:"
    echo "  ./deploy.sh --target do:zora marie"
    echo "  ./deploy.sh --target do:zora infra"
    echo "  ./deploy.sh --target do:zora --all"
    exit 1
}

# ---- Parse args ----
TARGET=""
ACTION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        --all) ACTION="all"; shift ;;
        -*) echo "Unknown option: $1"; usage ;;
        *) ACTION="$1"; shift ;;
    esac
done

[ -z "$TARGET" ] && { echo -e "${RED}Error: --target is required${NC}"; echo ""; usage; }
[ -z "$ACTION" ] && usage

# ---- Environment config ----
case "$TARGET" in
    do:*)
        REMOTE="${TARGET#do:}"
        TARGET_KEY="${REMOTE}"
        INFRA_DIR="/home/deploy/infra"
        APP_DIR="/home/deploy"
        ;;
    aws)
        REMOTE="aws01"
        TARGET_KEY="aws01"
        INFRA_DIR="/app/infra"
        APP_DIR="/app"
        ;;
    *)
        echo -e "${RED}Error: Unknown target '${TARGET}'. Use do:<droplet> or aws.${NC}"
        exit 1
        ;;
esac

ssh_cmd() { ssh "$REMOTE" "$@"; }

deploy_infra() {
    echo -e "${CYAN}[infra] Pulling latest...${NC}"
    ssh_cmd "cd ${INFRA_DIR} && git pull"

    echo -e "${CYAN}[infra] Restarting services...${NC}"
    ssh_cmd "cd ${INFRA_DIR} && docker compose up -d"

    echo -e "${GREEN}[infra] Done${NC}"
}

deploy_project() {
    local name="$1"
    local project_dir="${APP_DIR}/${name}"

    # Check project exists
    if ! ssh_cmd "test -d ${project_dir}"; then
        echo -e "${RED}[${name}] Directory ${project_dir} not found.${NC}"
        echo ""
        echo "  To set up this project for the first time, run:"
        echo "    ./init-project.sh ${name} --target ${TARGET} --repo <git-url>"
        echo ""
        return 1
    fi

    # Pick the compose file. Order of preference:
    #   1. docker-compose.<target_key>.yml — host-specific (e.g. aws01,
    #      isidora). Use this when a project's prod routing differs by
    #      target (e.g. Marie on aws01 needs path-based + HTTP, on DO
    #      needs subdomain + HTTPS — labels can't sanely be parametrized
    #      in a single file).
    #   2. docker-compose.prod.yml — generic prod compose, works for any
    #      server. The default for projects whose prod config is uniform.
    #   3. docker-compose.yml — fallback for projects that haven't split
    #      out a prod-specific file yet.
    local COMPOSE_FILE=""
    for candidate in "docker-compose.${TARGET_KEY}.yml" "docker-compose.prod.yml" "docker-compose.yml"; do
        if ssh_cmd "test -f ${project_dir}/${candidate}"; then
            COMPOSE_FILE="$candidate"
            break
        fi
    done

    if [ -z "$COMPOSE_FILE" ]; then
        echo -e "${RED}[${name}] No compose file found in ${project_dir}${NC}"
        echo ""
        echo "  Looked for: docker-compose.${TARGET_KEY}.yml, docker-compose.prod.yml, docker-compose.yml"
        echo "  Add one. See the README for templates."
        echo ""
        return 1
    fi

    echo -e "${CYAN}[${name}] Pulling latest...${NC}"
    ssh_cmd "cd ${project_dir} && git pull"

    echo -e "${CYAN}[${name}] Rebuilding containers (${COMPOSE_FILE})...${NC}"
    ssh_cmd "cd ${project_dir} && docker compose -f ${COMPOSE_FILE} up -d --build"

    echo -e "${GREEN}[${name}] Done${NC}"
}

deploy_all() {
    deploy_infra
    echo ""

    # Find all projects with a compose file
    local projects
    projects=$(ssh_cmd "ls -d ${APP_DIR}/*/docker-compose*.yml 2>/dev/null | xargs -I{} dirname {} | sort -u" || true)

    for project_dir in $projects; do
        local name=$(basename "$project_dir")
        # Skip infra directory
        [ "$name" = "infra" ] && continue
        echo ""
        deploy_project "$name"
    done
}

# ---- Main ----
case "$ACTION" in
    infra)
        deploy_infra
        ;;
    all)
        deploy_all
        ;;
    *)
        deploy_project "$ACTION"
        ;;
esac

echo ""
echo -e "${GREEN}Deploy complete.${NC}"
