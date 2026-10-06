#!/bin/sh
# One-command bootstrap for a fresh clone: ./scripts/setup.sh
# Idempotent. Creates .env (never overwrites existing values), data dirs, installs the
# WAHA community node, starts the stack, creates the example's tables and credentials,
# and imports + publishes the versioned workflows that are not in n8n yet.
set -eu
cd "$(dirname "$0")/.."

WAHA_NODE_PKG="@devlikeapro/n8n-nodes-waha@2025.2.9"
CHATBOT_WORKFLOW_ID=3zFS5yZDOZFAAhfM
# Credential ids referenced by workflows/*.json
CRED_POSTGRES_ID=qBw06fsYVSnHDIYZ
CRED_WAHA_ID=fLb4y6X1sdRn0lC8
CRED_OPENAI_ID=KFZp3oDrOgr20VBL

command -v docker >/dev/null || { echo "docker is required" >&2; exit 1; }
docker compose version >/dev/null || { echo "docker compose v2 is required" >&2; exit 1; }

# --- .env: create from the example, fill only empty keys -------------------------------
[ -f .env ] || { cp .env.example .env; chmod 600 .env; echo "created .env from .env.example"; }

secret() { openssl rand -hex "$1"; }

# set_default KEY VALUE: writes VALUE only if KEY is missing or empty
set_default() {
  key=$1
  val=$2
  current=$(grep -E "^${key}=" .env | tail -n1 | cut -d= -f2- || true)
  if [ -n "$current" ]; then
    return 0
  fi
  if grep -qE "^${key}=" .env; then
    tmp=$(mktemp)
    awk -v k="$key" -v v="$val" 'BEGIN{FS=OFS="="} $1==k && !done {print k "=" v; done=1; next} {print}' .env >"$tmp"
    cat "$tmp" >.env
    rm -f "$tmp"
  else
    printf '%s=%s\n' "$key" "$val" >>.env
  fi
}

case "$(uname -m)" in
  arm64 | aarch64) waha_tag=noweb-arm-2026.9.2 ;;
  *) waha_tag=noweb-2026.9.2 ;;
esac

set_default WAHA_TAG "$waha_tag"
set_default WAHA_HOST_PORT 3100
set_default WAHA_DASHBOARD_USER admin
set_default WAHA_DASHBOARD_PASSWORD "$(secret 12)"
set_default WAHA_API_KEY "$(secret 32)"
set_default N8N_TAG 2.41.7
set_default N8N_ENCRYPTION_KEY "$(secret 32)"
set_default TZ America/Sao_Paulo
set_default POSTGRES_TAG 17.11-alpine
set_default POSTGRES_PASSWORD "$(secret 24)"
set_default N8N_DB_PASSWORD "$(secret 24)"
set_default WAHA_DB_PASSWORD "$(secret 24)"
set_default REDIS_TAG 8.10.2-alpine
set_default REDIS_PASSWORD "$(secret 24)"
grep -qE '^N8N_API_KEY=' .env || echo 'N8N_API_KEY=' >>.env
grep -qE '^N8N_LICENSE_ACTIVATION_KEY=' .env || echo 'N8N_LICENSE_ACTIVATION_KEY=' >>.env
grep -qE '^OPENAI_API_KEY=' .env || echo 'OPENAI_API_KEY=' >>.env
grep -qE '^TEST_CHAT_IDS=' .env || echo 'TEST_CHAT_IDS=' >>.env

env_get() { grep -E "^$1=" .env | tail -n1 | cut -d= -f2-; }

# --- data dirs (git-ignored) -------------------------------------------------------------
mkdir -p n8n-data postgres-data redis-data workflows backups

# --- community node (shared by main and worker through ./n8n-data) -------------------------
if [ ! -d n8n-data/nodes/node_modules/@devlikeapro/n8n-nodes-waha ]; then
  echo "installing $WAHA_NODE_PKG"
  mkdir -p n8n-data/nodes
  [ -f n8n-data/nodes/package.json ] ||
    printf '{\n  "name": "installed-nodes",\n  "private": true,\n  "dependencies": {}\n}\n' >n8n-data/nodes/package.json
  docker compose run --rm --no-deps --entrypoint sh n8n -c \
    "cd /home/node/.n8n/nodes && npm install --save-exact $WAHA_NODE_PKG"
fi

# --- start -------------------------------------------------------------------------------
docker compose up -d --wait postgres redis
docker compose up -d

printf 'waiting for n8n'
i=0
until docker compose exec -T n8n wget -qO- http://localhost:5678/healthz >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -lt 60 ] || { echo; echo "n8n did not become healthy; see: docker compose logs n8n" >&2; exit 1; }
  printf '.'
  sleep 2
done
echo

# --- chatbot example tables (idempotent) ------------------------------------------------------
docker compose exec -T postgres psql -q -U n8n -d n8n -v ON_ERROR_STOP=1 -f - <scripts/sql/chatbot-car-rental.sql

n8n_db() { docker compose exec -T postgres psql -U n8n -d n8n -tAc "$1"; }
exists() { [ -n "$(n8n_db "SELECT 1 FROM $1 WHERE id = '$2'")" ]; }

# --- credentials: created from .env only when missing (never overwritten) ---------------------
creds=""
add_cred() { creds="${creds:+$creds,}$1"; }
exists credentials_entity "$CRED_POSTGRES_ID" ||
  add_cred "{\"id\":\"$CRED_POSTGRES_ID\",\"name\":\"Postgres account\",\"type\":\"postgres\",\"data\":{\"host\":\"postgres\",\"port\":5432,\"database\":\"n8n\",\"user\":\"n8n\",\"password\":\"$(env_get N8N_DB_PASSWORD)\",\"ssl\":\"disable\"}}"
exists credentials_entity "$CRED_WAHA_ID" ||
  add_cred "{\"id\":\"$CRED_WAHA_ID\",\"name\":\"WAHA account\",\"type\":\"wahaApi\",\"data\":{\"url\":\"http://waha:3000\",\"apiKey\":\"$(env_get WAHA_API_KEY)\"}}"
openai_key=$(env_get OPENAI_API_KEY)
if ! exists credentials_entity "$CRED_OPENAI_ID" && [ -n "$openai_key" ]; then
  add_cred "{\"id\":\"$CRED_OPENAI_ID\",\"name\":\"OpenAI account\",\"type\":\"openAiApi\",\"data\":{\"apiKey\":\"$openai_key\"}}"
fi
if [ -n "$creds" ]; then
  printf '[%s]\n' "$creds" | docker compose exec -T n8n sh -c \
    'cat >/tmp/creds.json && n8n import:credentials --input=/tmp/creds.json; status=$?; rm -f /tmp/creds.json; exit $status' ||
    echo "credential import failed; create the owner account in n8n first, then rerun this script" >&2
fi

# --- workflows: import only the ones not in n8n yet (never overwrites UI edits) --------------
# <TEST_CHAT_ID> in the JSON is replaced by TEST_CHAT_IDS from .env (the bot's allow-list).
test_chat_ids=$(env_get TEST_CHAT_IDS)
docker compose exec -T n8n sh -c 'rm -rf /tmp/wf && mkdir -p /tmp/wf'
imported=""
for f in workflows/*.json; do
  [ -f "$f" ] || continue
  id=$(sed -n 's/^  "id": "\([^"]*\)".*/\1/p' "$f" | head -n1)
  exists workflow_entity "$id" && continue
  sed "s/<TEST_CHAT_ID>/${test_chat_ids:-<TEST_CHAT_ID>}/" "$f" |
    docker compose exec -T n8n sh -c "cat >/tmp/wf/$(basename "$f")"
  imported="$imported $id"
done
if [ -n "$imported" ]; then
  if docker compose exec -T n8n n8n import:workflow --separate --input=/tmp/wf; then
    case "$imported" in
      *"$CHATBOT_WORKFLOW_ID"*)
        docker compose exec -T n8n n8n publish:workflow --id="$CHATBOT_WORKFLOW_ID"
        docker compose restart n8n n8n-worker >/dev/null # CLI publish takes effect on restart
        ;;
    esac
  else
    echo "workflow import failed; create the owner account in n8n first, then rerun this script" >&2
  fi
fi
docker compose exec -T n8n rm -rf /tmp/wf

host_port=$(env_get WAHA_HOST_PORT)
cat <<EOF

Stack is up.
  n8n editor:     http://localhost:5678
  WAHA dashboard: http://localhost:${host_port}/dashboard (credentials in .env)

Owner steps (cannot be automated):
  1. Create the n8n owner account, then rerun this script (credentials + workflows need it).
  2. Pair the 'default' WAHA session with the TEST number.
  3. Put OPENAI_API_KEY and TEST_CHAT_IDS (comma-separated chat ids, e.g. <id>@lid or
     <number>@c.us) in .env before the first rerun; the bot only answers those chats.
  4. Optional, free: unlock Debug in editor. In n8n: Settings > Usage and plan > Unlock (email),
     then put the emailed key in N8N_LICENSE_ACTIVATION_KEY in .env and run:
     docker compose up -d n8n n8n-worker
  5. Optional MCP: n8n Settings > n8n API > create key, put it in N8N_API_KEY in .env.
  6. Back up .env (N8N_ENCRYPTION_KEY loss makes saved credentials unreadable).
EOF
