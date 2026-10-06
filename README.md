# wpp-automation-n8n

## Stack

WAHA (NOWEB engine) + n8n (queue mode: `n8n` main + `n8n-worker`) + Postgres + Redis in one compose project. Image tags are pinned in `.env` (`WAHA_TAG`, `N8N_TAG`, `POSTGRES_TAG`, `REDIS_TAG`). Postgres and Redis publish no host ports (internal network only). Never use `latest`; change a tag only on purpose, after a backup.

The WAHA tag is an arm64 build on Apple Silicon (`noweb-arm-2026.9.2`); an amd64 VPS needs `noweb-2026.9.2`.

## First run

```
git clone <repo> && cd wpp-automation-n8n
./scripts/setup.sh
```

Requires Docker with Compose v2 and `openssl`. The script is idempotent: it creates `.env` (generates secrets, picks the WAHA tag for the CPU arch, never overwrites existing values), creates the data dirs, installs the WAHA community node, starts Postgres, Redis, WAHA, n8n and the worker, creates the chatbot example's tables, creates the `Postgres account`, `WAHA account` and `OpenAI account` credentials from `.env` when missing, imports the `workflows/*.json` not yet in n8n (replacing `<TEST_CHAT_ID>` with `TEST_CHAT_IDS`) and publishes the chatbot. Run it once, create the owner account, fill `OPENAI_API_KEY` and `TEST_CHAT_IDS` in `.env`, run it again: the example is live. On a new server, set `WEBHOOK_URL`/`N8N_EDITOR_BASE_URL` in `docker-compose.yml` to the public URL and put a reverse proxy with TLS in front.

Store the secrets in the password manager. Losing `N8N_ENCRYPTION_KEY` makes saved n8n credentials unreadable.

Owner steps:

- Create the n8n owner account.
- Pair the `default` session with the **test number** in the WAHA dashboard.
- Set up Google OAuth with redirect URI `http://localhost:5678/rest/oauth2-credential/callback`. In Testing mode the refresh token expires after 7 days; publish the OAuth app for production.

## URLs

- n8n editor: `http://localhost:5678`
- WAHA dashboard: `http://localhost:3100/dashboard` (host port from `WAHA_HOST_PORT`)
- From inside containers: `http://waha:3000` and `http://n8n:5678/webhook/d8dddf0c-f764-4853-b363-4a188b7a40e6/waha` (the chatbot's WAHA Trigger)
- WAHA API key header: `X-Api-Key`

## Daily commands

```
docker compose up -d
docker compose ps
docker compose logs -f <service>   # waha, n8n, n8n-worker, postgres or redis
docker compose restart <service>
docker compose stop
docker compose start
docker compose down
```

**Never run `docker compose down -v`: it deletes the WhatsApp session and all n8n data.**

## Persistence

Runtime data lives on the host as bind mounts, outside the containers and git-ignored:

- `postgres-data/` → Postgres data: n8n database, WAHA sessions and media (no more `database.sqlite`)
- `redis-data/` → Redis AOF (n8n queue)
- `n8n-data/` → `/home/node/.n8n` (config, community nodes; shared by main and worker)
- `gateway-data/` → legacy WAHA local sessions, no longer mounted. Kept on disk as rollback only.

Chatbot example tables: `scripts/sql/chatbot-car-rental.sql`, applied by `scripts/setup.sh`.

WAHA sessions moved to Postgres (`WHATSAPP_SESSIONS_POSTGRESQL_URL`, media via `WAHA_MEDIA_STORAGE=POSTGRESQL`). WAHA creates extra databases (`waha_<namespace>`, one per session) with the `waha` role, which therefore has CREATEDB. A session paired before the move has to be paired again.

The init script `postgres/init/01-create-databases.sh` creates the `n8n` and `waha` roles/databases and runs only on an empty `postgres-data/`. Changing `N8N_DB_PASSWORD`/`WAHA_DB_PASSWORD` later needs `ALTER ROLE`.

Versioned files:

- `workflows/` → `/workflows` inside the n8n container. Export/import workflow JSON here:

```
docker compose exec n8n n8n export:workflow --all --separate --output=/workflows/
docker compose exec n8n n8n import:workflow --separate --input=/workflows/
```

Never use `export:credentials` into `workflows/`. Importing overwrites workflows with the same id.

## Community nodes

Installed in `n8n-data/nodes/` (not versioned, so reinstall after recreating the environment):

- `@devlikeapro/n8n-nodes-waha@2025.2.9` (WAHA node)

```
docker compose exec -w /home/node/.n8n/nodes n8n npm install --save-exact @devlikeapro/n8n-nodes-waha@2025.2.9
docker compose restart n8n
```

Credentials in n8n: URL `http://waha:3000`, API key from `WAHA_API_KEY`.

## Backup / restore

Backup (into `backups/`, git-ignored):

```
mkdir -p backups
docker compose exec -T postgres pg_dumpall -U postgres > backups/postgres-$(date +%F).sql   # everything, incl. WAHA per-session databases
docker compose exec -T postgres pg_dump -U postgres -d n8n > backups/n8n-$(date +%F).sql     # n8n only
tar czf backups/n8n-data-$(date +%F).tgz n8n-data
```

Redis only holds the job queue; it needs no backup.

Restore: with a fresh empty `postgres-data/`, start only postgres (`docker compose up -d postgres`), then `docker compose exec -T postgres psql -U postgres -f - < backups/postgres-<date>.sql` (the dump recreates roles and databases, so move the init script aside or restore into a data dir created by it and expect "already exists" notices). Extract `n8n-data`, start the rest. Needs the same `N8N_ENCRYPTION_KEY` in `.env`.

## Queue mode

- `n8n` (main: editor, API, webhooks) enqueues executions in Redis; `n8n-worker` runs them. Manual executions are offloaded to workers (`OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true`).
- Worker parallelism: `N8N_WORKER_CONCURRENCY` (default 10). Scale with `docker compose up -d --scale n8n-worker=2`.
- Binary data uses `N8N_DEFAULT_BINARY_DATA_MODE=database`: filesystem mode is not supported with workers.
- Main and worker share the image tag, `N8N_ENCRYPTION_KEY` and `./n8n-data` (community nodes). After installing a community node, restart both `n8n` and `n8n-worker`.
- Workers get a 60s graceful stop period. Code nodes use n8n's default (internal) task runner mode; external runners need the separate `n8nio/runners` image and are not set up.

## n8n MCP (SDD)

`.mcp.json` registers `n8n-mcp` (pinned `n8n-mcp@2.91.0`) through `scripts/n8n-mcp.sh`, which loads `.env` (Claude Code does not) and points at `http://localhost:5678`.

Owner steps: n8n Settings > n8n API > create an API key, put it in `N8N_API_KEY` in `.env`, restart Claude Code.


## Webhooks in n8n 2.x

- `/webhook-test/...` works only while *Listen for test event* is active.
- `/webhook/...` works only when the workflow is **published** (n8n 2.x renamed *Activate* to *Publish*).
- WAHA posts event `message.any` (includes messages sent from the phone itself, `fromMe`) to the WAHA Trigger node of `@devlikeapro/n8n-nodes-waha`. Its URL is `/webhook/<webhookId>/waha`; the `webhookId` is fixed in the workflow JSON and matches `WHATSAPP_HOOK_URL` in `docker-compose.yml`.
- The trigger has one output per WAHA event; only `message.any` is wired. It cannot check a secret header, so inbound safety relies on n8n being reachable only from localhost and the Docker network.

## WAHA edition limits (checked 2026-10-05)

Since WAHA 2026.6.1 the former Plus features (unlimited sessions, media messages, all storages, built-in security) are in Core, so the pinned `2026.9.x` has no Core-only limits. Source: WAHA docs, *WAHA Plus* page.

## Safety

- Use the test number only.
- The client's number goes in only at deploy time, with the ban risk accepted in writing.
- No bulk or looped sends.
