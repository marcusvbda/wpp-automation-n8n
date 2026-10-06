#!/bin/sh
# One-command bootstrap for a fresh clone: ./scripts/setup.sh
# Idempotent. Creates .env (never overwrites existing values), data dirs, installs the
# WAHA community node, starts the stack and imports the versioned workflows.
set -eu
cd "$(dirname "$0")/.."

WAHA_NODE_PKG="@devlikeapro/n8n-nodes-waha@2025.2.9"

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

# --- workflows (imported inactive; overwrites workflows with the same id) -------------------
if ls workflows/*.json >/dev/null 2>&1; then
  docker compose exec -T n8n n8n import:workflow --separate --input=/workflows/ ||
    echo "workflow import failed; create the owner account in n8n first, then rerun this script" >&2
fi

host_port=$(grep -E '^WAHA_HOST_PORT=' .env | cut -d= -f2-)
cat <<EOF

Stack is up.
  n8n editor:     http://localhost:5678
  WAHA dashboard: http://localhost:${host_port}/dashboard (credentials in .env)

Owner steps (cannot be automated):
  1. Create the n8n owner account.
  2. Create the WAHA credential in n8n (URL http://waha:3000, API key = WAHA_API_KEY in .env).
  3. Pair the 'default' WAHA session with the TEST number.
  4. Optional, free: unlock Debug in editor. In n8n: Settings > Usage and plan > Unlock (email),
     then put the emailed key in N8N_LICENSE_ACTIVATION_KEY in .env and run:
     docker compose up -d n8n n8n-worker
  5. Optional MCP: n8n Settings > n8n API > create key, put it in N8N_API_KEY in .env.
  6. Back up .env (N8N_ENCRYPTION_KEY loss makes saved credentials unreadable).
EOF
