# wpp-automation-n8n

## Stack

WAHA (NOWEB engine) + n8n in one compose project. Image tags are pinned in `.env` (`WAHA_TAG`, `N8N_TAG`). Never use `latest`; change a tag only on purpose, after a backup.

The WAHA tag is an arm64 build on Apple Silicon (`noweb-arm-2026.9.2`); an amd64 VPS needs `noweb-2026.9.2`.

## First run

```
cp .env.example .env
# fill .env; generate secrets with:
openssl rand -hex 32
docker compose up -d
```

Store the secrets in the password manager. Losing `N8N_ENCRYPTION_KEY` makes saved n8n credentials unreadable.

Owner steps:

- Create the n8n owner account.
- Pair the `default` session with the **test number** in the WAHA dashboard.
- Set up Google OAuth with redirect URI `http://localhost:5678/rest/oauth2-credential/callback`. In Testing mode the refresh token expires after 7 days; publish the OAuth app for production.

## URLs

- n8n editor: `http://localhost:5678`
- WAHA dashboard: `http://localhost:3100/dashboard` (host port from `WAHA_HOST_PORT`)
- From inside containers: `http://waha:3000` and `http://n8n:5678/webhook/waha`
- WAHA API key header: `X-Api-Key`

## Daily commands

```
docker compose up -d
docker compose ps
docker compose logs -f <service>   # waha or n8n
docker compose restart <service>
docker compose stop
docker compose start
docker compose down
```

**Never run `docker compose down -v`: it deletes the WhatsApp session and all n8n data.**

## Backup / restore

Volume names carry the project prefix (`wpp-automation-n8n_`). Unprefixed names such as `n8n_data` would mount a new empty volume.

Backup (into `backups/`, git-ignored):

```
docker compose stop
mkdir -p backups
docker run --rm -v wpp-automation-n8n_n8n_data:/d:ro -v "$PWD/backups":/b alpine tar czf /b/n8n_data-$(date +%F).tgz -C /d .
docker run --rm -v wpp-automation-n8n_waha_sessions:/d:ro -v "$PWD/backups":/b alpine tar czf /b/waha_sessions-$(date +%F).tgz -C /d .
docker compose start
```

Restore (stack stopped; needs the same `N8N_ENCRYPTION_KEY` in `.env`):

```
docker compose stop
docker run --rm -v wpp-automation-n8n_n8n_data:/d -v "$PWD/backups":/b alpine sh -c 'rm -rf /d/* /d/..?* /d/.[!.]* ; tar xzf /b/n8n_data-YYYY-MM-DD.tgz -C /d'
docker run --rm -v wpp-automation-n8n_waha_sessions:/d -v "$PWD/backups":/b alpine sh -c 'rm -rf /d/* /d/..?* /d/.[!.]* ; tar xzf /b/waha_sessions-YYYY-MM-DD.tgz -C /d'
docker compose start
```

## Webhooks in n8n 2.x

- `/webhook-test/...` works only while *Listen for test event* is active.
- `/webhook/...` works only when the workflow is **published** (n8n 2.x renamed *Activate* to *Publish*).
- WAHA posts to `/webhook/waha` with event `message.any`, which includes messages sent from the phone itself (`fromMe`).
- The Webhook node must use `POST`.

## WAHA edition limits (checked 2026-10-05)

Since WAHA 2026.6.1 the former Plus features (unlimited sessions, media messages, all storages, built-in security) are in Core, so the pinned `2026.9.x` has no Core-only limits. Source: WAHA docs, *WAHA Plus* page.

## Safety

- Use the test number only.
- The client's number goes in only at deploy time, with the ban risk accepted in writing.
- No bulk or looped sends.
