# infra

Shared infrastructure for all environments: **DigitalOcean** (isidora), **AWS** (THECOLLECTIVE_AWS01), and **local dev**.

## What this repo provides

Traefik, PostgreSQL (pgvector), Redis, and Langfuse — running on every environment with the same conventions. Projects connect via the `infra` Docker network.

### Shared services

| Service  | From containers     | From host (dev)          | From host (server)              |
|----------|--------------------|--------------------------|---------------------------------|
| Postgres | `postgres:5432`    | `localhost:5432`         | Internal only                   |
| Redis    | `redis:6379`       | `localhost:6379`         | Internal only                   |
| Langfuse | `langfuse:3000`    | `https://langfuse.local` | SSH tunnel `localhost:3030`     |
| Traefik  | N/A                | `https://*.local`        | Ports 80/443                    |

## Repository structure

```
infra/
├── docker-compose.yml        ← DO/server infra (Traefik + Let's Encrypt, pgvector, Redis, Langfuse)
├── .env.example              ← Template for server .env
├── dynamic/                  ← Traefik dynamic config (health checks, security headers)
│   └── dynamic.yml
├── traefik/                  ← AWS-specific infra (path-based routing, no TLS)
│   ├── docker-compose.yml
│   └── dynamic/
├── deploy.sh                 ← Deploy from corporate laptop over SSH
├── init-project.sh           ← First-time project setup on a server
├── project.sh                ← Register/remove Traefik routing (AWS, path-based)
├── bootstrap.sh              ← Bootstrap a fresh VM (Docker, Git, clone)
├── setup.sh / start.sh / stop.sh
└── docs/
    ├── plans/                ← Migration and unification plans
    └── dev-diary/
```

## Environments

### DigitalOcean — isidora (174.138.33.106)

Primary production server. Host-based routing with Let's Encrypt TLS.

```
/home/deploy/
├── infra/                    ← this repo
│   ├── docker-compose.yml
│   ├── .env
│   └── dynamic/
├── marie/                    ← marie.lostriver.llc
├── newsintel/                ← newsintel.lostriver.llc
├── company-intel/            ← intel.lostriver.llc
├── vault/                    ← vault.lostriver.llc
└── caitie/                   ← caitie.app (currently down)
```

**SSH:**
```bash
ssh isidora                            # Shell
ssh -L 3030:localhost:3030 isidora     # Langfuse UI
ssh -L 8080:localhost:8080 isidora     # Traefik dashboard
```

### AWS — THECOLLECTIVE_AWS01 (10.251.8.172 via VPN)

Internal server. Path-based routing, no TLS (VPN access only). Uses `traefik/docker-compose.yml`.

**SSH:**
```bash
ssh aws01                              # Shell (requires VPN)
ssh -L 3030:localhost:3030 aws01       # Langfuse UI
```

### Local dev

Uses `~/Dev/local-infra/` with mkcert TLS and `*.local` domains. Same services (Traefik, Postgres, Redis, Langfuse) on the `infra` network.

## Day-to-day: deploying

```bash
# Deploy a project to DO
./deploy.sh do marie

# Deploy to AWS
./deploy.sh aws marie
```

## Adding a new project

Follow these steps to go from zero to a deployed app. Example uses a project called `acme`.

### Step 1: Create the database

```bash
# DO
ssh isidora
docker exec -it postgres psql -U caitie_admin_db
CREATE DATABASE acme;
\q

# Local
docker exec -it postgres psql -U postgres
CREATE DATABASE acme;
\q
```

### Step 2: Create deploy key on the server

One key per repo, per server. Read-only.

```bash
ssh isidora
ssh-keygen -t ed25519 -f ~/.ssh/github_deploy_acme -N ""
cat ~/.ssh/github_deploy_acme.pub
```

Add the public key at `https://github.com/<user>/Acme/settings/keys` → **Allow read access only**.

If this is a second deploy key on the server, add to `~/.ssh/config`:

```
Host github.com-acme
    HostName github.com
    User git
    IdentityFile ~/.ssh/github_deploy_acme
```

Then clone with: `git clone git@github.com-acme:<user>/Acme.git`

### Step 3: Create Dockerfiles (multi-stage)

Each service gets one Dockerfile with two targets:

```dockerfile
# apps/api/Dockerfile
FROM node:22-slim AS development
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .
CMD ["npm", "run", "dev"]

FROM node:22-slim AS production
WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production
COPY . .
RUN npm run build
CMD ["node", "dist/main.js"]
```

### Step 4: Create compose files

**`docker-compose.yml`** — local dev:

```yaml
name: acme

services:
  api:
    build:
      context: .
      dockerfile: apps/api/Dockerfile
      target: development
    container_name: acme-api
    env_file: .env
    volumes:
      - ./apps/api/src:/app/apps/api/src
    networks:
      - infra

  web:
    build:
      context: .
      dockerfile: apps/web/Dockerfile
      target: development
    container_name: acme-web
    environment:
      - VITE_API_URL=https://acme.local/api
    volumes:
      - ./apps/web/src:/app/apps/web/src
    networks:
      - infra

networks:
  infra:
    external: true
```

**`docker-compose.prod.yml`** — any server (DO, AWS, future):

```yaml
name: acme

services:
  api:
    build:
      context: .
      dockerfile: apps/api/Dockerfile
      target: production
    container_name: acme-api
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
      - "traefik.http.routers.acme-api.rule=Host(`${DOMAIN}`) && PathPrefix(`/api`)"
      - "traefik.http.routers.acme-api.entrypoints=websecure"
      - "traefik.http.routers.acme-api.tls.certresolver=letsencrypt"
      - "traefik.http.routers.acme-api.priority=200"
      - "traefik.http.services.acme-api.loadbalancer.server.port=3000"

  web:
    build:
      context: .
      dockerfile: apps/web/Dockerfile
      target: production
    container_name: acme-web
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
      - "traefik.http.routers.acme-web.rule=Host(`${DOMAIN}`)"
      - "traefik.http.routers.acme-web.entrypoints=websecure"
      - "traefik.http.routers.acme-web.tls.certresolver=letsencrypt"
      - "traefik.http.routers.acme-web.priority=100"
      - "traefik.http.services.acme-web.loadbalancer.server.port=3001"
      # HTTP -> HTTPS redirect
      - "traefik.http.routers.acme-redirect.rule=Host(`${DOMAIN}`)"
      - "traefik.http.routers.acme-redirect.entrypoints=web"
      - "traefik.http.routers.acme-redirect.middlewares=acme-https-redirect@docker"
      - "traefik.http.middlewares.acme-https-redirect.redirectscheme.scheme=https"
      - "traefik.http.middlewares.acme-https-redirect.redirectscheme.permanent=true"

networks:
  infra:
    external: true
```

The **only difference** between servers is `.env`:

```env
# DO
DOMAIN=acme.lostriver.llc

# Local
DOMAIN=acme.local
```

### Step 5: Create `.env.example`

```env
# --- Server-specific (change per environment) ---
DOMAIN=acme.local
DATABASE_URL=postgresql://postgres:postgres@postgres:5432/acme

# --- Secrets (generate once, store in Bitwarden) ---
JWT_SECRET=
OPENAI_API_KEY=

# --- Langfuse (per-project keys from Langfuse UI) ---
LANGFUSE_BASE_URL=http://langfuse:3000
LANGFUSE_PUBLIC_KEY=
LANGFUSE_SECRET_KEY=

# --- Defaults (usually don't change) ---
PORT=3000
NODE_ENV=production
```

### Step 6: DNS (DO only)

Add an A record in Cloudflare:

```
acme.lostriver.llc  →  174.138.33.106
```

Traefik will auto-provision a Let's Encrypt certificate on first request.

### Step 7: Clone and deploy on the server

```bash
ssh isidora
cd /home/deploy
git clone git@github.com-acme:<user>/Acme.git acme
cd acme

# Create .env from template
cp .env.example .env
# Edit .env: set DOMAIN, DATABASE_URL, secrets from Bitwarden

# Build and start
docker compose -f docker-compose.prod.yml up -d --build

# Run migrations (if applicable)
docker exec -w /app/apps/api acme-api npx drizzle-kit migrate
```

### Step 8: Langfuse integration

1. Open Langfuse UI (`ssh -L 3030:localhost:3030 isidora`, then `http://localhost:3030`)
2. **New Project** → name it "Acme"
3. **Settings → API Keys → Create API Key**
4. Copy `LANGFUSE_PUBLIC_KEY` and `LANGFUSE_SECRET_KEY` to the project's `.env`
5. `LANGFUSE_BASE_URL=http://langfuse:3000` (containers use Docker network, not the tunnel)

### Step 9: Store secrets in Bitwarden

Add all `.env` values to a Bitwarden Secure Note. Convention: if it goes in `.env`, it goes in Bitwarden.

### Step 10: Local dev setup

```bash
cd ~/Dev/Acme

# Create .env
cp .env.example .env
# Edit: DOMAIN=acme.local, DATABASE_URL with postgres:postgres

# Create local database
docker exec -it postgres psql -U postgres -c "CREATE DATABASE acme"

# Add to /etc/hosts
echo "127.0.0.1 acme.local" | sudo tee -a /etc/hosts

# Create mkcert certificate (in local-infra)
cd ~/Dev/local-infra
mkcert -cert-file certs/acme.pem -key-file certs/acme-key.pem acme.local

# Add cert to Traefik dynamic config (dynamic/tls.yml)
# Then add routing rules (dynamic/acme.yml)

# Start
cd ~/Dev/Acme
docker compose up -d --build
```

Visit `https://acme.local`

## Secrets

All server secrets are in Bitwarden:
- **THECOLLECTIVE_AWS01** Secure Note — AWS credentials and env vars
- DO secrets stored similarly

Convention: if it goes in `.env`, it goes in Bitwarden.
