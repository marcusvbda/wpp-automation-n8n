# Plan — Advanced workflow example

Source spec: `docs/features/advanced-workflow-example/spec.md` · SHA-256 `860ad40d2990b6cd25b9408385949b79ef34b628b1da15aa7a930d59f477be1d`
Run phases with `/execute-phases docs/features/advanced-workflow-example/plan.md <phases>` — one or a few per
session. Phase status is updated in place in this file.

Owner instruction for this plan: build the workflows **through the n8n MCP**
(`n8n-mcp`, czlonkowski, pinned `2.91.0`). The live n8n instance is where
workflows are created/validated; `workflows/*.json` are CLI exports of them.

## Status board

| Phase | Title                                              | Role          | Depends on       | Size | Status     |
| ----- | -------------------------------------------------- | ------------- | ---------------- | ---- | ---------- |
| 1     | Enable the n8n MCP for the executor                | n8n-workflows | none             | S    | DONE       |
| 2     | Persistent stores and credentials                  | n8n-workflows | none             | S    | DONE       |
| 3     | Shared error workflow                              | n8n-workflows | 1                | S    | DONE       |
| 4     | Ingress sub-workflow (filter + normalize)          | n8n-workflows | 1, 3             | S    | DONE       |
| 5     | Guards sub-workflow (fromMe, direct, allow-list, dedupe, rate limit) | n8n-workflows | 1, 2, 3 | M | DONE |
| 6     | Reply sub-workflow (AI Agent + Postgres memory)    | n8n-workflows | 1, 2, 3          | S    | DONE        |
| 7     | Send sub-workflow (seen → typing → delay → send)   | n8n-workflows | 1, 2, 3          | S    | DONE        |
| 8     | Authenticated inbound webhook (compose + env)      | n8n-workflows | none             | S    | DONE       |
| 9     | Orchestrator workflow with config node             | n8n-workflows | 4, 5, 6, 7, 8    | M    | DONE        |
| 10    | Publish, smoke tests, verification and report      | n8n-workflows | 9                | M    | IN_PROGRESS|

## Audit — 2026-10-06

| Check | Result |
| ----- | ------ |
| Running stack | `n8n`/`n8n-worker` `n8nio/n8n:2.41.7`, `waha` `devlikeapro/waha:noweb-arm-2026.9.2`, `postgres:17.11-alpine`, `redis:8.10.2-alpine` — all running |
| n8n mode | Queue mode (`EXECUTIONS_MODE: queue`, Redis, 1 worker, `OFFLOAD_MANUAL_EXECUTIONS_TO_WORKERS=true`). Confirms A3: no static data / in-process state |
| n8n DB | Postgres DB `n8n`, role `n8n` (owner of the DB). The spec's stores go there |
| WAHA webhook | `WHATSAPP_HOOK_URL=http://n8n:5678/webhook/waha`, `WHATSAPP_HOOK_EVENTS=message.any`, **no secret/HMAC/custom header** (OD2 → D2) |
| WAHA auth | `WAHA_API_KEY` set in compose; header `X-Api-Key` (README) |
| WAHA endpoints (context7, WAHA docs) | `POST /api/sendSeen`, `/api/startTyping`, `/api/stopTyping`, `/api/sendText`; body `{ session, chatId[, text] }`. Global webhook custom headers via `WHATSAPP_HOOK_CUSTOM_HEADERS=Name:Value;…`, HMAC via `WHATSAPP_HOOK_HMAC_KEY` |
| Community nodes | `@devlikeapro/n8n-nodes-waha@2025.2.9` installed. **Not used**: its base URL lives in the credential, which would break R2 (`wahaBaseUrl` in the config node). Plan uses HTTP Request nodes |
| n8n MCP | Registered in `.mcp.json` (`scripts/n8n-mcp.sh` → `npx -y n8n-mcp@2.91.0`, `N8N_API_URL=http://localhost:5678`, key `N8N_API_KEY` from `.env`). **Not enabled**: `.claude/settings.json` `enabledMcpjsonServers` lists only `context7`, `playwright`; no `n8n-mcp` tools in this session → D4 |
| n8n MCP tools (context7) | `n8n_create_workflow`, `n8n_update_partial_workflow` (addNode/updateNode/addConnection/updateSettings/…), `n8n_validate_workflow`, `validate_workflow`, `n8n_test_workflow`, `n8n_executions`, `n8n_get_workflow`, `search_nodes`, `get_node`, `n8n_health_check` |
| `n8n-workflows` subagent | `tools: Read, Write, Edit, Bash, Grep, Glob`, `maxTurns: 15` — **cannot call MCP tools** → D4 |
| `N8N_API_KEY` in `.env` | Not verifiable (reading `.env` is denied by settings). Owner confirms |
| `.env.example` keys | WAHA_*, N8N_TAG, N8N_ENCRYPTION_KEY, TZ, POSTGRES_*, N8N_DB_PASSWORD, WAHA_DB_PASSWORD, REDIS_*, N8N_WORKER_CONCURRENCY, N8N_LICENSE_ACTIVATION_KEY, N8N_API_KEY. **Missing**: webhook secret (D2), OpenAI key (goes in an n8n credential, not `.env`) |
| `workflows/` | Empty (`.gitkeep`). No error workflow exists yet (OD1 → D1) |
| n8n credentials | Unknown/none needed by this feature exist yet. Needed: Postgres, WAHA API key (Header Auth), OpenAI, webhook secret (Header Auth) |
| `package.json` / `services/` | Absent. No npm scripts exist |
| Checks that exist (`project-core`) | `jq empty workflows/*.json`; secrets grep `grep -rnEi "apikey\|api_key\|token\|Bearer \|@s\.whatsapp\.net" workflows/`; `docker compose config -q` |
| Import path | `scripts/setup.sh` imports `workflows/*.json` (inactive) with `--separate` → each file must be a single workflow object |
| Spec hygiene | Status DRAFT; sections jump 6 → 9 (no 7/8); ACs present; open decisions OD1–OD3 carried as D1–D3 |

## Owner decisions

All resolved by the owner on 2026-10-06. No phase is blocked.

### D1 — Where does the error workflow notify the owner? (spec OD1)

**Resolved: A — n8n execution log only.** The error workflow formats a PII-free
summary and ends; no credential, no address in the repo. Email can be added
later as one node. (Rejected: log + email; WhatsApp to the test chat.)

### D2 — How is the inbound webhook authenticated? (spec OD2)

**Resolved: A — WAHA custom header.** Compose
`WHATSAPP_HOOK_CUSTOM_HEADERS: X-Waha-Webhook-Secret:${WAHA_WEBHOOK_SECRET}`,
new `.env` key `WAHA_WEBHOOK_SECRET` (appended only if missing, generated with
`openssl rand -hex 32`), Webhook node uses Header Auth credential
`WAHA webhook secret` → n8n answers 403 before any execution (F7).
(Rejected: WAHA HMAC; Docker network only.)

### D3 — Keep `message.any` or switch to `message`? (spec OD3)

**Resolved: A — keep `message.any`.** No compose change for events; Guards
drops `fromMe`.

### D4 — How does the executor get the n8n MCP?

**Resolved: A — enable it.** Phase 1 adds `"n8n-mcp"` to
`enabledMcpjsonServers` in `.claude/settings.json`, adds `mcp__n8n-mcp__*` and
`mcp__context7__*` to the `tools:` of `.claude/agents/n8n-workflows.md`, and
raises its `maxTurns` 15 → 30. Owner creates the n8n API key into
`N8N_API_KEY` in `.env` and restarts Claude Code.

### D5 — Allow-list while testing

**Resolved: no chat-id filter for now ("estamos tentando").**
`restrictToAllowList` defaults to **`false`**; `allowedChatIds` stays in the
config node with the placeholder `<TEST_CHAT_ID>` (no real id anywhere, so no
export scrubbing). The allow-list guard is still built (Phase 5) so it can be
switched on by editing the config node; AC13 is tested by switching it on
temporarily (Phase 10). Consequence accepted by the owner: any contact who
writes to the paired number gets a reply. Deviation from spec §3 (default
`true`) and R8 ("test sends gated by an allow-list") — Phase 10 proposes the
spec note.

### D6 — Rate-limit reference point (spec F5/AC14)

**Resolved: A — claim on accept.** Atomically claim the chat's slot when a
message passes the guards (`last_reply_at = now()` only if the previous value
is older than `perChatMinIntervalSeconds`) and re-stamp after a successful
send. Two quick messages → one reply; race-free across workers.

### D7 — Which WAHA session replies?

**Resolved: A — the session from the webhook payload.** Seen/typing/send use
`body.session` of the inbound event (the session that received the message).
The normalized message gains a `session` field, and `wahaSession` is
**removed** from the config node (16 fields). Deviation from spec §3 (config
table, normalized shape) and AC9 ("session name" in the config node) — Phase 10
proposes the spec note.

## Global constraints (every phase)

- `CLAUDE.md` hard rules: git read-only (commits only via `/execute-phases`),
  no destructive Docker/DB ops, no dependency/image/version changes, no tests
  written, English everywhere except the two pt-BR fixed replies and the
  default reply language.
- **Build through the n8n MCP** (`n8n-mcp`): look up node types/typeVersions
  with `search_nodes`/`get_node` (and context7 for n8n/WAHA docs) before using
  them; validate the JSON with `validate_workflow` before
  `n8n_create_workflow`; edit with `n8n_update_partial_workflow`; finish with
  `n8n_validate_workflow` (profile `runtime`) showing 0 errors. **Never**
  `n8n_delete_workflow` or full-overwrite a workflow this feature didn't
  create. Workflows are created **inactive**; only Phase 10 publishes, with the
  owner's go.
- **Export after each build phase** (AC16):
  `docker compose exec -T n8n n8n export:workflow --id=<id> --pretty --output=/workflows/<file>.json`.
  If the CLI writes an array, unwrap to the single object (`jq '.[0]'`) — the
  setup script imports with `--separate`. **Always drop `.shared`** (`jq 'del(.shared)'`):
  the export embeds the owner's project name (full name + email) there — PII. No `pinData` (check
  `jq 'has("pinData") and (.pinData|length>0)'` is `false`), credentials as
  `{ id, name }` only, workflow `name` = file basename. Never
  `export:credentials`.
- Credential ids for node JSON: read with
  `docker compose exec -T postgres psql -U n8n -d n8n -c "select id, name, type from credentials_entity"`
  (never select the `data` column).
- Every workflow's settings: `errorWorkflow` = id of `system-error-handler`
  (Phase 3), `executionOrder: "v1"`; sub-workflows also
  `callerPolicy: "workflowsFromSameOwner"`.
- **R2/AC9:** no config value (model name, temperature, token cap, delays,
  base URL, memory window, rate-limit interval, replies, business rules,
  allow-list) is written anywhere except "Load workflow config".
  Sub-workflows read them from the `config` object they receive. The WAHA
  session is never a literal anywhere: it comes from the inbound payload (D7).
- **Canvas (R7):** sticky-note section headers, left-to-right, English
  verb-first node names (exactly as in each contract), no crossing
  connections; each sub-workflow has a sticky note with its input/output
  contract.
- **No live sends before Phase 10.** No real phone numbers, chat ids, names
  or message bodies in the repo; fixtures use obviously fake ids
  (`000000000000@c.us`, `120363000000000000@g.us`, `000000000000@newsletter`,
  `status@broadcast`) and live only in the session scratchpad.
- SQL uses query parameters (`$1`, `$2` via the Postgres node's query
  replacements), never string-interpolated values.
- Send-message nodes: `retryOnFail: false`. LLM: `maxRetries: 0`.
- Cross-phase data contracts (fixed):
  - **Config object** (`config`): the fields of spec §3 **minus `wahaSession`**
    (16 fields, D7), same names/types; `restrictToAllowList` defaults to
    `false` (D5).
  - **Normalized message** (`message`): `{ messageId, session, chatId, senderId, fromMe, type, text, timestamp, isGroup, isDirect }`
    (`session` added, D7);
    `type ∈ text|image|audio|video|sticker|document|location|contact|reaction|poll|unknown`.
  - Ingress returns `{ accepted: boolean, reason?: "not-a-message-event" | "not-a-user-message", message?: Message }`.
  - Guards returns `{ pass: boolean, reason: string }`.
  - Reply returns `{ ok: true, reply: string }` or `{ ok: false, error: string }`.
  - Send takes `{ config, session, chatId, text, meta }` and returns `{ sent: boolean, error?: string, meta }` (`meta` echoed unchanged).
- **Live replies:** with no allow-list (D5), the published bot answers any
  direct chat that writes to the paired number. The owner accepted this.
  Synthetic test payloads must therefore **never** use a fake *direct* chat id
  while `restrictToAllowList` is `false`: that would call the LLM and WAHA
  `sendText` to a made-up number.

## Acceptance-criteria coverage

| AC | Phases |
| -- | ------ |
| AC1 text → exactly one `gpt-4o-mini` reply using `businessRules` | 6, 7, 9, 10 |
| AC2 group → no WAHA/LLM call, no memory/dedupe row | 4, 5, 9, 10 |
| AC3 broadcast/status/channel or `fromMe` → no reply, no LLM | 4, 5, 10 |
| AC4 duplicate `messageId` → one reply | 2, 5, 10 |
| AC5 earlier context used; survives restart | 2, 6, 10 |
| AC6 no history bleed between chats | 6, 10 |
| AC7 seen → start typing → stop typing → send, clamped delay ± jitter | 7, 10 |
| AC8 config edits take effect without touching other nodes | 6, 7, 9, 10 |
| AC9 config values only in config node; no secrets/real numbers | 3–9, 10 |
| AC10 covered fact stated (SUV R$ 229); uncovered → human agent | 9, 10 |
| AC11 booking: collect city/dates/category/name, human confirms | 9, 10 |
| AC12 non-text → no LLM, `unsupportedTypeReply` once with typing | 4, 7, 9, 10 |
| AC13 not allow-listed → nothing sent | 5, 10 |
| AC14 second message within interval → no reply | 2, 5, 7, 10 |
| AC15 LLM failure → error workflow once + `failureReply` once, no retry | 3, 6, 9, 10 |
| AC16 separate files, sticky headers, shared error workflow in settings | 3–7, 9, 10 |

## Phases

### Phase 1 — Enable the n8n MCP for the executor

Status: DONE
Evidence: `enabledMcpjsonServers` += `n8n-mcp`; `n8n-workflows` agent tools += `mcp__n8n-mcp__*`, `mcp__context7__*`, `maxTurns: 30`; `scripts/n8n-mcp.sh` exports `WEBHOOK_SECURITY_MODE=moderate` (default strict SSRF gate blocked `localhost:5678`). Fixes found on the way: first `npx` install takes ~33 s (> Claude Code's 30 s connect timeout) and left a broken npx cache entry — removed and reinstalled, warm start ~4 s. Stdio probe: `n8n_health_check` success/status ok, `n8n_list_workflows` success (3 pre-existing owner workflows — never touched). `jq empty .claude/settings.json`, `sh -n scripts/n8n-mcp.sh` OK; `code-reviewer` APPROVED. Session tools appear after `/mcp` reconnect or a Claude Code restart.
Role: n8n-workflows (config edit; can be done by the orchestrator) · Depends on: none · Covers: — (enabler) · Size: S
Spec: owner instruction ("usando o mcp do n8n"), §2 R7

**Goal.** The executing session and the `n8n-workflows` subagent can call the
`n8n-mcp` tools against the local n8n.

**Contract (D4 = A).**

- `.claude/settings.json`: `enabledMcpjsonServers` → `["context7", "playwright", "n8n-mcp"]`. Nothing else changes.
- `.claude/agents/n8n-workflows.md` frontmatter: `tools: Read, Write, Edit, Bash, Grep, Glob, mcp__n8n-mcp__*, mcp__context7__*`; `maxTurns: 30`. Body unchanged.
- Owner steps: n8n Settings > n8n API > create key → `N8N_API_KEY=` in `.env`; restart Claude Code.

**Steps.**

1. Apply the two edits.
2. Ask the owner to do the owner steps and restart.
3. After restart: call `n8n_health_check` and `n8n_list_workflows`.

**Done when.**

- `n8n_health_check` reports the API reachable/authenticated.
- `n8n_list_workflows` returns (an empty or existing list) without auth error.
- `jq empty .claude/settings.json` passes.

**Not in this phase.** Any workflow or credential.

### Phase 2 — Persistent stores and credentials

Status: DONE
Evidence: `scripts/sql/chatbot-car-rental.sql` applied 3× as role `n8n` (runs 2–3: "already exists, skipping"); PKs `chatbot_processed_messages_pkey`, `chatbot_chat_reply_state_pkey` present, tables owned by `n8n` in `public`; README line added; `code-reviewer` APPROVED. Credentials (2026-10-06): existing `OpenAI account` (openAiApi) and `WAHA account` (wahaApi, sends `X-Api-Key` via generic `authenticate`) are reused instead of creating duplicates; The owner created the Postgres credential as **`Postgres account`** (id `qBw06fsYVSnHDIYZ`); Phases 5–7 use it.
Role: n8n-workflows · Depends on: none · Covers: AC4, AC5, AC14 (stores) · Size: S
Spec: §3 Persistent stores, A3, R4, R8

**Goal.** The dedupe and rate-limit tables exist in the `n8n` database, and
the credentials every later phase references exist with fixed names.

**Contract.**

- New file `scripts/sql/chatbot-car-rental.sql` (idempotent, additive only):

  ```sql
  CREATE TABLE IF NOT EXISTS chatbot_processed_messages (
    message_id   text        PRIMARY KEY,
    processed_at timestamptz NOT NULL DEFAULT now()
  );
  CREATE TABLE IF NOT EXISTS chatbot_chat_reply_state (
    chat_id       text        PRIMARY KEY,
    last_reply_at timestamptz NOT NULL
  );
  ```

  Conversation memory is **not** created here: the Postgres Chat Memory node
  creates `chatbot_chat_histories` itself (Phase 6).
- Apply as role `n8n` (owner of DB `n8n`) over the local socket:
  `docker compose exec -T postgres psql -U n8n -d n8n -v ON_ERROR_STOP=1 -f - < scripts/sql/chatbot-car-rental.sql`.
- Credentials the **owner** creates in the n8n UI (exact names; executor never
  sees values):
  - `Postgres account` — Postgres; host `postgres`, port `5432`, database `n8n`, user `n8n`, password = `N8N_DB_PASSWORD`, SSL disabled.
  - ~~`WAHA API key`~~ → reuse existing `WAHA account` (`wahaApi`) as the
    HTTP Request predefined credential type; fall back to a Header Auth
    `WAHA API key` (name `X-Api-Key`) only if the HTTP Request node can't use
    `wahaApi` (Phase 7 checks).
  - ~~`OpenAI API`~~ → reuse existing `OpenAI account` (`openAiApi`).
- One line in `README.md` under "Persistence" pointing to the SQL file and the
  apply command.

**Steps.**

1. Write the SQL file; apply it.
2. Ask the owner to create the three credentials; confirm with the
   `credentials_entity` query (names/types only).
3. Add the README line.

**Done when.**

- `docker compose exec -T postgres psql -U n8n -d n8n -c "\d chatbot_processed_messages" -c "\d chatbot_chat_reply_state"` shows both tables with the PKs above.
- Re-running the apply command succeeds with no changes (idempotent).
- `select name, type from credentials_entity` lists the three names.

**Not in this phase.** Webhook secret credential (Phase 8), any workflow.

### Phase 3 — Shared error workflow

Status: DONE
Evidence: created via n8n-mcp, id **`FF0x666oa1bfHLDI`** (use as `errorWorkflow` everywhere), inactive; nodes "On workflow error" (errorTrigger v1) → "Summarize error" (Set v3.5, 7 fields) + sticky; `validate_workflow`/`n8n_validate_workflow` 0 errors 0 warnings; exported, unwrapped from array, `.shared` (owner name+email) stripped; `jq empty` OK, pinData empty, secrets grep 0 hits, no PII; `code-reviewer` APPROVED.
Role: n8n-workflows · Depends on: 1 · Covers: AC15, AC16 (error workflow part), AC9 · Size: S
Spec: §4 F4, F6; R8; OD1

**Goal.** `system-error-handler` exists in n8n and in `workflows/`, so every
later workflow can set it as its error workflow.

**Contract (D1 = A).**

- Workflow/file: `system-error-handler` → `workflows/system-error-handler.json`.
- Nodes: `Error Trigger` ("On workflow error") → Edit Fields "Summarize error"
  with exactly: `workflowName` (`$json.workflow.name`), `workflowId`,
  `executionId` (`$json.execution.id`), `executionUrl` (`$json.execution.url`),
  `failedNode` (`$json.execution.lastNodeExecuted`), `errorMessage`
  (`$json.execution.error.message`), `occurredAt` (`$now.toISO()`). No message
  bodies, chat ids or phone numbers.
- Sticky notes: "Error handling — notifies the owner (execution log only, D1)"
  and a note that it never sends to end users.
- Settings: `executionOrder: "v1"`; it must not set itself as its own error
  workflow.

**Steps.**

1. `get_node` for `n8n-nodes-base.errorTrigger` and `n8n-nodes-base.set` (current typeVersions).
2. `validate_workflow` → `n8n_create_workflow` → `n8n_validate_workflow`.
3. Export to `workflows/system-error-handler.json`; record its id in the
   plan's Phase 3 notes for later phases.

**Done when.**

- `n8n_validate_workflow` 0 errors.
- `jq empty workflows/*.json` passes; `jq -r .name workflows/system-error-handler.json` = `system-error-handler`.
- Secrets grep has no hits in this file.

**Not in this phase.** Wiring other workflows to it (each phase does its own).

### Phase 4 — Ingress sub-workflow (filter + normalize)

Status: DONE
Evidence: created via n8n-mcp, id **`bxDRnRLTIloMn7tY`**, inactive, errorWorkflow `FF0x666oa1bfHLDI`; `n8n_validate_workflow` 0 errors 0 warnings; Code node 29 lines, pure; local `node` sanity on 8 fake payloads (text, image, group, status, newsletter, fromMe, ephemeral-wrapped text → text, protocolMessage → ignored); export unwrapped, `.shared` stripped, `jq empty` OK, no PII, secrets grep: 1 expected hit (`@s.whatsapp.net` suffix in code). Review round 1 → APPROVED with 2 fixes applied (below the product boundary): unwrap `ephemeralMessage`/`viewOnceMessage(V2)`/`editedMessage`; `protocolMessage` (delete/edit events) → `{ accepted: false, reason: "not-a-user-message" }` (F2: not a user message, so no unsupported reply). Risk noted: the NOWEB `_data.message` shape isn't documented by WAHA (raw WhatsApp proto) — Phase 10 confirms with real messages.
Role: n8n-workflows · Depends on: 1, 3 · Covers: AC2, AC3, AC12 (type detection), AC16 · Size: S
Spec: §3 Normalized message shape, §4 item 2, R1, R8, OD3

**Goal.** A sub-workflow that turns a raw WAHA webhook body into the
normalized message, or says why it isn't one.

**Contract.**

- Workflow/file: `chatbot-waha-car-rental-ingress` → `workflows/chatbot-waha-car-rental-ingress.json`.
- Input (trigger "When called by orchestrator", Execute Workflow Trigger,
  input source passthrough): `{ config, body }`; `body` is the WAHA webhook
  JSON `{ event, session, payload }`.
- Nodes, left to right:
  1. "When called by orchestrator"
  2. If "Keep message events": `body.event` is `message` or `message.any`.
     False → Edit Fields "Return ignored event" `{ accepted: false, reason: "not-a-message-event" }`.
  3. Code "Normalize WAHA message" (pure, < 30 lines, no network/env) →
     `{ accepted: true, message }` with:
     - `messageId` = `payload.id`
     - `session` = `body.session` (D7: replies go out on this session)
     - `fromMe` = `payload.fromMe === true`
     - `chatId` = `fromMe ? payload.to : payload.from`
     - `senderId` = `payload.participant ?? payload.from`
     - `timestamp` = `payload.timestamp`
     - `isGroup` = `chatId.endsWith('@g.us')`
     - `isDirect` = `chatId` ends with `@c.us`, `@lid` or `@s.whatsapp.net`
       (so `@g.us`, `@broadcast`/`status@broadcast`, `@newsletter` are not direct)
     - `type`: from the first key of `payload._data.message` (NOWEB):
       `conversation`/`extendedTextMessage` → `text`; `imageMessage` → `image`;
       `audioMessage` → `audio`; `videoMessage`/`ptvMessage` → `video`;
       `stickerMessage` → `sticker`; `documentMessage`/`documentWithCaptionMessage` → `document`;
       `locationMessage`/`liveLocationMessage` → `location`;
       `contactMessage`/`contactsArrayMessage` → `contact`;
       `reactionMessage` → `reaction`; keys starting with `pollCreationMessage` → `poll`;
       if `_data.message` is absent: `hasMedia ? 'unknown' : (body non-empty ? 'text' : 'unknown')`.
     - `text` = `type === 'text' ? String(payload.body ?? '').trim() : ''`; a
       `text` type with empty text becomes `unknown`.
     Before writing it, confirm the NOWEB payload keys with context7
     (`/devlikeapro/waha-docs`, "message webhook payload NOWEB _data"); if they
     differ, adapt the mapping and note it in the phase report.
  4. Edit Fields "Return normalized message" (output of 3 as is).
- Sticky notes: "1 · Filter events", "2 · Normalize", "Contract" (input/output above).
- Settings per Global constraints (error workflow = `system-error-handler`).

**Steps.**

1. `get_node` for Execute Workflow Trigger, If, Code, Set.
2. Build → validate → create → `n8n_validate_workflow`.
3. Export.

**Done when.**

- `n8n_validate_workflow` 0 errors.
- Code node pure (no `$env`, no `require`, no HTTP).
- `jq empty workflows/*.json` passes; `.settings.errorWorkflow` equals the Phase 3 id.

**Not in this phase.** Authentication (Phase 8, in the Webhook node), guards.

### Phase 5 — Guards sub-workflow

Status: DONE
Evidence: created via n8n-mcp, id **`6pSuha5uHeqK2Ll2`**, inactive, errorWorkflow set; `n8n_validate_workflow` 0 errors 0 warnings; Postgres v2.7 with `queryReplacement` as an expression array (no interpolation), `alwaysOutputData` + `?? ''` checks for empty results; SQL sanity in BEGIN…ROLLBACK (dup insert → 0 rows; second claim within 3 s → 0 rows; interval 0 → 1 row); export unwrapped, `.shared` stripped, no PII/secrets; `code-reviewer` APPROVED (note: a missing `perChatMinIntervalSeconds` fails closed as rate-limited — Phase 9 must set it).
Role: n8n-workflows · Depends on: 1, 2, 3 · Covers: AC2, AC3, AC4, AC13, AC14, AC16 · Size: M
Spec: §4 item 3, F2, F5, R1, R8

**Goal.** One sub-workflow that decides whether a normalized message may be
answered, writing state only for messages that reach the dedupe step.

**Contract (D6 = A).**

- Workflow/file: `chatbot-waha-car-rental-guards` → `workflows/chatbot-waha-car-rental-guards.json`.
- Input: `{ config, message }`. Output: `{ pass, reason }`.
- Order (no DB write before step 4, so groups/broadcasts/`fromMe`/non-allowed
  chats leave no rows — AC2):
  1. If "Skip own messages": `message.fromMe` → `{ pass: false, reason: "from-me" }`.
  2. If "Skip non-direct chats": `!message.isDirect` → `{ pass: false, reason: "not-direct" }`.
  3. If "Check allow-list": pass when `!config.restrictToAllowList` or
     `config.allowedChatIds.split(',').map(s => s.trim()).filter(Boolean).includes(message.chatId)`;
     else `{ pass: false, reason: "not-allowed" }`.
  4. Postgres "Record message id" (credential `Postgres account`, Always Output Data on):
     `INSERT INTO chatbot_processed_messages (message_id) VALUES ($1) ON CONFLICT (message_id) DO NOTHING RETURNING message_id;` with `$1 = message.messageId`.
     If "Is new message?": `message_id` present → continue; else `{ pass: false, reason: "duplicate" }`.
  5. Postgres "Claim reply slot" (Always Output Data on):

     ```sql
     INSERT INTO chatbot_chat_reply_state (chat_id, last_reply_at) VALUES ($1, now())
     ON CONFLICT (chat_id) DO UPDATE SET last_reply_at = now()
     WHERE chatbot_chat_reply_state.last_reply_at <= now() - make_interval(secs => $2::double precision)
     RETURNING chat_id;
     ```

     `$1 = message.chatId`, `$2 = config.perChatMinIntervalSeconds`.
     If "Slot claimed?": `chat_id` present → Edit Fields "Return pass" `{ pass: true, reason: "ok" }`; else `{ pass: false, reason: "rate-limited" }`.
  - Each `pass: false` exit is its own Edit Fields node named "Return ignored (<reason>)", placed under its If, no crossings.
- Sticky notes: "1 · Cheap checks (no writes)", "2 · Dedupe", "3 · Rate limit", "Contract".

**Steps.**

1. `get_node` for Postgres (executeQuery + query replacement option) and If.
2. Build → validate → create → `n8n_validate_workflow`; export.

**Done when.**

- `n8n_validate_workflow` 0 errors; all SQL uses `$n` parameters.
- No node before "Record message id" touches the DB.
- `jq empty workflows/*.json` passes; error workflow set.

**Not in this phase.** The post-send re-stamp (Phase 7).

### Phase 6 — Reply sub-workflow (AI Agent + Postgres memory)

Status: DONE
Evidence: created via n8n-mcp, id **`Rl28yJygAKG6NBRv`**, inactive, errorWorkflow set; agent v3.1 + lmChatOpenAi v1.3 (model as id-mode expression on `config.llmModel`, temperature/maxTokens from config, `maxRetries: 0`) + memoryPostgresChat v1.4 (customKey = chatId, table `chatbot_chat_histories`, window `ceil(memoryWindow/2)` — the window counts user+AI pairs); agent `continueErrorOutput` → `{ ok: false, error }`; `n8n_validate_workflow` 0 errors 0 warnings; no literal config values; export clean (no PII). Review APPROVED; hardening applied: sub-nodes read the trigger with `.first()`, error wrapped in `String()`. Not executed yet (first LLM call happens in Phase 10).
Role: n8n-workflows · Depends on: 1, 2, 3 · Covers: AC1, AC5, AC6, AC8, AC15, AC16 · Size: S
Spec: §4 item 4, F4, R3, R4, R6

**Goal.** Given a chat id and text, return the LLM reply with per-chat
persistent memory, or a clean failure object (never throws for LLM errors).

**Contract.**

- Workflow/file: `chatbot-waha-car-rental-reply` → `workflows/chatbot-waha-car-rental-reply.json`.
- Input: `{ config, chatId, text }`. Output: `{ ok: true, reply }` | `{ ok: false, error }`.
- Nodes:
  - "When called by orchestrator".
  - AI Agent "Generate reply": prompt source "define below", text
    `{{ $json.text }}`, system message `{{ $json.config.businessRules }}`,
    `onError: continueErrorOutput`.
    - Chat model sub-node "OpenAI chat model" (credential `OpenAI account`): model
      `{{ $('When called by orchestrator').item.json.config.llmModel }}`
      (expression/by-id mode), temperature `config.llmTemperature`, max tokens
      `config.llmMaxOutputTokens`, **`maxRetries: 0`**, default timeout.
    - Memory sub-node "Conversation memory" (Postgres Chat Memory, credential
      `Postgres account`): session id = custom key
      `{{ $('When called by orchestrator').item.json.chatId }}`, table
      `chatbot_chat_histories`, context window from `config.memoryWindow`.
      Check with `get_node` whether the window counts messages or exchanges;
      if exchanges, use `Math.ceil(memoryWindow / 2)` so the model gets the
      last `memoryWindow` messages (R4).
  - Success → Edit Fields "Return reply" `{ ok: true, reply: $json.output }`;
    if `output` is empty, route to failure instead (If "Has reply text?").
  - Error output → Edit Fields "Return failure" `{ ok: false, error: <error message, no user text> }`.
- No tool sub-nodes. Memory is written only on success (F3/F4: no memory write).
- Sticky notes: "1 · Generate reply", "2 · Result", "Contract".

**Steps.**

1. `search_nodes`/`get_node` for `@n8n/n8n-nodes-langchain.agent`, `lmChatOpenAi`, `memoryPostgresChat` (typeVersions, option names).
2. Build → validate → create → `n8n_validate_workflow`; export.

**Done when.**

- `n8n_validate_workflow` 0 errors.
- `jq` on the export: the only literal model name, temperature, token cap or
  window value is absent (all are expressions on `config`).
- `jq empty workflows/*.json` passes; error workflow set.

**Not in this phase.** Calling the LLM live (Phase 10).

### Phase 7 — Send sub-workflow (seen → typing → delay → send)

Status: DONE
Evidence: created via n8n-mcp, id **`yBMIvg47q3KjM4BK`**, inactive, errorWorkflow set; HTTP Request v4.5 with predefined credential `wahaApi` ("WAHA account") — accepted by validation, runtime header injection confirmed only in Phase 10 (fallback: Header Auth `WAHA API key`, owner-created); JSON bodies via `JSON.stringify` (session/chatId/text from input, D7); presence calls best-effort, send `continueErrorOutput` + no retry; delay formula checked locally (len 5/60/400 → 1–3 / 4–6 / 11–13 s); `n8n_validate_workflow` 0 errors 0 warnings; export clean. Correction rounds: (1) `alwaysOutputData` on "Stamp last reply time" (the UPDATE returns no rows, so "Return sent" would never run); (2) `.first()` for trigger reads after the Postgres node. `code-reviewer` APPROVED.
Role: n8n-workflows · Depends on: 1, 2, 3 · Covers: AC7, AC8, AC12, AC14, AC16 · Size: S
Spec: §4 item 5, F1 step 5, F6, R5, R8

**Goal.** Deliver one text to one chat with human-like presence, re-stamp the
rate-limit row, and report failure instead of retrying.

**Contract.**

- Workflow/file: `chatbot-waha-car-rental-send` → `workflows/chatbot-waha-car-rental-send.json`.
- Input: `{ config, chatId, text, meta }`. Output: `{ sent, error?, meta }`.
- Nodes, left to right (all WAHA calls: HTTP Request, POST, JSON body,
  predefined credential `WAHA account` (`wahaApi`; Header Auth `WAHA API key` fallback, see Phase 2), `retryOnFail: false`;
  URL `{{ config.wahaBaseUrl }}/api/<endpoint>`; body
  `{ session, chatId }` with `session` from the input, D7):
  1. "When called by orchestrator".
  2. Code "Compute typing delay" (pure): `base = clamp(text.length / typingCharsPerSecond, typingMinSeconds, typingMaxSeconds)`;
     `delay = max(0, base + (Math.random() * 2 - 1) * typingJitterSeconds)`, rounded to 0.1 s → `typingDelaySeconds`.
  3. "Mark chat as seen" → `/api/sendSeen` (`onError: continueRegularOutput`).
  4. Wait "Wait before typing": `config.seenDelaySeconds` seconds.
  5. "Start typing" → `/api/startTyping` (`continueRegularOutput`).
  6. Wait "Simulate typing": `typingDelaySeconds` seconds.
  7. "Stop typing" → `/api/stopTyping` (`continueRegularOutput`).
  8. "Send text message" → `/api/sendText`, body adds `text`; `onError: continueErrorOutput`.
     - Success → Postgres "Stamp last reply time" (`Postgres account`):
       `UPDATE chatbot_chat_reply_state SET last_reply_at = now() WHERE chat_id = $1;` →
       Edit Fields "Return sent" `{ sent: true, meta }`.
     - Error → Edit Fields "Return send failure" `{ sent: false, error: <message>, meta }`.
- Delays and base URL read only from the input `config` (AC8/AC9); `session`
  and `chatId` from the input fields (D7).
  Downstream nodes reference input via `$('When called by orchestrator')`.
- Sticky notes: "1 · Presence", "2 · Send", "3 · Record", "Contract".

**Steps.**

1. Confirm the four endpoints and bodies with context7 (`/devlikeapro/waha-docs`); `get_node` HTTP Request, Wait, Code, Postgres.
2. Build → validate → create → `n8n_validate_workflow`; export.

**Done when.**

- `n8n_validate_workflow` 0 errors; "Send text message" has `retryOnFail` false.
- No literal URL, session name or delay number in the export.
- `jq empty workflows/*.json` passes; error workflow set.

**Not in this phase.** Any live call to WAHA.

### Phase 8 — Authenticated inbound webhook (compose + env)

Status: DONE
Evidence: compose/`.env.example`/`setup.sh` updated; `WAHA_WEBHOOK_SECRET` appended to `.env` (was missing; value never printed); `docker compose config -q` OK; resolved value matches `^X-Waha-Webhook-Secret:[0-9a-f]{64}$`; `sh -n scripts/setup.sh` OK; `docker compose up -d waha` → running, session `Default` `WORKING` (the session is named `Default`, capital D — irrelevant here since replies use the payload's session, D7); `code-reviewer` APPROVED. **Owner prerequisite for Phase 9:** create the Header Auth credential `WAHA webhook secret` (name `X-Waha-Webhook-Secret`, value = `WAHA_WEBHOOK_SECRET` in `.env`) — not present on 2026-10-06.
Role: n8n-workflows · Depends on: none · Covers: F7 (supports AC1–AC4) · Size: S
Spec: §4 F7, R8, OD2, A5

**Goal.** WAHA sends a shared secret header on every webhook, and n8n has a
Header Auth credential to check it.

**Contract (D2 = A).**

- `docker-compose.yml`, `waha.environment`: add
  `WHATSAPP_HOOK_CUSTOM_HEADERS: X-Waha-Webhook-Secret:${WAHA_WEBHOOK_SECRET}`.
  `WHATSAPP_HOOK_URL`/`WHATSAPP_HOOK_EVENTS` unchanged (D3 = A).
- `.env.example`: add `WAHA_WEBHOOK_SECRET=` under `# WAHA` with comment `# openssl rand -hex 32 — header WAHA sends to n8n`.
- `scripts/setup.sh`: generate `WAHA_WEBHOOK_SECRET` like the other secrets
  (only when missing; follow the script's existing pattern).
- `.env`: append `WAHA_WEBHOOK_SECRET=<generated>` **only if the key is
  missing**, never printing the value (owner runs it if the executor's
  `.env` access is denied).
- Apply: `docker compose up -d waha` (recreates the container; sessions are in
  Postgres and persist). Never `down -v`.
- Owner creates credential `WAHA webhook secret` — Header Auth, name
  `X-Waha-Webhook-Secret`, value = `WAHA_WEBHOOK_SECRET`.

**Done when.**

- `docker compose config -q` passes.
- `docker compose ps waha` running; WAHA dashboard shows the `default` session still `WORKING`.
- `credentials_entity` lists `WAHA webhook secret`.
- `git diff` shows no secret value anywhere.

**Not in this phase.** The Webhook node (Phase 9).

### Phase 9 — Orchestrator workflow with config node

Status: DONE
Evidence: created via n8n-mcp, id **`3zFS5yZDOZFAAhfM`**, inactive, never executed; Webhook v2.1 POST `waha` + Header Auth `WAHA webhook secret` (Nr0CK7GM4izONDhE), respond on received; "Load workflow config" with the 16 fields (D5 `restrictToAllowList` false, D7 no `wahaSession`); helper Sets "Build ingress/guards/reply input" (Execute Workflow v1.4 can't map fields for passthrough sub-workflows); Stop and Error for F4/F6; `validate_workflow` + `n8n_validate_workflow` 0 errors 0 warnings; AC9: config literals only in "Load workflow config"; `<TEST_CHAT_ID>` placeholder; no `wahaSession`; no PII; `code-reviewer` APPROVED. Blockers on the way (owner fixed): broken `.env` line 30, then a truncated `N8N_API_KEY` (regenerated). Runtime unknowns for Phase 10: passthrough via Execute Workflow v1.4 without `workflowInputs`; sub-workflows must be published to be called in production (n8n docs).
Role: n8n-workflows · Depends on: 4, 5, 6, 7, 8 · Covers: AC1, AC2, AC8, AC9, AC10, AC11, AC12, AC15, AC16 · Size: M
Spec: §2 R2, R3, R7; §3 config table + business rules; §4 item 1, F3, F4, F6; §5

**Goal.** The `chatbot-waha-car-rental` workflow wires the four sub-workflows
behind an authenticated webhook, with the single config node.

**Contract.**

- Workflow/file: `chatbot-waha-car-rental` → `workflows/chatbot-waha-car-rental.json`.
- Nodes, left to right:
  1. Webhook "Receive WAHA event": POST, path `waha` (→ `/webhook/waha`),
     authentication Header Auth `WAHA webhook secret`, respond
     **immediately** (`onReceived`, 200).
  2. Edit Fields "Load workflow config" — only these 16 fields (spec §3
     minus `wahaSession`, D7), with the defaults (`wahaBaseUrl`
     `http://waha:3000`, `llmModel` `gpt-4o-mini`, `llmTemperature` 0.4,
     `llmMaxOutputTokens` 300, `memoryWindow` 20, `typingCharsPerSecond` 12,
     `typingMinSeconds` 2, `typingMaxSeconds` 12, `typingJitterSeconds` 1,
     `seenDelaySeconds` 1, `perChatMinIntervalSeconds` 3,
     `restrictToAllowList` **false** (D5), `allowedChatIds` `<TEST_CHAT_ID>`),
     no other input fields kept.
     - `unsupportedTypeReply`: `Por enquanto eu só consigo ler mensagens de texto. Pode me escrever o que precisa? 🙂`
     - `failureReply`: `Tive um probleminha aqui. Pode repetir sua mensagem em instantes?`
     - `businessRules` (English, multi-line): every bullet of spec §3
       "Example businessRules content" verbatim in substance — assistant
       "Duda" of fictional DriveEasy Rentals; friendly, concise, 1–3 short
       sentences, reply in the customer's language (default Brazilian
       Portuguese), max one emoji; branches + hours; fleet and daily rates
       (Economy hatch R$ 119, Compact sedan R$ 149, SUV R$ 229, Minivan 7
       seats R$ 289, Pickup R$ 259); requirements (license 2+ years, age 21 /
       25 for SUV/Minivan/Pickup, credit card in driver's name); deposits
       (R$ 800 Economy/Compact, R$ 1,500 others, released within 7 days);
       mileage 200 km/day, R$ 0.80/extra km; fuel rule + R$ 40 fee; extras
       (child seat R$ 25/day, extra driver R$ 30/day, full insurance R$ 45/day);
       cancellation (free up to 24 h, then 1 day's rate); booking: cannot book
       or take payment — collect pickup city, dates, car category and name,
       then say a human agent will confirm, never claim it is confirmed;
       claims/accidents/legal/price negotiation → human agent ("see our
       website"); never invent facts — if unsure, say a human agent will help.
  3. Execute Workflow "Run ingress" (`chatbot-waha-car-rental-ingress`, wait
     for completion) with `{ config: $('Load workflow config').item.json, body: $('Receive WAHA event').item.json.body }`.
  4. If "Is accepted message?" (`accepted`) — false: end (no node).
  5. Execute Workflow "Run guards" `{ config, message }` → If "Passed guards?" — false: end.
  6. If "Is text message?" (`message.type === 'text'`):
     - true → Execute Workflow "Run reply" `{ config, chatId, text }` → If "Reply generated?" (`ok`):
       - true → Edit Fields "Prepare LLM reply" `{ chatId, text: reply, meta: { replyKind: "llm" } }`
       - false → Edit Fields "Prepare failure reply" `{ chatId, text: config.failureReply, meta: { replyKind: "failure", llmError: error } }`
     - false → Edit Fields "Prepare unsupported reply" `{ chatId, text: config.unsupportedTypeReply, meta: { replyKind: "unsupported" } }` (no LLM, no memory — F3)
  7. Execute Workflow "Run send" `{ config, session: message.session, chatId, text, meta }` (the three prepare nodes feed it; each prepare node also carries `session`).
  8. If "Was reply sent?" (`sent`): false → Stop and Error "Fail on send error" (message: `WAHA send failed: <error>`; no chat id/text) — F6.
     true → If "Was it a failure reply?" (`meta.replyKind === 'failure'`) → true → Stop and Error "Fail on LLM error" (`LLM reply failed: <meta.llmError>`) — F4: the user already got `failureReply`, then the execution fails once so the error workflow runs once.
- Sticky notes: section headers "1 · Ingress", "2 · Guards", "3 · Reply",
  "4 · Send", "5 · Outcome", and a "Keys" note next to the config node: *only
  non-secret settings live here; WAHA API key, OpenAI key and webhook secret
  are n8n credentials (`WAHA account`, `OpenAI account`, `WAHA webhook secret`)*.
- Workflow stays **inactive**. Settings per Global constraints.
- Export as usual; no scrubbing (D5: only the `<TEST_CHAT_ID>` placeholder
  exists, live and in the repo).
- Note in the phase report: authentication is in the Webhook node (orchestrator),
  not in the Ingress sub-workflow as §4 item 2 says — rejected before any
  execution (F7). Propose a spec `Deviation:` note.

**Steps.**

1. `get_node` for Webhook (header auth, respond mode), Execute Workflow (by id, inputs), Stop and Error.
2. Build → validate → create → `n8n_validate_workflow`; export.

**Done when.**

- `n8n_validate_workflow` 0 errors; workflow inactive.
- AC9 check passes:
  `grep -rlE "gpt-4o-mini|waha:3000|DriveEasy|Por enquanto|probleminha" workflows/` lists only `workflows/chatbot-waha-car-rental.json`, and within it those strings only appear in "Load workflow config"
  (`jq '[.nodes[] | select(tostring | test("gpt-4o-mini|waha:3000|DriveEasy")) | .name]'` → `["Load workflow config"]`).
- `jq '.nodes[] | select(.name=="Load workflow config")' workflows/chatbot-waha-car-rental.json | grep -c "<TEST_CHAT_ID>"` ≥ 1, and no `wahaSession` field anywhere (`grep -rc wahaSession workflows/` all 0).
- `jq empty workflows/*.json` passes; secrets grep reviewed (expected benign hits: `maxTokens`/`llmMaxOutputTokens`, the `@s.whatsapp.net` suffix in the Ingress code).

**Not in this phase.** Publishing; live messages.

### Phase 10 — Publish, smoke tests, verification and report

Status: IN_PROGRESS
Role: n8n-workflows (+ owner on the test phone) · Depends on: 9 · Covers: AC1–AC16 · Size: M
Spec: §6 all ACs, §4 F1–F7, §5

**Goal.** The bot runs live on the test number, every AC is checked, and the
report lists results, deviations and the owner's checklist.

**Contract.**

- Owner says go before publishing. With no allow-list (D5), publishing makes
  the bot answer **every** direct chat that writes to the paired number.
- If n8n 2.41 requires sub-workflows to be published to be called (check
  context7), publish the four sub-workflows first (they have no external
  trigger). Then publish the orchestrator.
- Synthetic events: POST to `http://localhost:5678/webhook/waha` with header
  `X-Waha-Webhook-Secret` read from `.env` inside the command (never echoed);
  fixtures in the scratchpad only, with fake ids. Never a fake **direct**
  chat id while `restrictToAllowList` is `false` (it would trigger a real send
  attempt). Replays that must reach a direct chat use the owner's test chat id,
  given at run time and kept out of the repo and the report. Live sends only to
  the owner's test chat; at most a handful, spaced > `perChatMinIntervalSeconds`.
- Execution evidence via `n8n_executions` (status, last node, node start
  times) — never paste message bodies or chat ids into the report.

**Steps (smoke tests → ACs).**

1. **F7:** POST without the header → 403, no execution.
2. **AC2/AC3 (no sends):** synthetic `message.any` for a group
   (`120363000000000000@g.us`), `status@broadcast`, `@newsletter`,
   `fromMe: true`, and an `event: "session.status"` → each execution ends at
   the expected guard, no WAHA/LLM node ran; `select count(*)` on both tables
   unchanged.
2b. **AC13:** temporarily set `restrictToAllowList` to `true` in the live config
   node (with `allowedChatIds` still `<TEST_CHAT_ID>`), post a synthetic
   message from a fake direct chat (`000000000000@c.us`) → ends at
   "not-allowed", nothing sent, no row written; set it back to `false`
   **before** any other step.
3. **AC1/AC7/AC10:** owner sends "Qual o valor da diária do SUV?" from the
   test phone → one reply mentioning R$ 229; Send execution shows seen → start
   typing → stop typing → send in order, and the gap between "Start typing"
   and "Stop typing" ≈ clamp(len/12, 2, 12) ± 1 s.
4. **AC10 (uncovered):** ask something not in the rules → reply says a human
   agent will help.
5. **AC11:** ask to book → bot asks for city, dates, category, name; never says confirmed; says a human agent will confirm.
6. **AC5:** mention a category, later ask "qual categoria eu escolhi?" → correct;
   `docker compose restart n8n n8n-worker`, ask again → still correct.
7. **AC6:** a second synthetic chat id can't be live-tested without a second
   number; verify instead that `chatbot_chat_histories.session_id` holds one
   row-set per chat id and the memory node keys by `chatId` (the owner may
   test from a second phone of their own).
8. **AC4:** replay the same synthetic text payload (owner's test chat id,
   payload's `session`, a new fake `messageId`) twice → one reply; second
   execution ends at "duplicate".
9. **AC14:** two messages within 3 s → one reply; second ends at "rate-limited".
10. **AC12:** owner sends an image → `unsupportedTypeReply` once, with typing; no Reply sub-workflow execution.
11. **AC15:** temporarily set `llmModel` to an invalid name in the live config
    node, send one message → `failureReply` once, exactly one
    `system-error-handler` execution, OpenAI call not retried; restore
    `gpt-4o-mini`, re-validate.
12. **AC8:** change `typingMinSeconds` (e.g. 4) in the live config only →
    next reply's typing gap ≥ 4 s; restore.
13. Confirm every live config value is back to its default
    (`restrictToAllowList` false, `llmModel` `gpt-4o-mini`, `typingMinSeconds`
    2), then re-export all six workflows and confirm no diff other than
    `versionId`/`active`/timestamps from the publish.

**Done when.**

- Full gate: `jq empty workflows/*.json`; `n8n_validate_workflow` 0 errors on all six workflows; `docker compose config -q`.
- **AC16:** `ls workflows/` shows `chatbot-waha-car-rental.json`, `-ingress`, `-guards`, `-reply`, `-send`, `system-error-handler.json`; for the five chatbot files `jq -r .settings.errorWorkflow` equals the error-handler id; each has ≥ 2 `n8n-nodes-base.stickyNote` nodes.
- **AC9:** the Phase 9 grep/jq checks pass for all files; secrets grep reviewed;
  `git diff` and `git status` show no `.env`, keys, real chat ids or phone numbers.
- Every AC marked pass/fail with evidence (execution ids, not contents).
- Report includes the deviations, each with a proposed spec `Deviation:` note:
  auth in the Webhook node; guard order (allow-list before dedupe); D5
  (`restrictToAllowList` defaults to `false`, against §3 and R8); D6 (claim on
  accept); D7 (session from the payload, `wahaSession` removed, `session`
  added to the normalized shape, AC9 wording). Also the ideas not built
  (dedupe table retention, per-chat lock, plus the spec's list).
- Owner manual checklist delivered: credentials present; the paired number is
  the test number; with no allow-list, every direct chat to it gets answered;
  set `restrictToAllowList` to `true` and fill `allowedChatIds` live before any
  other contacts could write; never point the bot at a customer number.

**Not in this phase.** Any new behaviour; fixing failures beyond small
corrections inside the phase's own workflows (report bigger ones).
