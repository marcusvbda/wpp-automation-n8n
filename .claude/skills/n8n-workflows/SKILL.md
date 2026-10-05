---
name: n8n-workflows
description: Invariants and conventions for building n8n workflows in this repo — JSON hygiene, webhooks, credentials, idempotency, error handling, sub-workflows, Code nodes, export/import. Load before creating or editing any workflow or the n8n compose setup.
---

# n8n workflows — invariants

Verify node parameters and versions with context7 before relying on them;
node `typeVersion`s change.

## Files and JSON hygiene

- One workflow per file in `workflows/`, named `<area>-<purpose>.json`
  (kebab-case, English). The workflow `name` matches.
- Exports are committed **without** `pinData`, execution data, or credential
  secrets. Credentials appear only as `{ id, name }` references.
- Keep workflow `id`, node `id`s and `position`s stable across edits so diffs
  stay small. Node names are English, verb-first ("Parse incoming message",
  "Send reply").
- Export/import use the n8n CLI inside the container (`n8n export:workflow
  --separate`, `n8n import:workflow --separate`). **Never** run
  `export:credentials`. Import overwrites by id: only when the task asks.
- Editing in the n8n UI is the owner's prerogative; manual UI changes win over
  the spec (see `CLAUDE.md`). Re-export, don't re-create.

## Triggers and webhooks

- Distinguish the test URL (`/webhook-test/…`, editor only) from the production
  URL (`/webhook/…`, active workflow). Gateways must be configured with the
  production URL.
- Every webhook that comes from the gateway validates a shared secret/header
  (or a gateway-signed token) in the first nodes and returns early on mismatch.
  Respond quickly (Respond to Webhook / "respond immediately") and do the slow
  work after — gateways retry on timeout.
- Webhook paths are explicit and stable (`whatsapp/<gateway>/incoming`), never
  the random default.

## Reliability

- **Idempotency:** gateways can deliver the same event twice. Dedupe on the
  gateway's message id before any side effect (static data or a datastore
  node/DB); a duplicate exits silently.
- Ignore the bot's own outbound messages (`fromMe`) and non-user events early.
- Branch explicitly on message type (text, media, reaction, status…); unknown
  types go to a defined fallback, not a crash.
- Retries (`retryOnFail`) only on idempotent steps; send-message nodes are not
  retried blindly.
- Every workflow sets the shared error workflow (Error Trigger) in its
  settings. The error workflow notifies the owner's channel and never sends to
  end users.
- Use `Continue (using error output)` where a failure has a meaningful
  alternate path instead of letting the execution die.

## Structure

- Extract repeated logic into sub-workflows (Execute Workflow) with a typed
  input contract documented in the sub-workflow's sticky note.
- Code nodes: small, pure, no network calls, no secrets, no `$env` reads for
  secrets (use credentials). Anything > ~30 lines or needing libraries goes to
  the TypeScript service and is called over HTTP.
- Use the Set/Edit Fields node to normalize the gateway payload once, right
  after the trigger; downstream nodes read only the normalized shape.
- Expressions guard against missing fields (`?.`, defaults).
- No hardcoded phone numbers, URLs or tokens: use credentials, environment
  variables exposed to n8n, or workflow inputs.

## Compose / runtime

- Pin image tags (the owner decides versions). Persist n8n data in a named
  volume; never delete it (see `CLAUDE.md`).
- `N8N_ENCRYPTION_KEY`, `WEBHOOK_URL`, timezone and DB settings come from
  `.env`; only names go in `.env.example`.
- Set `GENERIC_TIMEZONE`/`TZ` explicitly; schedules depend on it.
