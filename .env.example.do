# =============================================================================
# Infrastructure .env — DigitalOcean (isidora)
# =============================================================================
# Copy to .env: cp .env.example.do .env
# On existing volumes, POSTGRES_USER/POSTGRES_PASSWORD are for documentation
# only — auth is controlled by the data directory, not these env vars.
# =============================================================================

# --- Traefik ---
TRAEFIK_INSECURE=true
TRAEFIK_DASHBOARD_BIND=127.0.0.1
ACME_EMAIL=jordi@lostriver.llc

# --- Postgres ---
POSTGRES_USER=postgres
POSTGRES_PASSWORD=
POSTGRES_BIND=127.0.0.1
POSTGRES_VOLUME=caitie_postgres_data

# --- Redis ---
REDIS_ARGS=--requirepass CHANGE_ME --maxmemory 512mb --maxmemory-policy noeviction
REDIS_HEALTHCHECK_ARGS=-a CHANGE_ME
REDIS_BIND=127.0.0.1
REDIS_VOLUME=caitie_redis_data

# --- Langfuse ---
# Generate secrets: openssl rand -base64 32
LANGFUSE_SECRET=
LANGFUSE_SALT=
LANGFUSE_URL=http://localhost:3030
LANGFUSE_BIND=127.0.0.1
LANGFUSE_TRAEFIK=false

# --- Umami ---
# Generate secret: openssl rand -base64 32
UMAMI_SECRET=
UMAMI_BIND=127.0.0.1
UMAMI_TRAEFIK=true
UMAMI_DOMAIN=analytics.lostriver.llc
UMAMI_TLS=true
UMAMI_CERTRESOLVER=letsencrypt

# --- Volumes (preserve existing DO data) ---
TRAEFIK_VOLUME=caitie_traefik_letsencrypt
