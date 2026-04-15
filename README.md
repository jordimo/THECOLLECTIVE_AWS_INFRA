# infra

Shared infrastructure for all environments: **DigitalOcean** (isidora), **AWS** (THECOLLECTIVE_AWS01), and **local dev**.

One `docker-compose.yml`, all environments. Differences live in `.env`.

## What this repo provides

Traefik, PostgreSQL (pgvector), Redis, Langfuse, and Mailpit (local only) — running on every environment with the same conventions. Projects connect via the `infra` Docker network.

### Shared services

| Service  | From containers     | From host (dev)          | From host (server)              |
|----------|--------------------|--------------------------|---------------------------------|
| Postgres | `postgres:5432`    | `localhost:5432`         | Internal only                   |
| Redis    | `redis:6379`       | `localhost:6379`         | Internal only                   |
| Langfuse | `langfuse:3000`    | `https://langfuse.local` | SSH tunnel `localhost:3030`     |
| Traefik  | N/A                | `https://*.local`        | Ports 80/443                    |
| Mailpit  | `mailpit:1025`     | `localhost:8025`         | N/A (local only)                |

## Repository structure

```
infra/
├── docker-compose.yml        ← Unified infra (all environments)
├── .env.example.local        ← Template for local dev
├── .env.example.do           ← Template for DigitalOcean
├── dynamic/                  ← Traefik dynamic config
│   ├── dynamic.yml           ← Health checks, security headers (committed)
│   ├── middlewares.yml        ← Shared middlewares (committed)
│   ├── tls.yml               ← Local mkcert certs (gitignored)
│   └── routing-*.yml         ← Local project routing (gitignored)
├── certs/                    ← Local mkcert certificates (gitignored)
├── init-project.sh           ← Set up a new project (any environment)
├── deploy.sh                 ← Deploy from corporate laptop over SSH
├── traefik/                  ← AWS-specific infra (path-based routing)
└── docs/
    ├── plans/
    └── dev-diary/
```

## Quick start

### Local dev

```bash
cp .env.example.local .env
docker compose --profile local up -d
```

Services: Traefik (`:8080`), Postgres (`:5432`), Redis (`:6379`), Langfuse (`:3030`), Mailpit (`:8025`)

### Server (DO/AWS)

```bash
cp .env.example.do .env
# Edit .env with production values
docker compose up -d
```

## Environments

### DigitalOcean — isidora (174.138.33.106)

Primary production server. Host-based routing with Let's Encrypt TLS.

```
/home/deploy/
├── infra/                    ← this repo
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

### Local dev

Uses `~/Dev/infra/` with mkcert TLS and `*.local` domains. Same compose file as servers, with `.env.example.local` for local-specific settings. Mailpit enabled via `COMPOSE_PROFILES=local`.

## Day-to-day: deploying

All scripts run from this repo (`~/Dev/infra/`). They SSH into the server, pull the latest code, and rebuild.

```bash
# Deploy a project
./deploy.sh --target do:isidora marie

# Deploy infra (git pull + restart services)
./deploy.sh --target do:isidora infra

# Deploy everything (infra + all projects)
./deploy.sh --target do:isidora --all

# AWS
./deploy.sh --target aws marie
```

The deploy script doesn't need the git URL — the repo is already cloned on the server (set up by `init-project.sh`). It just does `git pull && docker compose up -d --build`.

If a project isn't found, the script suggests running `init-project.sh`.

## Adding a new project

### Using `init-project.sh` (recommended)

The script automates database creation, repo cloning, .env setup, mkcert certificates, /etc/hosts, Traefik routing, container builds, and migrations.

```bash
# Local — project already cloned
./init-project.sh acme --target local --dir ~/Dev/THECOLLECTIVE/Acme

# Local — clone and set up
./init-project.sh acme --target local --dir ~/Dev/Acme --repo git@github.com:jordimo/Acme.git

# DO (isidora) — clone from GitHub
./init-project.sh acme --target do:isidora --repo git@github.com:jordimo/Acme.git

# DO (isidora) — project already on server
./init-project.sh acme --target do:isidora

# AWS
./init-project.sh acme --target aws --repo git@github.com:jordimo/Acme.git

# Custom database name
./init-project.sh acme --target do:isidora --db acme_production --repo git@github.com:jordimo/Acme.git
```

Options:
- `--target` — **Required.** `local`, `do:<droplet>`, or `aws`
- `--dir` — Project directory (required for local, defaults to `/home/deploy/<name>` on DO)
- `--repo` — Git repo URL (clones if directory doesn't exist)
- `--db` — Database name (defaults to project name)

**After running the script**, update `docs/plans/infra-unification.md` → `registry.yml` with the new app entry (domain, containers, ports, db, redis_db).

### Manual setup

If you prefer manual steps or the script doesn't fit your case:

#### 1. Deploy key (servers only)

```bash
ssh isidora
ssh-keygen -t ed25519 -f ~/.ssh/github_deploy_acme -N ""
cat ~/.ssh/github_deploy_acme.pub
```

Add at `https://github.com/<user>/Acme/settings/keys` (read-only).

For multiple deploy keys, add to `~/.ssh/config`:
```
Host github.com-acme
    HostName github.com
    User git
    IdentityFile ~/.ssh/github_deploy_acme
```

#### 2. Project compose files

Each project has two compose files:

- **`docker-compose.yml`** — local dev (volume mounts, hot reload, no Traefik labels)
- **`docker-compose.prod.yml`** — any server (production builds, Traefik labels, healthchecks)

Differences between servers live in `.env` only (`DOMAIN`, `DATABASE_URL`).

#### 3. `.env.example`

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

#### 4. DNS (DO only)

Add an A record in Cloudflare: `acme.lostriver.llc → 174.138.33.106`

#### 5. Langfuse integration

1. Access Langfuse UI (`ssh -L 3030:localhost:3030 isidora`, then `http://localhost:3030`)
2. **New Project** → name it "Acme"
3. **Settings → API Keys → Create API Key**
4. Add to the project's `.env`:
   ```env
   LANGFUSE_BASE_URL=http://langfuse:3000
   LANGFUSE_PUBLIC_KEY=pk-lf-...
   LANGFUSE_SECRET_KEY=sk-lf-...
   ```

## Secrets

All server secrets are in Bitwarden:
- **THECOLLECTIVE_AWS01** Secure Note — AWS credentials and env vars
- DO secrets stored similarly

Convention: if it goes in `.env`, it goes in Bitwarden.
