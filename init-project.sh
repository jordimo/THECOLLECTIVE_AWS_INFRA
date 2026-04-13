#!/bin/bash
# =============================================================================
# Initialize a project on THECOLLECTIVE_AWS01
# =============================================================================
# Run from the corporate laptop (VPN connected).
#
# Usage:
#   ./init-project.sh <name> <git-repo-url> [--api <port>] [--web <port>]
#
# Examples:
#   ./init-project.sh marie git@github.com:jordimo/Marie.git
#   ./init-project.sh betty git@github.com:jordimo/Betty.git --api 3000 --web 3001
#
# What it does:
#   1. Clones the repo to /app/<name> on the VM
#   2. Creates a PostgreSQL database named <name>
#   3. Registers Traefik routing via project.sh
#   4. Builds and starts containers (docker-compose.vm.yml)
#   5. Runs database migrations (drizzle-kit)
#   6. Prompts to create a SUPER_ADMIN user
#
# Prerequisites:
#   - VPN connected, SSH alias 'aws01' configured
#   - Deploy key added to the GitHub repo
#   - Infrastructure running (./start.sh)
#   - .env file will need to be created on the VM before step 4
# =============================================================================

set -euo pipefail

VM="${VM:-aws01}"
VM_APP_DIR="/app"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}▸${NC} $1"; }
ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}!${NC} $1"; }
fail()  { echo -e "${RED}✗${NC} $1"; exit 1; }

ssh_cmd() { ssh "$VM" "$@"; }

usage() {
    echo "Usage: ./init-project.sh <name> <git-repo-url> [--api <port>] [--web <port>]"
    exit 1
}

# ---- Parse args ----
[[ $# -lt 2 ]] && usage

NAME="$1"
REPO_URL="$2"
shift 2

API_PORT="3000"
WEB_PORT="3001"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --api) API_PORT="$2"; shift 2 ;;
        --web) WEB_PORT="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

PROJECT_DIR="${VM_APP_DIR}/${NAME}"

echo ""
echo -e "${CYAN}=== Initializing '${NAME}' on THECOLLECTIVE_AWS01 ===${NC}"
echo ""

# ---------------------------------------------------------------------------
# 1. Clone repo
# ---------------------------------------------------------------------------
info "Cloning repo..."
if ssh_cmd "test -d ${PROJECT_DIR}"; then
    ok "Directory ${PROJECT_DIR} already exists — skipping clone"
else
    ssh_cmd "git clone ${REPO_URL} ${PROJECT_DIR}"
    ok "Cloned to ${PROJECT_DIR}"
fi

# ---------------------------------------------------------------------------
# 2. Create database
# ---------------------------------------------------------------------------
info "Checking database '${NAME}'..."
DB_EXISTS=$(ssh_cmd "docker exec postgres psql -U postgres -tAc \"SELECT 1 FROM pg_database WHERE datname = '${NAME}'\"" 2>/dev/null || true)

if [ "$DB_EXISTS" = "1" ]; then
    ok "Database '${NAME}' already exists"
else
    ssh_cmd "docker exec postgres psql -U postgres -c 'CREATE DATABASE \"${NAME}\";'" >/dev/null
    ok "Database '${NAME}' created"
fi

# ---------------------------------------------------------------------------
# 3. Set up .env
# ---------------------------------------------------------------------------
if ssh_cmd "test -f ${PROJECT_DIR}/.env"; then
    ok ".env file exists"
else
    warn ".env file not found at ${PROJECT_DIR}/.env"
    echo ""
    echo "  Create it now. A template is available at ${PROJECT_DIR}/.env.example.vm"
    echo ""
    echo "  Option A — edit on the VM:"
    echo "    ssh ${VM} 'micro ${PROJECT_DIR}/.env'"
    echo ""
    echo "  Option B — push from here:"
    echo "    ssh ${VM} 'cat > ${PROJECT_DIR}/.env << EOF"
    echo "    ...paste values..."
    echo "    EOF'"
    echo ""
    read -rp "  Press Enter when .env is ready (or Ctrl+C to abort)..."

    if ! ssh_cmd "test -f ${PROJECT_DIR}/.env"; then
        fail ".env still not found. Create it and re-run this script."
    fi
    ok ".env file created"
fi

# ---------------------------------------------------------------------------
# 4. Register Traefik routing
# ---------------------------------------------------------------------------
info "Registering Traefik routing..."
DYNAMIC_FILE="${VM_APP_DIR}/Deployer/traefik/dynamic/${NAME}.yml"

if ssh_cmd "test -f ${DYNAMIC_FILE}"; then
    ok "Routing already registered"
else
    ssh_cmd "cd ${VM_APP_DIR}/Deployer && ./project.sh add ${NAME} --api ${API_PORT} --web ${WEB_PORT}"
    ok "Routing registered: /${NAME} -> web, /${NAME}/api -> api"
fi

# ---------------------------------------------------------------------------
# 5. Build and start containers
# ---------------------------------------------------------------------------
info "Building and starting containers..."
ssh_cmd "cd ${PROJECT_DIR} && docker compose -f docker-compose.vm.yml up -d --build"
ok "Containers running"

# ---------------------------------------------------------------------------
# 6. Run migrations
# ---------------------------------------------------------------------------
info "Running database migrations..."
ssh_cmd "docker exec -w /app/apps/api ${NAME}-api npx drizzle-kit migrate" 2>&1
ok "Migrations applied"

# ---------------------------------------------------------------------------
# 7. Create admin user (optional)
# ---------------------------------------------------------------------------
echo ""
USER_COUNT=$(ssh_cmd "docker exec postgres psql -U postgres -d ${NAME} -tAc 'SELECT count(*) FROM users'" 2>/dev/null || echo "error")

if [ "$USER_COUNT" = "error" ]; then
    warn "Could not check users table — it may not exist yet. Skipping admin creation."
elif [ "$USER_COUNT" -gt 0 ] 2>/dev/null; then
    ok "Users already exist (${USER_COUNT} found) — skipping admin creation"
else
    echo -e "${CYAN}No users found — let's create the first SUPER_ADMIN.${NC}"
    echo ""

    read -rp "  Admin email: " ADMIN_EMAIL
    read -rp "  Admin name:  " ADMIN_NAME

    while true; do
        read -rsp "  Password (min 8 chars, upper+lower+digit): " ADMIN_PASSWORD
        echo ""
        if [ ${#ADMIN_PASSWORD} -lt 8 ]; then
            warn "Password must be at least 8 characters"; continue
        fi
        if ! (echo "$ADMIN_PASSWORD" | grep -q '[a-z]' && \
             echo "$ADMIN_PASSWORD" | grep -q '[A-Z]' && \
             echo "$ADMIN_PASSWORD" | grep -q '[0-9]'); then
            warn "Password must contain uppercase, lowercase, and a digit"; continue
        fi
        break
    done

    # Hash password and create user inside the API container
    ssh_cmd "docker exec ${NAME}-api node -e \"
        const bcrypt = require('bcrypt');
        const crypto = require('crypto');
        const { Client } = require('pg');
        (async () => {
            const hash = await bcrypt.hash(process.argv[1], 12);
            const tenantId = crypto.randomUUID();
            const userId = crypto.randomUUID();
            const client = new Client({ connectionString: process.env.DATABASE_URL });
            await client.connect();
            await client.query('BEGIN');
            await client.query(\\\"INSERT INTO tenants (id, name, slug) VALUES (\\\$1, 'The Collective', 'default')\\\", [tenantId]);
            await client.query(\\\"INSERT INTO users (id, tenant_id, email, name, password_hash, auth_provider, role) VALUES (\\\$1, \\\$2, \\\$3, \\\$4, \\\$5, 'LOCAL', 'SUPER_ADMIN')\\\", [userId, tenantId, process.argv[2], process.argv[3], hash]);
            await client.query('COMMIT');
            await client.end();
            console.log('Admin created: ' + process.argv[2]);
        })().catch(e => { console.error(e.message); process.exit(1); });
    \" '${ADMIN_PASSWORD}' '${ADMIN_EMAIL}' '${ADMIN_NAME}'"

    ok "SUPER_ADMIN user created: ${ADMIN_EMAIL}"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}=== '${NAME}' initialized ===${NC}"
echo ""
echo "  Web: http://52.72.211.242/${NAME}"
echo "  API: http://52.72.211.242/${NAME}/api"
echo ""
echo "  Deploy updates:  ./deploy.sh ${NAME}"
echo ""
