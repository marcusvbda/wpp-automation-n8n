#!/bin/sh
# Launches the n8n-mcp server (czlonkowski) over stdio for Claude Code.
# Claude Code does not load .env, so source it here. Reads N8N_API_KEY from .env.
set -eu
cd "$(dirname "$0")/.."

set -a
# shellcheck disable=SC1091
. ./.env
set +a

export MCP_MODE=stdio
export LOG_LEVEL=error
export DISABLE_CONSOLE_OUTPUT=true
export N8N_API_URL=http://localhost:5678
export N8N_API_KEY="${N8N_API_KEY:-}"
# The default strict SSRF gate blocks localhost; moderate allows it (private IPs and metadata stay blocked).
export WEBHOOK_SECURITY_MODE=moderate

exec npx -y n8n-mcp@2.91.0
