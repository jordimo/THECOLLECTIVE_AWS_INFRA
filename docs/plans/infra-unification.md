# Infra Unification Plan

## Problem

Three environments with different conventions:

| | Local | AWS | DO |
|---|---|---|---|
| Compose | `docker-compose.yml` | `docker-compose.vm.yml` | `docker-compose.do.yml` |
| Network | `local-dev` | `traefik-public` | `caitie-infra_traefik` |
| Routing | Host (`marie.local`) | Path (`/marie`) | Host (`marie.lostriver.llc`) |
| Traefik | File provider | File provider | Docker labels |
| TLS | mkcert | None | Let's Encrypt |
| DB container | `local_postgres` | `postgres` | `caitie_postgres_1` |
| Infra location | `~/Dev/local-infra` | `/app/Deployer` | `/home/deploy/caitie/infrastructure` |

3 compose files + 3 env templates per project. Unsustainable.

## Target state

### Naming conventions (everywhere)

| Thing | Convention | Examples |
|---|---|---|
| Network | `infra` | Same on local, DO, AWS |
| Postgres container | `postgres` | Not `local_postgres`, not `caitie_postgres_1` |
| Redis container | `redis` | Not `local_redis`, not `caitie_redis_1` |
| Traefik container | `traefik` | Not `local_traefik`, not `caitie_traefik_1` |
| Project containers | `{project}-{service}` | `marie-api`, `marie-web` |
| DB name | `{project}` | `marie`, `newsintel` |
| Repo name | `{Project}` | `jordimo/Marie` |
| Compose (dev) | `docker-compose.yml` | Hot reload, volume mounts |
| Compose (prod) | `docker-compose.prod.yml` | Production builds, Traefik labels |
| Env template | `.env.example` | One template, env vars control differences |
| Infra repo | `jordimo/infra` | Server-agnostic, works for any target |

### Routing (everywhere)

Host-based routing with Docker labels on all environments:

- **Local:** `marie.local` (mkcert TLS)
- **DO:** `marie.lostriver.llc` (Let's Encrypt)
- **AWS:** `marie.<aws-domain>` or `nip.io` fallback (Let's Encrypt once IT enables 443)

No more path-based routing. No more file provider configs.

### Two compose files per project

**`docker-compose.yml`** — local dev only:
```yaml
name: marie

services:
  api:
    build:
      context: .
      dockerfile: apps/api/Dockerfile
      target: development
    container_name: marie-api
    env_file: .env
    volumes:
      - ./apps/api/src:/app/apps/api/src
      - ./packages/shared/src:/app/packages/shared/src
      - ./packages/shared/dist:/app/packages/shared/dist
    networks:
      - infra

  web:
    build:
      context: .
      dockerfile: apps/web/Dockerfile
      target: development
    container_name: marie-web
    volumes:
      - ./apps/web/src:/app/apps/web/src
      - ./packages/shared/src:/app/packages/shared/src
      - ./packages/shared/dist:/app/packages/shared/dist
    networks:
      - infra

networks:
  infra:
    external: true
```

**`docker-compose.prod.yml`** — any server (DO, AWS, future):
```yaml
name: marie

services:
  api:
    build:
      context: .
      dockerfile: apps/api/Dockerfile
      target: production
    container_name: marie-api
    restart: unless-stopped
    env_file: .env
    environment:
      - NODE_ENV=production
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:3000/api/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 15s
    networks:
      - infra
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.marie-api.rule=Host(`${DOMAIN}`) && PathPrefix(`/api`)"
      - "traefik.http.routers.marie-api.entrypoints=websecure"
      - "traefik.http.routers.marie-api.tls.certresolver=letsencrypt"
      - "traefik.http.routers.marie-api.priority=200"
      - "traefik.http.services.marie-api.loadbalancer.server.port=3000"

  web:
    build:
      context: .
      dockerfile: apps/web/Dockerfile
      target: production
    container_name: marie-web
    restart: unless-stopped
    environment:
      - VITE_API_URL=https://${DOMAIN}/api
    healthcheck:
      test: ["CMD", "node", "-e", "fetch('http://localhost:3001').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"]
      interval: 30s
      timeout: 5s
      retries: 3
    networks:
      - infra
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.marie-web.rule=Host(`${DOMAIN}`)"
      - "traefik.http.routers.marie-web.entrypoints=websecure"
      - "traefik.http.routers.marie-web.tls.certresolver=letsencrypt"
      - "traefik.http.routers.marie-web.priority=100"
      - "traefik.http.services.marie-web.loadbalancer.server.port=3001"
      # HTTP -> HTTPS redirect
      - "traefik.http.routers.marie-redirect.rule=Host(`${DOMAIN}`)"
      - "traefik.http.routers.marie-redirect.entrypoints=web"
      - "traefik.http.routers.marie-redirect.middlewares=marie-https-redirect@docker"
      - "traefik.http.middlewares.marie-https-redirect.redirectscheme.scheme=https"
      - "traefik.http.middlewares.marie-https-redirect.redirectscheme.permanent=true"

networks:
  infra:
    external: true
```

### One `.env.example` per project

```env
# --- Server-specific (set per environment) ---
DOMAIN=marie.local
DATABASE_URL=postgresql://postgres:postgres@postgres:5432/marie

# --- Project-specific (same everywhere) ---
JWT_SECRET=
OPENAI_API_KEY=
# ...etc
```

Each server has its own `.env` with the right `DOMAIN` and `DATABASE_URL`. Everything else is the same.

### One infra compose (all environments)

```yaml
services:
  traefik:
    image: traefik:v3.2
    container_name: traefik
    # ...

  postgres:
    image: pgvector/pgvector:pg16
    container_name: postgres
    # ...

  redis:
    image: redis:7-alpine
    container_name: redis
    # ...

  langfuse:
    image: langfuse/langfuse:2
    container_name: langfuse
    # Port 3030 exposed, access via SSH tunnel on servers
    # or https://langfuse.local on dev
    # ...

networks:
  infra:
    name: infra
    driver: bridge
```

Same file on local, DO, AWS. Only difference is `.env` (Postgres password, TLS config, Langfuse secrets).

**Shared services available to all projects:**

| Service | From containers | From host (dev) | From host (server) |
|---|---|---|---|
| Postgres | `postgres:5432` | `localhost:5432` | Internal only |
| Redis | `redis:6379` | `localhost:6379` | Internal only |
| Langfuse | `langfuse:3000` | `https://langfuse.local` | SSH tunnel `localhost:3030` |
| Traefik | N/A | `https://*.local` | Ports 80/443 |

Projects connect to Langfuse via `LANGFUSE_BASE_URL`:
- **Local:** `https://langfuse.local` or `http://langfuse:3000`
- **Servers:** `http://langfuse:3000` (internal Docker network, no tunnel needed from containers)

### Deploy script with targets

```bash
./deploy.sh <target> <project>
./deploy.sh do marie
./deploy.sh aws marie
./deploy.sh do --all
```

Targets configured via SSH aliases — deploy script doesn't know about IPs or keys:

```
# ~/.ssh/config (corporate laptop)
Host do
    HostName 174.138.33.106
    User deploy
    IdentityFile ~/.ssh/do_isidora

Host aws
    HostName 10.251.8.172
    User ubuntu
    IdentityFile ~/.ssh/AWSNMTNAPP001-keypair.pem
```

## Migration plan

### Constraint: DO data must not be lost

Postgres data lives in Docker volumes. Renaming containers or networks does not touch volumes. The migration is safe as long as we don't `docker compose down -v` (which removes volumes).

### Steps

#### Phase 1: Local dev (no risk)

1. Rename `local-dev` network to `infra` in local-infra
2. Rename containers: `local_postgres` → `postgres`, `local_redis` → `redis`, `local_traefik` → `traefik`
3. Update all project `docker-compose.yml` files to use `infra` network
4. Rebuild local infra from scratch (no persistent data concerns on dev)

#### Phase 2: AWS (low risk, currently broken anyway)

1. Rename `traefik-public` → `infra`
2. Switch from file provider to Docker labels
3. Keep path-based routing for now — no domain, IP-only access via corporate VPN
4. Traefik needs both `web` and `websecure` entrypoints but no Let's Encrypt (internal only)
5. Projects use `docker-compose.prod.yml` with AWS-specific `.env` (`DOMAIN` not used, path routing via override labels)
6. Replace `docker-compose.vm.yml` with `docker-compose.prod.yml` in Marie

#### Phase 3: DO (careful, has production data)

**Projects to migrate:** marie, caitie, newsintel, company-intel, vaultwarden

**Data safety:** Postgres data lives in Docker volumes. Renaming containers or networks does NOT touch volumes. The only destructive command is `docker compose down -v` — NEVER run that. Verify with `docker volume ls` before and after each step.

1. **Backup first**
   - `docker exec caitie_postgres_1 pg_dumpall -U caitie_admin_db > /home/deploy/backup_$(date +%Y%m%d).sql`
   - Verify backup file is non-empty

2. **Create `infra` network alongside existing ones**
   - `docker network create infra`
   - Both old (`caitie-infra_traefik`, `caitie-infra_shared_services`) and new (`infra`) coexist

3. **Deploy new infra compose**
   - New Traefik, Postgres, Redis with standardized names on `infra` network
   - New Postgres mounts the SAME volume as old one — data persists
   - Verify: `docker exec postgres psql -U caitie_admin_db -d caitie_db -c "SELECT count(*) FROM users"`

4. **Migrate projects one at a time (safest order: marie first, caitie last)**
   a. Stop project: `docker compose -f docker-compose.do.yml down` (NO `-v` flag)
   b. Switch to `docker-compose.prod.yml` + new `.env`
   c. Start: `docker compose -f docker-compose.prod.yml up -d --build`
   d. Verify the app works
   e. Move to next project

5. **Once all projects migrated**
   - Stop old infra containers
   - Remove old networks (`caitie-infra_traefik`, `caitie-infra_shared_services`)
   - Remove old infra compose

6. **Postgres user migration (optional, later)**
   - Currently `caitie_admin_db` — rename to `postgres` for consistency
   - This requires updating DATABASE_URL in every project's `.env`
   - Do this LAST, after everything else is stable

#### Phase 4: Cleanup

1. Remove `docker-compose.vm.yml`, `docker-compose.do.yml`, `.env.example.vm`, `.env.example.do` from all projects
2. Remove `project.sh` and dynamic Traefik config files from infra repo
3. Rename GitHub repo: `jordimo/THECOLLECTIVE_AWS_INFRA` → `jordimo/infra`
4. Update all docs and README files
5. Update memory files

### Standard project scripts

**Convention:** All scripts are `.sh` files that run from the command line on the host. If a script needs Node/Python internals (e.g. bcrypt for password hashing), the `.sh` script handles `docker exec` internally — the user never touches `.js` files directly.

Every project must include:

#### `scripts/start.sh`

Start the project. Detects environment automatically:

```bash
#!/bin/bash
set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

if [ -f docker-compose.prod.yml ] && [ "${NODE_ENV:-}" = "production" ]; then
    docker compose -f docker-compose.prod.yml up -d --build
else
    docker compose up -d --build
fi
```

Usage:
```bash
./scripts/start.sh              # local dev
NODE_ENV=production ./scripts/start.sh  # production server
```

#### `scripts/stop.sh`

```bash
#!/bin/bash
set -e
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ -f docker-compose.prod.yml ] && [ "${NODE_ENV:-}" = "production" ]; then
    docker compose -f docker-compose.prod.yml down
else
    docker compose down
fi
```

#### `scripts/create-admin.sh`

Interactive — prompts for email, name, password. Idempotent (skips if users exist). Runs from the host, executes inside the API container:

```bash
#!/bin/bash
set -e
PROJECT=$(basename "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)")
CONTAINER="${PROJECT}-api"

# Check container is running
if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
    echo "Error: ${CONTAINER} is not running. Start the project first."
    exit 1
fi

# Prompt for details
read -rp "Admin email: " EMAIL
read -rp "Admin name: " NAME
read -rsp "Password (min 8 chars): " PASSWORD
echo ""

# Run inside the container — JS is an implementation detail
docker exec -i "$CONTAINER" node -e "
const bcrypt = require('bcrypt');
const crypto = require('crypto');
const { Client } = require('pg');
(async () => {
  const client = new Client({ connectionString: process.env.DATABASE_URL });
  await client.connect();
  const existing = await client.query('SELECT count(*) FROM users');
  if (parseInt(existing.rows[0].count) > 0) {
    console.log('Users already exist (' + existing.rows[0].count + ' found). Skipping.');
    await client.end();
    return;
  }
  const hash = await bcrypt.hash(process.argv[1], 12);
  const tid = crypto.randomUUID();
  await client.query('BEGIN');
  await client.query(\"INSERT INTO tenants (id, name, slug) VALUES (\\\$1, 'The Collective', 'default')\", [tid]);
  await client.query(\"INSERT INTO users (id, tenant_id, email, name, password_hash, auth_provider, role) VALUES (\\\$1,\\\$2,\\\$3,\\\$4,\\\$5,'LOCAL','SUPER_ADMIN')\",
    [crypto.randomUUID(), tid, process.argv[2], process.argv[3], hash]);
  await client.query('COMMIT');
  await client.end();
  console.log('Admin created: ' + process.argv[2]);
})().catch(e => { console.error(e.message); process.exit(1); });
" "$PASSWORD" "$EMAIL" "$NAME"
```

Usage:
```bash
./scripts/create-admin.sh
# Admin email: jordi@lostriver.llc
# Admin name: Jordi
# Password: ********
# Admin created: jordi@lostriver.llc
```

#### `scripts/migrate.sh`

```bash
#!/bin/bash
set -e
PROJECT=$(basename "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)")
docker exec -w /app/apps/api "${PROJECT}-api" npx drizzle-kit migrate
```

#### `scripts/setup-env.sh`

Interactive `.env` generator (see `.env` management section below).

### `.env` management

**Problem:** Setting up `.env` on a new server is manual, error-prone, and requires copy-pasting from Bitwarden.

**Solution:** One `.env.example` with clear sections:

```env
# =============================================================================
# Environment-specific — CHANGE THESE PER SERVER
# =============================================================================
DOMAIN=marie.local
DATABASE_URL=postgresql://postgres:postgres@postgres:5432/marie
FRONTEND_URL=https://${DOMAIN}
ENTRA_REDIRECT_URI=https://${DOMAIN}/api/auth/entra/callback

# =============================================================================
# Secrets — GENERATE ONCE, STORE IN BITWARDEN
# =============================================================================
JWT_SECRET=
OPENAI_API_KEY=
ENTRA_CLIENT_ID=
ENTRA_CLIENT_SECRET=
ENTRA_TENANT_ID=

# =============================================================================
# Defaults — USUALLY DON'T CHANGE
# =============================================================================
JWT_EXPIRES_IN_SECONDS=604800
PORT=3000
NODE_ENV=production
NOTIFICATIONS_ENABLED=false
LANGFUSE_BASE_URL=https://cloud.langfuse.com
LANGFUSE_SECRET_KEY=
LANGFUSE_PUBLIC_KEY=
RESEND_API_KEY=
RESEND_FROM_ADDRESS=Marie <onboarding@resend.dev>
```

**Key ideas:**
- Three clear sections: environment-specific, secrets, defaults
- `DOMAIN` is the single variable that drives routing, frontend URL, and callback URLs
- `FRONTEND_URL` and `ENTRA_REDIRECT_URI` reference `${DOMAIN}` in the example so you see the pattern — but `.env` files don't support variable interpolation, so the actual values must be written out
- Secrets section tells you exactly what to generate/fetch from Bitwarden
- Defaults section rarely changes — copy as-is

**Future improvement:** A `scripts/setup-env.sh` that prompts for the environment-specific values and generates the `.env`:

```bash
./scripts/setup-env.sh
# Domain [marie.local]: marie.lostriver.llc
# Postgres password: ****
# JWT secret (leave blank to generate): 
# OpenAI API key: sk-...
# → .env created
```

## Decisions made

1. **Infra repo name:** `jordimo/infra` — server-agnostic
2. **AWS routing:** stays path-based for now (IP only, no domain, VPN access only)
3. **DO projects:** ALL will be migrated (marie, caitie, newsintel, company-intel, vaultwarden)
4. **DB safety:** pg_dumpall backup before any DO migration work

## Open questions

1. **Local Traefik** — keep file provider for local (mkcert certs need it) or switch to Docker labels too?
2. **Langfuse** — run per-server or use Langfuse Cloud?
3. **Postgres user on DO** — migrate from `caitie_admin_db` to `postgres` or leave as-is?
4. **AWS domain** — if one becomes available later, easy to switch from path-based to host-based
