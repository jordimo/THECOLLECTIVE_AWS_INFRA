#!/bin/bash
# =============================================================================
# Initialize a new project
# =============================================================================
# Works on any environment: local dev, DO (isidora), AWS (aws01).
#
# Usage:
#   ./init-project.sh <name> <git-repo-url> [--target <local|do|aws>]
#
# Examples:
#   ./init-project.sh acme git@github.com:jordimo/Acme.git --target do
#   ./init-project.sh acme git@github.com:jordimo/Acme.git --target local
#   ./init-project.sh acme git@github.com:jordimo/Acme.git --target aws
#
# What it does:
#   1. Creates a PostgreSQL database
#   2. Clones the repo (servers) or verifies it exists (local)
#   3. Prompts for .env setup
#   4. Builds and starts containers
#   5. Runs database migrations (if drizzle-kit is available)
#   6. Sets up local dev extras (mkcert, /etc/hosts, Traefik routing)
#
# Prerequisites:
#   - Infrastructure running (Traefik, Postgres, Redis on 'infra' network)
#   - For servers: SSH alias configured (isidora, aws01)
#   - For servers: deploy key added to the GitHub repo
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${CYAN}▸${NC} $1"; }
ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}!${NC} $1"; }
fail()  { echo -e "${RED}✗${NC} $1"; exit 1; }

usage() {
    echo "Usage: ./init-project.sh <name> <git-repo-url> [--target <local|do|aws>]"
    echo ""
    echo "Targets:"
    echo "  local   Local dev (default)"
    echo "  do      DigitalOcean (isidora)"
    echo "  aws     AWS (aws01)"
    exit 1
}

# ---- Parse args ----
[[ $# -lt 2 ]] && usage

NAME="$1"
REPO_URL="$2"
shift 2

TARGET="local"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

# ---- Environment config ----
case "$TARGET" in
    local)
        REMOTE=""
        PROJECT_DIR="$HOME/Dev/${NAME}"
        COMPOSE_FILE="docker-compose.yml"
        DOMAIN="${NAME}.local"
        LOCAL_INFRA_DIR="$HOME/Dev/local-infra"
        ;;
    do)
        REMOTE="isidora"
        PROJECT_DIR="/home/deploy/${NAME}"
        COMPOSE_FILE="docker-compose.prod.yml"
        DOMAIN="${NAME}.lostriver.llc"
        ;;
    aws)
        REMOTE="aws01"
        PROJECT_DIR="/app/${NAME}"
        COMPOSE_FILE="docker-compose.prod.yml"
        DOMAIN=""
        ;;
    *)
        fail "Unknown target: ${TARGET}. Use local, do, or aws."
        ;;
esac

run() {
    if [ -n "$REMOTE" ]; then
        ssh "$REMOTE" "$@"
    else
        eval "$@"
    fi
}

echo ""
echo -e "${CYAN}=== Initializing '${NAME}' on ${TARGET} ===${NC}"
echo ""

# ---------------------------------------------------------------------------
# 1. Create database
# ---------------------------------------------------------------------------
info "Checking database '${NAME}'..."
DB_EXISTS=$(run "docker exec postgres psql -U postgres -tAc \"SELECT 1 FROM pg_database WHERE datname = '${NAME}'\"" 2>/dev/null || true)

if [ "$DB_EXISTS" = "1" ]; then
    ok "Database '${NAME}' already exists"
else
    run "docker exec postgres psql -U postgres -c 'CREATE DATABASE \"${NAME}\";'" >/dev/null
    ok "Database '${NAME}' created"
fi

# ---------------------------------------------------------------------------
# 2. Clone repo (servers) or verify it exists (local)
# ---------------------------------------------------------------------------
if [ -n "$REMOTE" ]; then
    info "Cloning repo on ${TARGET}..."
    if run "test -d ${PROJECT_DIR}"; then
        ok "Directory ${PROJECT_DIR} already exists — skipping clone"
    else
        run "git clone ${REPO_URL} ${PROJECT_DIR}"
        ok "Cloned to ${PROJECT_DIR}"
    fi
else
    info "Checking local project directory..."
    if [ -d "$PROJECT_DIR" ]; then
        ok "Project exists at ${PROJECT_DIR}"
    else
        fail "Project not found at ${PROJECT_DIR}. Clone it first: git clone ${REPO_URL} ${PROJECT_DIR}"
    fi
fi

# ---------------------------------------------------------------------------
# 3. Set up .env
# ---------------------------------------------------------------------------
info "Checking .env..."
if run "test -f ${PROJECT_DIR}/.env"; then
    ok ".env file exists"
else
    if run "test -f ${PROJECT_DIR}/.env.example"; then
        info "Creating .env from .env.example..."
        run "cp ${PROJECT_DIR}/.env.example ${PROJECT_DIR}/.env"
        warn ".env created from template — edit it with the right values:"
        if [ -n "$REMOTE" ]; then
            echo "    ssh ${REMOTE} 'nano ${PROJECT_DIR}/.env'"
        else
            echo "    nano ${PROJECT_DIR}/.env"
        fi
    else
        warn "No .env or .env.example found at ${PROJECT_DIR}"
        echo "    Create .env before continuing."
    fi
    echo ""
    read -rp "  Press Enter when .env is ready (or Ctrl+C to abort)..."

    if ! run "test -f ${PROJECT_DIR}/.env"; then
        fail ".env still not found."
    fi
    ok ".env file ready"
fi

# ---------------------------------------------------------------------------
# 4. Local dev extras
# ---------------------------------------------------------------------------
if [ "$TARGET" = "local" ]; then
    # mkcert certificate
    info "Checking TLS certificate for ${DOMAIN}..."
    CERT_DIR="${LOCAL_INFRA_DIR}/certs"
    if [ -f "${CERT_DIR}/${NAME}.pem" ]; then
        ok "Certificate exists"
    else
        if command -v mkcert &>/dev/null; then
            mkcert -cert-file "${CERT_DIR}/${NAME}.pem" -key-file "${CERT_DIR}/${NAME}-key.pem" "${DOMAIN}"
            ok "Certificate created for ${DOMAIN}"
        else
            warn "mkcert not installed — install it: brew install mkcert"
        fi
    fi

    # Add certificate to Traefik TLS config
    TLS_FILE="${LOCAL_INFRA_DIR}/dynamic/tls.yml"
    if [ -f "$TLS_FILE" ] && ! grep -q "${NAME}.pem" "$TLS_FILE"; then
        info "Adding certificate to Traefik TLS config..."
        cat >> "$TLS_FILE" <<TLSEOF

    - certFile: /etc/traefik/certs/${NAME}.pem
      keyFile: /etc/traefik/certs/${NAME}-key.pem
TLSEOF
        ok "Certificate added to tls.yml"
    fi

    # Traefik routing config
    ROUTING_FILE="${LOCAL_INFRA_DIR}/dynamic/${NAME}.yml"
    if [ -f "$ROUTING_FILE" ]; then
        ok "Traefik routing already configured"
    else
        info "Creating Traefik routing for ${DOMAIN}..."
        cat > "$ROUTING_FILE" <<ROUTEEOF
http:
  routers:
    ${NAME}-http:
      rule: "Host(\`${DOMAIN}\`)"
      entryPoints:
        - web
      middlewares:
        - redirect-to-https
      service: ${NAME}-web

    ${NAME}-api:
      rule: "Host(\`${DOMAIN}\`) && PathPrefix(\`/api\`)"
      entryPoints:
        - websecure
      service: ${NAME}-api
      tls: {}
      priority: 200

    ${NAME}-web:
      rule: "Host(\`${DOMAIN}\`)"
      entryPoints:
        - websecure
      service: ${NAME}-web
      tls: {}
      priority: 100

  services:
    ${NAME}-api:
      loadBalancer:
        servers:
          - url: "http://${NAME}-api:3000"

    ${NAME}-web:
      loadBalancer:
        servers:
          - url: "http://${NAME}-web:5173"
ROUTEEOF
        ok "Routing created: https://${DOMAIN}"
    fi

    # /etc/hosts entry
    if grep -q "${DOMAIN}" /etc/hosts; then
        ok "/etc/hosts entry exists"
    else
        info "Adding ${DOMAIN} to /etc/hosts (requires sudo)..."
        echo "127.0.0.1 ${DOMAIN}" | sudo tee -a /etc/hosts >/dev/null
        ok "Added ${DOMAIN} to /etc/hosts"
    fi
fi

# ---------------------------------------------------------------------------
# 5. DNS reminder (DO only)
# ---------------------------------------------------------------------------
if [ "$TARGET" = "do" ] && [ -n "$DOMAIN" ]; then
    echo ""
    warn "DNS: Add an A record in Cloudflare:"
    echo "    ${DOMAIN} → 174.138.33.106"
    echo ""
    read -rp "  Press Enter when DNS is configured (or Ctrl+C to skip)..."
fi

# ---------------------------------------------------------------------------
# 6. Build and start containers
# ---------------------------------------------------------------------------
info "Building and starting containers..."
run "cd ${PROJECT_DIR} && docker compose -f ${COMPOSE_FILE} up -d --build"
ok "Containers running"

# ---------------------------------------------------------------------------
# 7. Run migrations (if drizzle-kit available)
# ---------------------------------------------------------------------------
info "Checking for migrations..."
if run "docker exec ${NAME}-api which npx" &>/dev/null; then
    info "Running drizzle-kit migrations..."
    run "docker exec -w /app/apps/api ${NAME}-api npx drizzle-kit migrate" 2>&1 || warn "Migrations failed — you may need to run them manually"
    ok "Migrations applied"
else
    warn "No npx in ${NAME}-api container — run migrations manually if needed"
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}=== '${NAME}' initialized on ${TARGET} ===${NC}"
echo ""

case "$TARGET" in
    local)
        echo "  URL: https://${DOMAIN}"
        echo "  API: https://${DOMAIN}/api"
        ;;
    do)
        echo "  URL: https://${DOMAIN}"
        echo "  API: https://${DOMAIN}/api"
        echo "  Deploy: ./deploy.sh do ${NAME}"
        ;;
    aws)
        echo "  URL: http://52.72.211.242/${NAME}"
        echo "  API: http://52.72.211.242/${NAME}/api"
        echo "  Deploy: ./deploy.sh aws ${NAME}"
        ;;
esac

echo ""
echo "  Next steps:"
echo "    - Set up Langfuse: ssh -L 3030:localhost:3030 ${REMOTE:-localhost}"
echo "      Create project '${NAME}' → Settings → API Keys → copy to .env"
echo "    - Store secrets in Bitwarden"
echo ""
