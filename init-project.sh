#!/bin/bash
# =============================================================================
# Initialize a new project
# =============================================================================
# Works on any environment: local dev, DO (isidora), AWS (aws01).
#
# Usage:
#   ./init-project.sh <name> [options]
#
# Examples:
#   # Local
#   ./init-project.sh acme --target local --dir ~/Dev/THECOLLECTIVE/Acme
#
#   # DO (isidora) — clone from GitHub
#   ./init-project.sh acme --target do:isidora --repo git@github.com:jordimo/Acme.git
#
#   # DO (isidora) — project already on server
#   ./init-project.sh acme --target do:isidora --dir /home/deploy/acme
#
# Options:
#   --target <target>          Required. One of: local, do:<droplet>, aws
#   --dir <path>              Project directory (required for local, optional for servers)
#   --repo <git-url>          Git repo URL (clones if dir doesn't exist)
#   --db <name>               Database name (default: project name)
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

# Where this script lives (= the infra repo)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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
    echo "Usage: ./init-project.sh <name> --target <target> [options]"
    echo ""
    echo "Targets:"
    echo "  local            Local dev"
    echo "  do:<droplet>     DigitalOcean (e.g. do:isidora)"
    echo "  aws              AWS (aws01)"
    echo ""
    echo "Options:"
    echo "  --dir <path>     Project directory (required for local)"
    echo "  --repo <git-url> Git repo URL (clones if dir doesn't exist)"
    echo "  --db <name>      Database name (default: project name)"
    echo ""
    echo "Examples:"
    echo "  ./init-project.sh acme --target local --dir ~/Dev/Acme"
    echo "  ./init-project.sh acme --target do:isidora --repo git@github.com:jordimo/Acme.git"
    exit 1
}

# ---- Parse args ----
[[ $# -lt 1 ]] && usage

NAME="$1"
shift

TARGET=""
PROJECT_DIR=""
REPO_URL=""
DB_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target) TARGET="$2"; shift 2 ;;
        --dir) PROJECT_DIR="$2"; shift 2 ;;
        --repo) REPO_URL="$2"; shift 2 ;;
        --db) DB_NAME="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; usage ;;
    esac
done

[ -z "$TARGET" ] && fail "--target is required (local, do:<droplet>, or aws)"

DB_NAME="${DB_NAME:-$NAME}"

# ---- Environment config ----
case "$TARGET" in
    local)
        REMOTE=""
        COMPOSE_FILE="docker-compose.yml"
        DOMAIN="${NAME}.local"
        if [ -z "$PROJECT_DIR" ]; then
            fail "Local target requires --dir <path> (e.g. --dir ~/Dev/Acme)"
        fi
        ;;
    do:*)
        REMOTE="${TARGET#do:}"
        COMPOSE_FILE="docker-compose.prod.yml"
        DOMAIN="${NAME}.lostriver.llc"
        PROJECT_DIR="${PROJECT_DIR:-/home/deploy/${NAME}}"
        ;;
    aws)
        REMOTE="aws01"
        COMPOSE_FILE="docker-compose.prod.yml"
        DOMAIN=""
        PROJECT_DIR="${PROJECT_DIR:-/app/${NAME}}"
        ;;
    *)
        fail "Unknown target: ${TARGET}. Use local, do:<droplet>, or aws."
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
echo -e "  Directory: ${PROJECT_DIR}"
[ -n "$DOMAIN" ] && echo -e "  Domain:    ${DOMAIN}"
echo -e "  Database:  ${DB_NAME}"
echo ""

# ---------------------------------------------------------------------------
# 1. Create database
# ---------------------------------------------------------------------------
info "Checking database '${DB_NAME}'..."
DB_EXISTS=$(run "docker exec postgres psql -U postgres -tAc \"SELECT 1 FROM pg_database WHERE datname = '${DB_NAME}'\"" 2>/dev/null || true)

if [ "$DB_EXISTS" = "1" ]; then
    ok "Database '${DB_NAME}' already exists"
else
    run "docker exec postgres psql -U postgres -c 'CREATE DATABASE \"${DB_NAME}\";'" >/dev/null
    ok "Database '${DB_NAME}' created"
fi

# ---------------------------------------------------------------------------
# 2. Clone repo or verify it exists
# ---------------------------------------------------------------------------
if [ -n "$REMOTE" ]; then
    if run "test -d ${PROJECT_DIR}"; then
        ok "Directory ${PROJECT_DIR} already exists"
    elif [ -n "$REPO_URL" ]; then
        info "Cloning repo on ${TARGET}..."
        run "git clone ${REPO_URL} ${PROJECT_DIR}"
        ok "Cloned to ${PROJECT_DIR}"
    else
        fail "Directory ${PROJECT_DIR} not found and no --repo provided"
    fi
else
    if [ -d "$PROJECT_DIR" ]; then
        ok "Project exists at ${PROJECT_DIR}"
    elif [ -n "$REPO_URL" ]; then
        info "Cloning repo..."
        git clone "$REPO_URL" "$PROJECT_DIR"
        ok "Cloned to ${PROJECT_DIR}"
    else
        fail "Directory ${PROJECT_DIR} not found. Use --repo to clone or --dir to point to it."
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
    INFRA_DIR="$SCRIPT_DIR"

    # mkcert certificate
    info "Checking TLS certificate for ${DOMAIN}..."
    CERT_DIR="${INFRA_DIR}/certs"
    mkdir -p "$CERT_DIR"
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
    TLS_FILE="${INFRA_DIR}/dynamic/tls.yml"
    if [ -f "$TLS_FILE" ] && ! grep -q "${NAME}.pem" "$TLS_FILE"; then
        info "Adding certificate to Traefik TLS config..."
        cat >> "$TLS_FILE" <<TLSEOF

    - certFile: /etc/traefik/certs/${NAME}.pem
      keyFile: /etc/traefik/certs/${NAME}-key.pem
TLSEOF
        ok "Certificate added to tls.yml"
    elif [ ! -f "$TLS_FILE" ]; then
        info "Creating Traefik TLS config..."
        cat > "$TLS_FILE" <<TLSEOF
tls:
  stores:
    default:
      defaultCertificate:
        certFile: /etc/traefik/certs/${NAME}.pem
        keyFile: /etc/traefik/certs/${NAME}-key.pem

  certificates:
    - certFile: /etc/traefik/certs/${NAME}.pem
      keyFile: /etc/traefik/certs/${NAME}-key.pem
TLSEOF
        ok "TLS config created"
    fi

    # Traefik routing config
    ROUTING_FILE="${INFRA_DIR}/dynamic/routing-${NAME}.yml"
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
    do:*)
        echo "  URL: https://${DOMAIN}"
        echo "  API: https://${DOMAIN}/api"
        echo "  Deploy: ./deploy.sh ${REMOTE} ${NAME}"
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
echo "    - Update registry.yml in docs/plans/infra-unification.md"
echo ""
