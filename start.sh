#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Check .env exists
if [ ! -f .env ]; then
    echo "No .env file found."
    echo ""
    echo "  cp .env.example .env"
    echo ""
    exit 1
fi

# Detect profile
PROFILE_FLAG=""
if grep -q '^COMPOSE_PROFILES=.*local' .env 2>/dev/null; then
    PROFILE_FLAG="--profile local"
fi

# ---------------------------------------------------------------------------
# Local dev: ensure .local domains for infra services
# ---------------------------------------------------------------------------
if grep -q '^COMPOSE_PROFILES=.*local' .env 2>/dev/null; then
    # Infra services that need .local domains
    # Format: name:domain (cert files use the name, not the domain)
    INFRA_DOMAINS=(
        "langfuse:langfuse.local"
        "analytics:analytics.local"
    )

    for entry in "${INFRA_DOMAINS[@]}"; do
        CERT_NAME="${entry%%:*}"
        DOMAIN="${entry##*:}"

        # /etc/hosts
        if ! grep -q "$DOMAIN" /etc/hosts; then
            echo "Adding $DOMAIN to /etc/hosts (requires sudo)..."
            echo "127.0.0.1 $DOMAIN" | sudo tee -a /etc/hosts >/dev/null
        fi

        # mkcert certificate
        if [ ! -f "certs/${CERT_NAME}.pem" ]; then
            if command -v mkcert &>/dev/null; then
                mkcert -cert-file "certs/${CERT_NAME}.pem" -key-file "certs/${CERT_NAME}-key.pem" "$DOMAIN"
            else
                echo "Warning: mkcert not installed — install with: brew install mkcert"
            fi
        fi
    done
fi

echo "Starting infrastructure..."
docker compose $PROFILE_FLAG up -d

# Show what's running
echo ""
echo "Running:"
echo "  Traefik dashboard: http://localhost:8080"
echo "  PostgreSQL:        localhost:5432"
echo "  Redis:             localhost:6379"
if grep -q '^COMPOSE_PROFILES=.*local' .env 2>/dev/null; then
    echo "  Langfuse:          https://langfuse.local   (admin@local.dev / adminadmin)"
    echo "  Umami:             https://analytics.local  (admin / umami)"
    echo "  Mailpit:           http://localhost:8025"
else
    echo "  Langfuse:          http://localhost:3030"
    echo "  Umami:             http://localhost:3040"
fi
echo ""
echo "Add projects with: ./init-project.sh <name> --target local --dir <path>"
echo ""
