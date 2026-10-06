# Setup

Documents the environment as it runs today: the compose stack, the bootstrap
script, configuration, persistence, backup/restore and tooling. It does **not**
cover workflows (those get their own feature specs).

Source of truth is the current code (`docker-compose.yml`, `scripts/setup.sh`,
`.env.example`, `postgres/init/`). If this spec and the code diverge, the code
wins; add a `Deviation:` note here.

## 1. Goal

One command on a fresh clone (`./scripts/setup.sh`) brings up a self-hosted
WhatsApp automation stack: WAHA (gateway) + n8n in queue mode + Postgres +
Redis, with everything stateful on host bind mounts and secrets only in a
git-ignored `.env`.

## 2. Services (`docker-compose.yml`)

One compose project, 5 services. Image tags come from `.env` and are pinned,
never `latest`.

| Service      | Image                           | Host port                       | Role                                                    |
| ------------ | ------------------------------- | ------------------------------- | ------------------------------------------------------- |
| `postgres`   | `postgres:${POSTGRES_TAG}`      | none (internal)                 | n8n DB, WAHA sessions and media                         |
| `redis`      | `redis:${REDIS_TAG}`            | none (internal)                 | n8n queue (Bull)                                        |
| `waha`       | `devlikeapro/waha:${WAHA_TAG}`  | `127.0.0.1:${WAHA_HOST_PORT}→3000` | WhatsApp gateway (NOWEB engine), dashboard + API     |
| `n8n`        | `n8nio/n8n:${N8N_TAG}`          | `127.0.0.1:5678→5678`           | Main: editor, API, webhooks; enqueues executions        |
| `n8n-worker` | `n8nio/n8n:${N8N_TAG}`          | none                            | Runs executions (`worker --concurrency=…`)              |

All host ports bind to `127.0.0.1` only.

### 2.1 postgres

- `max_connections=1000` (WAHA opens one database per session).
- Volumes: `./postgres-data` → data dir; `./postgres/init` → `/docker-entrypoint-initdb.d` (read-only).
- Superuser `postgres` / `POSTGRES_PASSWORD`, default DB `postgres`.
- Healthcheck: `pg_isready -U postgres -d postgres` (5s interval, 20 retries).
- `restart: unless-stopped`.

Init script `postgres/init/01-create-databases.sh` (runs **only on an empty
`postgres-data/`**):

- role `n8n` (LOGIN, `N8N_DB_PASSWORD`) + database `n8n` owned by it.
- role `waha` (LOGIN, **CREATEDB**, `WAHA_DB_PASSWORD`) + database `waha` owned by it. CREATEDB is needed because WAHA creates `waha_<namespace>` databases per session.
- Changing `N8N_DB_PASSWORD` / `WAHA_DB_PASSWORD` later requires `ALTER ROLE`.

### 2.2 redis

- `redis-server --requirepass ${REDIS_PASSWORD} --appendonly yes` (AOF on).
- Volume: `./redis-data` → `/data`.
- Healthcheck: authenticated `redis-cli ping` returns `PONG`.
- Holds only the job queue; needs no backup.

### 2.3 waha

- Engine: `WHATSAPP_DEFAULT_ENGINE=NOWEB`.
- Webhook: `WHATSAPP_HOOK_URL=http://n8n:5678/webhook/waha`, events `message.any` (includes messages sent from the phone itself, `fromMe`).
- Dashboard enabled; credentials `WAHA_DASHBOARD_USER` / `WAHA_DASHBOARD_PASSWORD`.
- API auth: `WAHA_API_KEY` (header `X-Api-Key`).
- Sessions in Postgres: `WHATSAPP_SESSIONS_POSTGRESQL_URL` → `waha` DB as role `waha`. Media in Postgres too (`WAHA_MEDIA_STORAGE=POSTGRESQL`, `WAHA_MEDIA_POSTGRESQL_URL`).
- `depends_on` postgres healthy. No volumes. `restart: unless-stopped`.
- Tag is architecture specific: `noweb-arm-2026.9.2` (arm64/Apple Silicon), `noweb-2026.9.2` (amd64). Since WAHA 2026.6.1 the former Plus features are in Core, so the pinned `2026.9.x` has no Core-only limits (checked 2026-10-05).

### 2.4 n8n (main)

Shared env anchor `x-n8n-env` (also used by the worker):

| Variable                                 | Value                                                       |
| ---------------------------------------- | ----------------------------------------------------------- |
| `DB_TYPE`                                | `postgresdb` (host `postgres:5432`, db/user `n8n`)          |
| `EXECUTIONS_MODE`                        | `queue`                                                     |
| `QUEUE_BULL_REDIS_HOST/PORT/PASSWORD`    | `redis` / `6379` / `${REDIS_PASSWORD}`                      |
| `N8N_ENCRYPTION_KEY`                     | `${N8N_ENCRYPTION_KEY}`                                     |
| `N8N_DEFAULT_BINARY_DATA_MODE`           | `database` (filesystem mode is unsupported with workers)    |
| `N8N_LICENSE_ACTIVATION_KEY`             | `${…:-}` optional free Registered Community license         |
| `GENERIC_TIMEZONE`, `TZ`                 | `${TZ}`                                                     |

Main-only env: `N8N_SECURE_COOKIE=false` (local plain http),
`N8N_EDITOR_BASE_URL=http://localhost:5678`, `WEBHOOK_URL=http://localhost:5678/`,
`N8N_PUBLIC_API_DISABLED=false`, `OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true`.

Volumes: `./n8n-data` → `/home/node/.n8n`; `./workflows` → `/workflows`.
`depends_on` postgres + redis healthy. `restart: unless-stopped`.

### 2.5 n8n-worker

- Same image, env anchor, tag and encryption key as main; `command: worker --concurrency=${N8N_WORKER_CONCURRENCY:-10}`.
- Same volumes (community nodes must exist on the worker too).
- `depends_on` postgres, redis healthy and `n8n` started. `stop_grace_period: 60s`.
- Code nodes use n8n's default internal task runner; external runners (`n8nio/runners`) are not set up.
- Scale: `docker compose up -d --scale n8n-worker=2`.

### 2.6 Internal addresses

- WAHA from containers: `http://waha:3000`
- n8n webhook receiver from WAHA: `http://n8n:5678/webhook/waha`

## 3. Configuration (`.env`)

`.env` is git-ignored (mode 600). `.env.example` lists every key without
values. Variables:

| Key                          | Notes                                                     |
| ---------------------------- | --------------------------------------------------------- |
| `WAHA_TAG`                   | pinned; arch dependent (see 2.3)                          |
| `WAHA_HOST_PORT`             | host port for WAHA, default `3100`                        |
| `WAHA_DASHBOARD_USER`        | default `admin`                                           |
| `WAHA_DASHBOARD_PASSWORD`    | generated                                                 |
| `WAHA_API_KEY`               | generated                                                 |
| `N8N_TAG`                    | default `2.41.7`                                          |
| `N8N_ENCRYPTION_KEY`         | generated once; losing it makes saved credentials unreadable |
| `TZ`                         | default `America/Sao_Paulo`                               |
| `POSTGRES_TAG`               | default `17.11-alpine`                                    |
| `POSTGRES_PASSWORD`          | generated (superuser)                                     |
| `N8N_DB_PASSWORD`            | generated (role `n8n`)                                    |
| `WAHA_DB_PASSWORD`           | generated (role `waha`)                                   |
| `REDIS_TAG`                  | default `8.10.2-alpine`                                   |
| `REDIS_PASSWORD`             | generated                                                 |
| `N8N_WORKER_CONCURRENCY`     | optional, default 10 in compose                           |
| `N8N_LICENSE_ACTIVATION_KEY` | optional; free Registered Community license (Debug in editor, folders, custom execution data). Request in n8n: Settings > Usage and plan > Unlock |
| `N8N_API_KEY`                | optional; created by the owner in n8n: Settings > n8n API; used by `scripts/n8n-mcp.sh` |

Rules: never overwrite existing values, only fill missing/empty keys; never
commit `.env`; tags change only on purpose, after a backup.

## 4. Bootstrap (`scripts/setup.sh`)

POSIX `sh`, idempotent, run from a fresh clone. Requirements: Docker with
Compose v2, `openssl`. Steps, in order:

1. Check `docker` and `docker compose` v2.
2. Create `.env` from `.env.example` (chmod 600) if missing.
3. `set_default` fills only missing/empty keys (see table in section 3). Secrets via `openssl rand -hex` (12 bytes for the dashboard password, 32 for API key and encryption key, 24 for DB/Redis passwords). WAHA tag picked from `uname -m` (arm64/aarch64 → `noweb-arm-2026.9.2`, else `noweb-2026.9.2`). Appends empty `N8N_API_KEY` and `N8N_LICENSE_ACTIVATION_KEY` if absent.
4. Create dirs: `n8n-data postgres-data redis-data workflows backups`.
5. Install the community node `@devlikeapro/n8n-nodes-waha@2025.2.9` into `n8n-data/nodes` (only if missing) via a one-off `docker compose run --rm --no-deps` of the n8n image.
6. `docker compose up -d --wait postgres redis`, then `docker compose up -d`.
7. Wait for n8n `/healthz` (up to 60 tries × 2s); fail with a hint to check logs.
8. If `workflows/*.json` exists, run `n8n import:workflow --separate --input=/workflows/` (workflows land inactive; same id overwrites). A failure only warns (the owner account may not exist yet; rerun).
9. Print URLs and owner steps.

## 5. Owner steps (manual, not automatable)

1. Create the n8n owner account.
2. Create the WAHA credential in n8n: URL `http://waha:3000`, API key = `WAHA_API_KEY`.
3. Pair the `default` WAHA session with the **test number** in the WAHA dashboard.
4. Optional: unlock the free license, put the emailed key in `N8N_LICENSE_ACTIVATION_KEY`, then `docker compose up -d n8n n8n-worker`.
5. Optional: create an n8n API key and put it in `N8N_API_KEY` (for the MCP).
6. Optional: Google OAuth with redirect URI `http://localhost:5678/rest/oauth2-credential/callback`. In Testing mode the refresh token expires after 7 days; publish the OAuth app for production.
7. Back up `.env` in a password manager.

## 6. URLs

- n8n editor: `http://localhost:5678`
- WAHA dashboard: `http://localhost:${WAHA_HOST_PORT}/dashboard` (default `3100`)

## 7. Persistence

All runtime data is bind-mounted on the host and git-ignored:

| Path             | Content                                                                 |
| ---------------- | ----------------------------------------------------------------------- |
| `postgres-data/` | n8n database, WAHA sessions and media, WAHA per-session databases       |
| `redis-data/`    | Redis AOF (queue)                                                       |
| `n8n-data/`      | `/home/node/.n8n`: config and community nodes (shared by main + worker) |
| `gateway-data/`  | legacy WAHA local sessions; no longer mounted, kept only for rollback   |
| `backups/`       | dumps and archives (git-ignored)                                        |

A WAHA session paired before the move to Postgres must be paired again.

Versioned: `workflows/` (→ `/workflows` in the n8n container) for workflow
JSON. Currently only `.gitkeep`.

## 8. Daily commands

```
docker compose up -d
docker compose ps
docker compose logs -f <service>   # waha, n8n, n8n-worker, postgres, redis
docker compose restart <service>
docker compose stop
docker compose start
docker compose down
```

**Never** `docker compose down -v`, `docker volume rm|prune`, `docker system
prune`, or delete the data dirs: that destroys WhatsApp sessions and n8n data.

Workflow export/import:

```
docker compose exec n8n n8n export:workflow --all --separate --output=/workflows/
docker compose exec n8n n8n import:workflow --separate --input=/workflows/
```

Never `export:credentials` into `workflows/`. Import overwrites workflows with
the same id.

## 9. Community nodes

Installed in `n8n-data/nodes/` (not versioned; reinstall after recreating the
environment): `@devlikeapro/n8n-nodes-waha@2025.2.9`. After installing any
community node, restart both `n8n` and `n8n-worker`.

```
docker compose exec -w /home/node/.n8n/nodes n8n npm install --save-exact @devlikeapro/n8n-nodes-waha@2025.2.9
docker compose restart n8n n8n-worker
```

## 10. Backup / restore

Backup into `backups/`:

```
mkdir -p backups
docker compose exec -T postgres pg_dumpall -U postgres > backups/postgres-$(date +%F).sql   # everything, incl. WAHA per-session DBs
docker compose exec -T postgres pg_dump -U postgres -d n8n > backups/n8n-$(date +%F).sql     # n8n only
tar czf backups/n8n-data-$(date +%F).tgz n8n-data
```

Restore: with a fresh empty `postgres-data/`, `docker compose up -d postgres`,
then `docker compose exec -T postgres psql -U postgres -f - < backups/postgres-<date>.sql`.
The dump recreates roles and databases, so expect "already exists" notices if
the init script ran. Extract `n8n-data`, start the rest. Requires the same
`N8N_ENCRYPTION_KEY`.

## 11. Webhook behavior (n8n 2.x)

- `/webhook-test/...` works only while *Listen for test event* is active.
- `/webhook/...` works only when the workflow is **published** (n8n 2.x renamed *Activate* to *Publish*).
- WAHA posts to `/webhook/waha`; the Webhook node must use `POST`.

## 12. Tooling (`.mcp.json`, `scripts/n8n-mcp.sh`)

Project MCP servers for Claude Code:

- `context7` (`npx @upstash/context7-mcp@latest`): current library docs.
- `playwright` (`npx @playwright/mcp@latest`): browser automation.
- `n8n-mcp`: runs `scripts/n8n-mcp.sh`, which sources `.env` (Claude Code does not), sets `N8N_API_URL=http://localhost:5678`, `N8N_API_KEY`, stdio mode, and execs `npx -y n8n-mcp@2.91.0`. Needs `N8N_API_KEY` set and Claude Code restarted.

## 13. Safety

- Use the test number only. The client's number goes in only at deploy time, with ban risk accepted in writing.
- No bulk or looped sends.
- No secrets, WhatsApp session data or real numbers in the repo.

## 14. Moving to a server

Not done yet. Required changes: set `WEBHOOK_URL` and `N8N_EDITOR_BASE_URL` in
`docker-compose.yml` to the public URL, remove `N8N_SECURE_COOKIE=false`, put a
reverse proxy with TLS in front, and use the amd64 WAHA tag
(`noweb-2026.9.2`).

## 15. Out of scope

- Workflow design, migration of existing workflows ("overflows"), WhatsApp send/receive logic.
- TypeScript helper service (none exists yet).
- External task runners.
