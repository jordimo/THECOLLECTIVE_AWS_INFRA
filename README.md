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

### 1. Deploy key

```bash
ssh isidora 'ssh-keygen -t ed25519 -f ~/.ssh/github_deploy_<project> -N ""'
ssh isidora 'cat ~/.ssh/github_deploy_<project>.pub'
```

Add at `https://github.com/<user>/<repo>/settings/keys` (read-only).

### 2. Project compose files

Each project has two compose files:

- **`docker-compose.yml`** — local dev (volume mounts, hot reload, no Traefik labels)
- **`docker-compose.prod.yml`** — any server (production builds, Traefik labels, healthchecks)

Differences between servers live in `.env` only (`DOMAIN`, `DATABASE_URL`).

### 3. Database

```bash
ssh isidora
docker exec -it postgres psql -U caitie_admin_db
CREATE DATABASE <project>;
```

### 4. Langfuse setup

Langfuse provides LLM observability (tracing, prompt management, evaluations).

**First-time setup (per environment):**

1. Access Langfuse UI:
   - Local: `https://langfuse.local` or `http://localhost:3030`
   - Server: `ssh -L 3030:localhost:3030 isidora`, then open `http://localhost:3030`
2. Create an account (first user becomes admin)

**Per-project setup:**

1. Open Langfuse UI → **New Project** → name it after the app (e.g. "Marie")
2. Go to **Settings → API Keys → Create API Key**
3. Add to the project's `.env`:
   ```env
   LANGFUSE_BASE_URL=http://langfuse:3000
   LANGFUSE_PUBLIC_KEY=pk-lf-...
   LANGFUSE_SECRET_KEY=sk-lf-...
   ```
   (Containers reach Langfuse via Docker network, not the SSH tunnel)

## Secrets

All server secrets are in Bitwarden:
- **THECOLLECTIVE_AWS01** Secure Note — AWS credentials and env vars
- DO secrets stored similarly

Convention: if it goes in `.env`, it goes in Bitwarden.
