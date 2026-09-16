# inngest-vps

**One-command self-hosted [Inngest](https://www.inngest.com/) on AWS Lightsail or Fly.io.**

The original Lightsail/Terraform path remains the default. The additive Fly target runs Inngest OSS on Fly, uses Fly's TLS termination and a Fly Redis service, and connects to Supabase Postgres. Neither target uses Inngest Cloud.

Inngest Cloud is great, but the Hobby tier caps concurrency and crons. Self-hosting gives you full control for about **$12/month** on a 2 GB Lightsail box. Inngest ships Docker images and docs, but there is no single "deploy button" for a production-ready stack with TLS, Postgres, and Redis. This repo is that button.

## Automated tests

The deployment guards have a credential-free shell test. Run it from the repository root:

```bash
./scripts/deploy-config.test.sh
```

It exercises both sync modes with command stubs, verifies that Fly mode does not invoke SSH or rsync, verifies that an ambient `FLY_APP_NAME` does not redirect the default Lightsail mode, and verifies that an invalid Supabase schema or missing `sslmode=require` fails before `flyctl` is called.

## How this compares to Inngest's deployment options

[Inngest's deployment docs](https://www.inngest.com/docs/platform/deployment) list six paths. They solve different problems:

| Official option | What it optimizes for | Where the work lands on you |
|-----------------|----------------------|-----------------------------|
| **Vercel / Render / DigitalOcean / Cloudflare Pages** | Inngest **Cloud** calling your functions on that platform | Platform deploy + Inngest Cloud account. Hobby concurrency/cron limits still apply. Great when you live on one host and want managed sync. |
| **Deploy on any platform** | Flexibility: run the SDK anywhere | You choose Cloud vs self-host, env vars, TLS, and how apps register. Docs, not a stack. |
| **[Self-host Inngest](https://www.inngest.com/docs/self-hosting)** | Run the orchestrator yourself | Docker image + flags/config. You still provision the VM, Postgres, Redis, HTTPS, DNS, and worker registration (OSS has no Cloud sync API). |

**inngest-vps** is opinionated glue for that last gap: not a new runtime, just the boring production stack Inngest documents but does not ship as one unit.

| | Inngest Cloud + platform integration | Official self-host docs | **inngest-vps** |
|---|:---:|:---:|:---:|
| Orchestrator | Inngest Cloud | Self-hosted OSS | Self-hosted OSS |
| Typical cost | Free tier → paid | VM + DB (you size it) | **~$12/mo** Lightsail default |
| Postgres + Redis | Managed by Inngest | You wire it up | **Included** in Compose |
| HTTPS / public URL | Your app host handles it | You wire it up | **Caddy + Let's Encrypt** |
| VM + firewall + static IP | Your platform | You wire it up | **Terraform** (Lightsail) |
| Worker app sync | Integrations / Cloud API | Manual dashboard or `urls:` in config | **`sync-apps.sh`** (generates `inngest.yaml`, reloads server) |
| Deploy entrypoint | Platform-specific | `docker run` / compose yourself | **`aws login` → `./scripts/up.sh`** |

**Pick Inngest Cloud integrations** if you're on Vercel (or similar), happy on Hobby/Pro, and want zero ops on the orchestrator.

**Pick official self-host** if you want full control and already have Kubernetes, RDS, and an ingress story.

**Pick inngest-vps** if you outgrew Hobby limits, want self-host on a single cheap VPS, and would rather run one script than assemble Postgres, Redis, Caddy, Terraform, and OSS worker polling from scratch.

Your app workers can stay on Coolify, Railway, Vercel, or anywhere public HTTPS. Only the **Inngest server** runs on Lightsail; point them at it with `INNGEST_BASE_URL` + the keys from `./scripts/install.sh --print-env`.

## Fly.io target (additive)

The Fly path is a sibling to `./scripts/up.sh`; it does not replace Lightsail or Terraform:

```bash
cp fly.toml.example fly.toml
cp .env.example .env
# Set keys and the values below in .env (or export them)
export FLY_APP_NAME=inngest-oss
export FLY_REDIS_URL=redis://<redis-app>.internal:6379
export INNGEST_POSTGRES_URI='postgresql://postgres.<project-ref>:<password>@aws-0-<region>.pooler.supabase.com:5432/inngest?sslmode=require&options=-c%20search_path%3Dinngest'
./scripts/up-fly.sh
```

Create the `inngest` database (or use another dedicated database) in Supabase. The session pooler URI must use port `5432`, include `sslmode=require`, and use a dedicated/non-tenant schema. The example uses `search_path=inngest`; do **not** use the tenant RLS schema `app`, and do not put Inngest system tables in it. URL-encode query parameters as shown. `INNGEST_POSTGRES_URI` is passed to Inngest unchanged.

Fly terminates TLS at the edge, so `https://<FLY_APP_NAME>.fly.dev/health` is the health check. `fly.toml` disables auto-stop and keeps at least one machine running. Redis is expected to be a separate Fly app reachable on its private `.internal` address. Set `FLY_REDIS_URL` to its private URL; the deployment stores it as `INNGEST_REDIS_URI`.

`./scripts/install.sh --print-env` remains the worker contract for either target and does not require `INNGEST_LIGHTSAIL_IP`. It prints `INNGEST_BASE_URL`, `INNGEST_EVENT_KEY`, `INNGEST_SIGNING_KEY`, and `INNGEST_DEV=0`. Worker serve paths vary by framework: use `/api/inngest` for the OpsATC pilot and many Next.js/Express workers, or `/inngest` for Mastra. Put the actual public endpoint in `sync-apps.conf`.

Fly sync is deliberately OSS poll-based: `./scripts/sync-apps.sh --write-yaml` regenerates `inngest.yaml` from `sync-apps.conf`; `./scripts/sync-apps.sh --fly` deploys it. `./scripts/sync-apps.sh --check` only probes worker URLs. The default sync target is Lightsail, so a `FLY_APP_NAME` in `.env` or the shell cannot change an existing Lightsail command; choose Fly explicitly with `--fly` (or `INNGEST_TARGET=fly`). There is no Lightsail SSH on the Fly path and no Inngest Cloud REST sync (OSS returns 501).

Clean-clone verification:

```bash
git clone https://github.com/PracticalWorks/inngest-vps.git && cd inngest-vps
cp fly.toml.example fly.toml
# configure .env, Supabase, Fly Redis, and sync-apps.conf
./scripts/install.sh --print-env
./scripts/up-fly.sh
curl -fsS "https://${FLY_APP_NAME}.fly.dev/health"
FLY_APP_NAME="$FLY_APP_NAME" ./scripts/sync-apps.sh --check
FLY_APP_NAME="$FLY_APP_NAME" ./scripts/sync-apps.sh --write-yaml
FLY_APP_NAME="$FLY_APP_NAME" ./scripts/sync-apps.sh
```


| Piece | Role |
|-------|------|
| **Inngest OSS** | Event API, executor, dashboard UI |
| **Postgres 17** | Persistent state (not SQLite) |
| **Redis 7** | Queue + run state |
| **Caddy** | Automatic HTTPS (Let's Encrypt) |
| **Terraform** | Lightsail instance, static IP, firewall |

Stack runs in Docker Compose on Ubuntu 24.04. Scripts handle AWS auth, provisioning, deploy, and worker registration.

## Prerequisites

- macOS or Linux with Homebrew (or install tools manually)
- AWS account
- AWS CLI 2.32+ (`aws login` supported)
- Terraform, rsync, OpenSSH
- A domain (e.g. `inngest.example.com`) you can point at the VPS

```bash
./scripts/prereqs.sh   # optional: install aws, terraform, rsync
```

## Quick start

```bash
git clone <this-repo> inngest-vps && cd inngest-vps
chmod +x scripts/*.sh scripts/lib/*.sh

./scripts/init.sh          # .env + sync-apps.conf from examples
# Edit .env → INNGEST_DOMAIN=inngest.example.com
# Edit sync-apps.conf → your worker apps (can be empty at first)

aws login                  # browser sign-in, no access keys required
./scripts/up.sh            # Lightsail + stack + deploy (~5 min)
```

After provision completes:

1. **DNS** — A record `INNGEST_DOMAIN` → static IP from output (grey-cloud / DNS-only for easiest TLS)
2. **Workers** — `./scripts/install.sh --print-env` → paste into each app's env, set `INNGEST_DEV=0`, redeploy
3. **Sync** — `./scripts/sync-apps.sh` → registers workers with the Inngest server
4. **Verify** — `curl -fsS https://<your-domain>/health` and open the dashboard → Apps

## Commands

| Command | Purpose |
|---------|---------|
| `./scripts/init.sh` | First-time local config from examples |
| `./scripts/up.sh` | Full deploy (Terraform + install) |
| `./scripts/provision.sh --install` | Re-sync stack to existing VPS |
| `./scripts/provision.sh --destroy` | Tear down AWS resources |
| `./scripts/install.sh --print-env` | Worker env vars to copy |
| `./scripts/sync-apps.sh` | Probe workers + reload Inngest poll config |
| `./scripts/sync-apps.sh --check` | Probe worker URLs only |

## Connect your apps

Self-hosted Inngest requires each worker to use the **same** event key and signing key as the server, plus:

```bash
INNGEST_DEV=0
INNGEST_BASE_URL=https://<INNGEST_DOMAIN>
INNGEST_EVENT_KEY=<from print-env>
INNGEST_SIGNING_KEY=<from print-env>
```

Add entries to `sync-apps.conf`:

```
my-app-id|https://my-app.example.com/api/inngest
```

**Mastra note:** `@mastra/server` serves Inngest at `/inngest`, not `/api/inngest`. Use the path your app actually exposes.

**OSS sync note:** Inngest Cloud has a REST "sync app" API. Self-hosted OSS does not (`501 not implemented`). This repo syncs by listing worker URLs in `inngest.yaml`; the Inngest server polls them. `./scripts/sync-apps.sh` regenerates that file and reloads the container. You can also use **Apps → Sync manually** in the dashboard.

## AWS auth

Solo operator flow — no IAM bootstrap, no console:

```bash
aws login
./scripts/up.sh
```

Terraform credentials come from `aws configure export-credentials` (works with `aws login`; plain Terraform does not read the login cache).

Classic alternative: `aws configure` with access keys.

## Cost and sizing

| Resource | Default | Price |
|----------|---------|-------|
| Lightsail `small_2_0` | 2 GB RAM, 1 vCPU | **~$12/mo** |
| Static IP | attached | included |

Memory limits in `docker-compose.yml` (~1.75 GB for containers). Default `INNGEST_QUEUE_WORKERS=200`.

## TLS options

**A) Grey-cloud DNS (default)** — Caddy obtains Let's Encrypt certs automatically. Set `INNGEST_DOMAIN` in `.env`.

**B) Orange-cloud + origin cert** — See comments in `Caddyfile`; mount Cloudflare origin certs under `./certs/`.

## Terraform

`terraform/aws/` — Lightsail instance, static IP, SSH key, firewall (22 from your IP, 80/443 public). Applied automatically by `provision.sh`. State stays local (gitignored).

Copy `terraform/aws/terraform.tfvars.example` or let the script generate `terraform.tfvars` on first run.

## Ops

```bash
ssh ubuntu@$(terraform -chdir=terraform/aws output -raw static_ip) \
  'cd /opt/inngest && sudo docker compose logs -f inngest'
```

Postgres backups: `scripts/backup-pg.sh` (cron on the VPS).

## Project layout

```
inngest-vps/
├── docker-compose.yml      # Lightsail Inngest + Postgres + Redis + Caddy
├── fly.toml.example       # Fly app config (copy to fly.toml)
├── Dockerfile             # Fly Inngest image with poll config
├── Caddyfile
├── inngest.yaml.example    # generated → inngest.yaml (gitignored)
├── sync-apps.conf.example  # copy → sync-apps.conf (gitignored)
├── scripts/
│   ├── up.sh               # entry point
│   ├── provision.sh        # Terraform + install
│   ├── install.sh          # rsync stack to VPS
│   ├── sync-apps.sh        # worker registration (OSS poll)
│   └── lib/                # aws + shared helpers
└── terraform/aws/        # Lightsail
```

## License

MIT — see [LICENSE](./LICENSE).

Inngest is a trademark of Inngest, Inc. This project is not affiliated with or endorsed by Inngest.
