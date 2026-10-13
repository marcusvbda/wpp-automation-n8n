# Plan — Divercity Park WhatsApp service bot ("Dry")

Source spec: `docs/features/chat-bot-divercity/spec.md` · SHA-256 `46b9827c2b7692cc9f9a527763108c2bd0504b14c5f629a26e9ec2c67f0ce756`
Product truth: the spec itself (no separate product doc).
Run phases with `/execute-phases docs/features/chat-bot-divercity/plan.md <phases>` — one or a few per
session. Phase status is updated in place in this file.

## Status board

| Phase | Title                                                  | Role          | Depends on | Size | Status  |
| ----- | ------------------------------------------------------ | ------------- | ---------- | ---- | ------- |
| 1     | Live probe: payload fields, contact signal, node types | n8n-workflows | none       | S    | DONE |
| 2     | Redis credential for the bot                           | node-service  | none       | S    | DONE    |
| 3     | Workflow skeleton: config, intake, filters 1–4, types  | n8n-workflows | 1, 2       | M    | DONE    |
| 4     | Filter 5: only numbers not in the phone's agenda       | n8n-workflows | 1, 3       | S    | DONE    |
| 5     | Pause and attendant detection                          | n8n-workflows | 3          | S    | DONE     |
| 6     | Handoff block and media path                           | n8n-workflows | 5          | M    | DONE     |
| 7     | Debounce (group messages)                              | n8n-workflows | 5          | M    | DONE     |
| 8     | Conversation session and context                       | n8n-workflows | 7          | M    | DONE     |
| 9     | Agent, tools, status routing to handoff                | n8n-workflows | 6, 8       | M    | DONE    |
| 10    | Reply and close paths (`continua`, `resolvido`)        | n8n-workflows | 9          | S    | DONE    |
| 11    | Hook routing, import and publish in test mode          | n8n-workflows | 2–10       | S    | DONE    |
| 12    | Verification and report                                | n8n-workflows | 1–11       | M    | DONE    |

## Audit — 2026-10-12

| Check | Result |
| ----- | ------ |
| Stack | Up (owner ran `docker compose up -d`): n8n, n8n-worker, postgres, redis, waha. `docker compose config -q` OK, `jq empty workflows/*.json` OK. |
| Images | `n8nio/n8n:2.41.7` (main + worker), `devlikeapro/waha:noweb-arm-2026.9.2`, `postgres:17.11-alpine`, `redis:8.10.2-alpine`. |
| n8n | 2.41.7, `EXECUTIONS_MODE=queue`, `GENERIC_TIMEZONE=America/Sao_Paulo` (spec 0.6 / 10 OK). |
| WAHA server | 2026.9.2, CORE tier, engine NOWEB. One session, name **`Default`** (capital D), status WORKING, `config.noweb.store = {enabled: true, fullSync: true}`, no session-level webhooks. |
| WAHA hook | Global `WHATSAPP_HOOK_URL` in `docker-compose.yml` → `/webhook/d8dddf0c-…/waha` (car-rental trigger), `WHATSAPP_HOOK_EVENTS=message.any`. Only one global URL (D2). |
| WAHA n8n nodes | `@devlikeapro/n8n-nodes-waha` **2025.2.9** (bundled OpenAPI 2025.2.5), nodes `wahaTrigger` / `WAHA` typeVersion 202502. Present: Chatting → Send Seen, Start Typing, Stop Typing, Send Text; Contacts → Get, Get All, Check Exists. **No LID endpoints** in this node version (the server has `/api/{session}/lids/...`). |
| `isMyContact` | **Not returned on NOWEB.** Contacts → Get returns only `id, lid, name, phoneNumber`; Get All adds `pushname, verifiedName`. Sample of 1000: `name` set on 215 (likely address-book name), `pushname` on 829, `phoneNumber` on 200, `@lid` contacts with `phoneNumber`: 0. The WAHA docs (`/docs/how-to/contacts/`) show `isMyContact` in the example response and mark `GET /api/contacts` as supported on all engines (NOWEB: store required, which is on), but they don't say which fields each engine fills. The live server's OpenAPI has no typed contact schema with `isMyContact`. So the field exists in the API's shape (WEBJS-style example), and NOWEB doesn't fill it (D3). |
| n8n credentials | `OpenAI account`, `Postgres account`, `WAHA account`, `WAHA webhook secret` (httpHeaderAuth, not in repo), `n8n Assistant model`. **No Redis credential** (Phase 2). |
| Workflows in n8n | `chatbot-waha-car-rental` (unpublished), `chatbot-waha-car-rental-guards` (unpublished, not in repo), `system-error-handler` (`FF0x666oa1bfHLDI`, error workflow), 3 study workflows. None with the new bot's id. |
| Repo convention | `workflows/chatbot-waha-car-rental.json`: Set nodes normalize the WAHA payload right after the trigger, `settings.errorWorkflow = FF0x666oa1bfHLDI`, credentials by `{id, name}`. Its trigger uses output index 3 for its event. (It uses English names, but this workflow is all-Portuguese by D1.) |
| Scripts / checks | No `package.json`, so no npm scripts. Checks that exist: `jq empty workflows/*.json`, the secrets grep from `project-core`, `docker compose config -q`. `scripts/setup.sh` creates credentials when missing (pattern for Phase 2) and imports workflows by id when missing. |
| `.env` | Not readable in this session (permission). Key names from `.env.example` only. No new `.env` key needed (`REDIS_PASSWORD` already exists). |
| Gaps vs spec | `isMyContact` missing (D3). Session name is `Default`, not `default`. No LID → phone operation in the native node (spec 2 worst case: name only, no link). No webhook HMAC configured (D5). |

### Audit — Phase 1 findings (partial, 2026-10-12; sanitized, no values)

Collected read-only from the stored history (249 messages, 15 chats) and the node packages. Facts 1, 3 and 4 are complete. Fact 2 (D3 condition) needs the owner's phone actions and is **open**.

**Fact 1 — message payload (WAHA NOWEB 2026.9.2).**

- Top-level keys: `id, timestamp, from, fromMe, source, body, hasMedia, media, ack, ackName, location, vCards, replyTo, _data`. `to` and `participant` exist on group messages only.
- `id` = `fromMe_chatId_msgId[_participant]`. `timestamp` is **seconds** (10 digits). `fromMe` is boolean.
- **1:1 chats arrive as `@lid`**: every private message in the sample has `from = <lid>@lid`, and for `fromMe = true` `from` is still the other party's id and `to` is null. So `chatId = from` (not `fromMe ? to : from`) for private chats. Groups: `from` = group id, `to` = group id, `participant` = sender `@lid`. Phase 3 must handle both shapes.
- `source`: exists, only `app` observed in history (no API sends in the sample; `api` is the expected value for API sends, to be confirmed in Phase 1 step 3 with the single test send).
- `body`: text for text messages, the caption for image/video (null when no caption), null for audio/sticker/album.
- `_data.message` keys by type: text → `conversation` or `extendedTextMessage.text`; audio → `audioMessage` (`ptt`); image → `imageMessage` (`caption`); video → `videoMessage`; sticker → `stickerMessage`; album → `albumMessage`. No `reactionMessage`, poll or `protocolMessage` seen in history (reactions live in `_data.reactions[]`; not verified on live `message.any` events).
- Display name: `_data.pushName` (present on about 65% of messages, so it needs a fallback). No `notifyName`.
- Real phone for `@lid`: `_data.key.remoteJidAlt` (1:1) and `_data.key.participantAlt` (groups), populated only when `_data.key.addressingMode = "lid"` (80 messages in the sample, absent on older ones). No `senderPn`. The server also has `GET /api/{session}/lids` → `[{lid, pn}]`, but the native node has no LID operation.

**Fact 2 — D3 signal (aggregate, first 2000 contacts of about 2200).**

- Contact keys: `id, lid, name, phoneNumber, pushname, verifiedName` (no `isMyContact`).
- `@c.us` (991): `name` set on 205 (22 differ from `pushname`, so it is the address-book name). `@lid` (1002): `name` set on only 10 (1%), `pushname` on 997.
- Reading: `name` looks like the address-book name, **but the `@lid` form of a saved contact is rarely populated**. Since private chats arrive as `@lid`, a lookup by the `@lid` id will probably report "unsaved" for saved numbers (fail-open for saved contacts, which is the wrong direction). A lookup by `<remoteJidAlt phone>@c.us` may work. **Not decidable without the test numbers.**
- Live check with the owner's saved test number (second probe, after the owner re-sent a text, audio, image and sticker):
  - The chat shows as `@c.us` in `chats/overview` (digits = the phone), `@s.whatsapp.net` in the raw `/chats`, and every incoming message has `from = <lid>@lid`, `to = null`, `_data.key.remoteJidAlt = <phone>@s.whatsapp.net`, `source = app`, `pushName` present.
  - Contacts → Get by `<phone>@c.us`: HTTP 200, keys `id, lid, name, phoneNumber, pushname`, `name` **non-empty**.
  - Contacts → Get by the bare `<lid>@lid`: HTTP 200, keys `id, pushname` only, `name` **empty**. So a lookup by the `@lid` id would wrongly report a saved contact as unsaved.
  - `GET /api/Default/lids/<lid>` resolves to a phone (`lid`, `pn`), but the native node has no LID operation, so the phone has to come from `remoteJidAlt`.
  - Unsaved side (proxy, no real unsaved test number was used): of 991 `@c.us` contacts in the first 2000, 786 have `pushname` and empty `name`. Contacts → Get on 3 of them returned only `id` and `pushname` (no `name`, `lid` or `phoneNumber`).
- Result: **PASS, conditional.** `name` separates saved from unsaved when the lookup uses `<phone>@c.us` (phone taken from `remoteJidAlt`). Caveats the executor must respect: (1) the unsaved side is inferred from aggregate data, not from a real unsaved test number; (2) when `remoteJidAlt` is absent, `telefone` is empty and the lookup must fail closed (ignored and logged); (3) the lookup must never use the `@lid` id.
- Not confirmed: `source` for a message sent through the API (`api` expected). The single test send was denied by the permission layer and not retried. Phase 5's rule (`source !== 'api'` **and** no `bot-msg:` mark) already works without it, but it should be seen in the first live run. A phone-typed reply (`fromMe = true`) older than the sample has `source = app`, `from` = `@lid`, `to = null`, no `remoteJidAlt`.
- **Consequence for the plan (chat id).** `chatId = fromMe ? to : from` does not hold for private chats, because `to` is null. Use `from` (`<lid>@lid`) as the chat key for private chats, for incoming and `fromMe` alike, so `pausa:`, `buf:` and `conv:` stay consistent. Sends can go to the same `<lid>@lid` chat id (message fetch by that id returns 200). Groups still end at `@g.us`.

**Fact 3 — WAHA Trigger 2025.2.9.** Type `@devlikeapro/n8n-nodes-waha.wahaTrigger`, typeVersion `202502`. There is **no parameter to select events**; the node has one output per event and routes by `body.event`. `message.any` = output index **3** (`message` = 1, `message.reaction` = 2). Connection goes under `main[3]`. Path suffix `waha`, immediate 200.

**Fact 4 — node types (n8n 2.41.7).**

| Node | Type | typeVersion |
| ---- | ---- | ----------- |
| Redis | `n8n-nodes-base.redis` | 1 (ops: `delete, get, incr, info, keys, llen, pop, publish, push, set`; `incr`/`set` take `expire` + `ttl`, `get` takes `keyType`, `push` takes `list` + `tail`; no standalone expire) |
| Redis Chat Memory | `@n8n/n8n-nodes-langchain.memoryRedisChat` | 1.6 |
| AI Agent | `@n8n/n8n-nodes-langchain.agent` | 3.1 |
| OpenAI Chat Model | `@n8n/n8n-nodes-langchain.lmChatOpenAi` | 1.3 (`model` is a resourceLocator; mode `id` takes an expression) |
| Structured Output Parser | `@n8n/n8n-nodes-langchain.outputParserStructured` | 1.3 |
| HTTP Request Tool | `@n8n/n8n-nodes-langchain.toolHttpRequest` | 1.1 |
| Wait | `n8n-nodes-base.wait` | 1.1 |
| Switch | `n8n-nodes-base.switch` | 3.4 |
| If | `n8n-nodes-base.if` | 2.3 |
| Filter | `n8n-nodes-base.filter` | 2.3 |
| Set | `n8n-nodes-base.set` | 3.5 |
| Code | `n8n-nodes-base.code` | 2 |
| NoOp | `n8n-nodes-base.noOp` | 1 |

## Owner decisions

### D1 — Language of the workflow's identifiers — RESOLVED 2026-10-12: all Portuguese

Owner: "tudo em português, porque vai ser usado por um brasileiro e precisa ser de fácil manuseio".
Everything inside the workflow is pt-BR: node names, sticky notes, CONFIG/INSTRUCOES keys (spec names verbatim), normalized field names, Redis keys (spec names), log events and Code node comments. WAHA/n8n terms the spec itself uses stay as they are (`chatId`, `fromMe`, `source`, `hasMedia`, `sessionKey`). This is an explicit owner exception to the `CLAUDE.md` language rule, **for this workflow only**. This plan's prose and commit messages stay English. The exact names are in "Global constraints → Names".

### D2 — How WAHA events reach the new workflow — RESOLVED 2026-10-12: option A

Repoint the global `WHATSAPP_HOOK_URL` in `docker-compose.yml` to the new trigger and recreate only the `waha` container. Car-rental stays in n8n, unpublished and untouched. (Phase 11.)

### D3 — Signal for "number saved in the phone's agenda" — RESOLVED 2026-10-12: option A, conditional

Use the native Contacts → Get and treat a non-empty `name` as "saved", failing closed, with `CONTATOS_IGNORADOS` as an extra manual list. **Condition:** Phase 1 must show `name` non-empty for the saved test number and empty for the unsaved one, including the `@lid` form if the test chat is `@lid`. If it doesn't, Phase 4 becomes `BLOCKED (D3)` and the executor stops and asks the owner again. Remaining options then: switch the engine to WEBJS, tested first on a second test session (image tag change); `CONTATOS_IGNORADOS` only; or upgrade the WAHA node package. This is a spec deviation (`isMyContact` → `name`), so a `Deviation:` note goes in the Phase 12 report.

### D4 — Message types the spec does not list — RESOLVED 2026-10-12: option A

Reactions, polls, protocol messages (edit/delete/revoke), empty texts and unknown types → ignore silently, with no reply, no handoff and no pause.

### D5 — Inbound webhook authentication — not asked; default A (defer)

Keep parity with car-rental: native WAHA Trigger, n8n bound to `127.0.0.1`, internal Docker network. Revisit at production deploy (WAHA webhook HMAC). Blocks nothing. The owner can override.

## Global constraints (every phase)

- **One workflow** `workflows/chatbot-waha-divercity.json`, `name` `chatbot-waha-divercity`, stable workflow `id` and node `id`s/positions (generated once in Phase 3). `settings`: `{"executionOrder":"v1","errorWorkflow":"FF0x666oa1bfHLDI"}`. The workflow stays **unpublished** until Phase 11.
- **Blocks with sticky notes** (spec 0.1): every block has a Sticky Note (pt-BR) with a title and a one-line purpose that encloses its nodes. Every node name starts with its block number, except `CONFIG` and `INSTRUCOES`. These two run right after the trigger, so `$('CONFIG').first().json` / `$('INSTRUCOES').first().json` are always available. Inside AI sub-nodes and tools, use `.first()`, never `.item`.
- **Native WAHA nodes only** (spec 0.2): `@devlikeapro/n8n-nodes-waha.wahaTrigger` / `.WAHA` v202502, credential `{"wahaApi":{"id":"fLb4y6X1sdRn0lC8","name":"WAHA account"}}`. No HTTP Request or generic Webhook toward WAHA. If an operation is missing, stop and report it.
- **Nothing hardcoded** (spec 0.3): every value that differs between test and production lives in `CONFIG`/`INSTRUCOES`. Derived TTLs (`× 3600`) are computed in expressions. No phone numbers, group ids or tokens in JSON. The repo copy always has `SITE_API_TOKEN = "COLE_O_TOKEN_AQUI"` and empty `ALLOWLIST`, `CONTATOS_IGNORADOS`, `GRUPO_ATENDIMENTO_ID`.
- **Token safety**: the real site token is pasted only in the n8n editor. Before any re-export from n8n into the repo, reset `SITE_API_TOKEN`, `ALLOWLIST`, `CONTATOS_IGNORADOS` and `GRUPO_ATENDIMENTO_ID` to the repo values. Never re-import over an n8n copy without first diffing it against the repo, because the owner's UI edits win (`CLAUDE.md`).
- **Never invent** (spec 0.5): any failure, empty response or doubt goes to the handoff.
- **Timezone** (spec 0.6): date logic uses `CONFIG.TIMEZONE` explicitly (`America/Sao_Paulo`). `GENERIC_TIMEZONE` is already set.
- **Redis**: core `n8n-nodes-base.redis` and `memoryRedisChat`, credential `Redis account` (Phase 2, DB index 1, isolated from the Bull queue on DB 0).
- **Names (D1, Portuguese)**:
  - `CONFIG` keys = spec 1.1 verbatim, with the spec's initial values, except `WAHA_SESSION = "Default"` (from the audit). Types: booleans for `INCLUIR_LINK_WA` and `MODO_TESTE`, numbers for numeric fields, strings otherwise.
  - `INSTRUCOES` keys = spec 1.2 verbatim: `PERSONA_E_REGRAS`, `FATOS_DO_PARQUE`, `AVISOS_DE_HOJE`, `FERIADOS`, `MSG_HANDOFF_CLIENTE`, `MSG_MIDIA`.
  - Normalized message fields: `idMensagem`, `sessao`, `fromMe`, `source`, `chatId`, `timestamp`, `tipo`, `tipoLabel`, `texto`, `legenda`, `nomeContato`, `telefone`, `ehLid`.
  - `tipo` values: `texto`, `audio`, `imagem`, `video`, `documento`, `localizacao`, `contato`, `figurinha`, `ignorar`.
  - Redis keys (spec): `pausa:{chatId}`, `buf:{chatId}`, `ultima:{chatId}`, `conv:{chatId}`, `bot-msg:{id}`, plus `entrega:{idMensagem}` (dedupe, repo idempotency invariant).
  - Handoff contract fields: `resposta`, `motivo`, `resumo`, `ultimoTexto`. Context fields: `conversaId`, `sessionKey`, `textoCliente`, `mensagemSistema`.
  - Agent output contract and tool names: spec verbatim (`resposta/status/motivo/resumo`, `continua/resolvido/humano`, `consultar_passaportes`, `consultar_horarios`).
- **Logging** ("registrar no log", spec 2/7): a Set node named `<block> Log <motivo>` with `{ evento, detalhe }` ends the branch, so the n8n execution record shows it. No extra store.
- **Test safety**: live sends only to the owner's allow-listed test chats. While developing, `GRUPO_ATENDIMENTO_ID` is empty or a test-only group of the owner. No loops or bulk sends. Manual runs use pinned sample payloads that are never committed (`pinData` stripped).
- **Scope**: no party-price tool (spec 8), no audio transcription, no reactivation command, no Google Calendar.
- Git read-only, no dependency/image/version changes, no tests written (`CLAUDE.md`).

## Acceptance-criteria coverage

| AC (spec 9) | Phases |
| ----------- | ------ |
| 1 Price without a date asks for the day / correct tier | 8, 9, 12 |
| 2 Today 12/10 holiday → `weekendPrice`, 12h–20h | 8, 9, 12 |
| 3 Tuesday `weekdayPrice`, Saturday `weekendPrice` | 8, 9, 12 |
| 4 "Open now?" uses Brasília time | 8, 9, 12 |
| 5 Party → `humano`, no party price | 9, 12 |
| 6 Media → `MSG_MIDIA` + one handoff; silence while paused; sticker ignored; text+audio < 5 s → handoff only | 3, 5, 6, 7, 12 |
| 7 Unknown number answered; saved number ignored | 4, 12 |
| 8 Allowlist number in test mode skips the contact filter | 4, 12 |
| 9 Contact lookup failure → ignored and logged | 4, 12 |
| 10 `resolvido` → farewell, `conv` deleted, no pause; later the bot introduces itself again | 8, 10, 12 |
| 11 Silence for `MEMORIA_TTL_HORAS` → new conversation | 8, 12 |
| 12 Handoff → group notice with name, link and summary; pause; back in a new conversation after expiry | 5, 6, 12 |
| 13 Attendant typing pauses; bot API message does not | 5, 6, 10, 12 |
| 14 Three messages within 5 s → one reply | 7, 12 |
| 15 Wrong token (401) / API down → `humano`, no invented price | 9, 12 |
| 16 Team-group message ignored; non-allowlisted number in test mode ignored | 3, 12 |
| 17 Old (replayed) message ignored | 3, 12 |

## Phases

### Phase 1 — Live probe: payload fields, contact signal, node types

Status: DONE
Evidence: facts 1–4 recorded in "Audit — Phase 1 findings", sanitized (keys, types, counts, booleans; no values). D3 condition: **PASS, conditional** (`name` non-empty for the saved test number when looked up by `<phone>@c.us`; empty by `@lid`; unsaved side inferred from aggregate data). Gaps: no real unsaved test number, and the API-send `source` value is unconfirmed (the test send was denied). `jq empty workflows/*.json` passes; no workflow, compose or credential touched.
Role: n8n-workflows · Depends on: none · Covers: prerequisite for AC 6, 7, 8, 9, 13 · Size: S
Spec: 2, 2.3, 3.1, 6, 10

**Goal.** Record the facts later phases depend on: real field paths in the WAHA message payload, whether `name` from Contacts → Get separates saved from unsaved numbers (the D3 condition), and the exact n8n node types/versions to use. Read-only. The only file written is this plan.

**Contract.**

- All output is sanitized: print **keys, types and counts, never values** (no numbers, names or texts). Run WAHA API calls inside the `waha` container using its own `$WAHA_API_KEY`, never printed. For example: `docker compose exec -T waha sh -c 'curl -s -H "X-Api-Key: $WAHA_API_KEY" "http://localhost:3000/api/..."' | jq '<keys only>'`. The live OpenAPI is at `/-json` with dashboard basic auth (`$WAHA_DASHBOARD_USERNAME:$WAHA_DASHBOARD_PASSWORD`).
- The owner helps from the test phones: they (a) send a text, an audio, an image and a sticker to the session number from a test number that **is saved** in the park phone's agenda, (b) send a text from a test number that **is not saved**, (c) type a reply on the park phone in chat (a). The executor sends **one** text through the WAHA API to test chat (a) only.
- Facts to record (in "Audit — Phase 1 findings", appended below the audit table):
  1. Message fields (via `GET /api/{session}/chats/{chatId}/messages` or `GET /api/messages`): paths for id, `fromMe`, `from`/`to`, `timestamp` unit, `hasMedia`, `_data.message` key per type (text, audio/ptt, image, sticker), caption path, contact display name (`_data.pushName`/`notifyName`), whether `source` exists and what it is for the API send vs. the phone-typed reply, and for `@lid` chats, any field carrying the real phone (`_data.key.remoteJidAlt`, `senderPn`, …).
  2. **D3 condition**: Contacts → Get for (a) and (b), plus the `@lid` form if the chat is `@lid`. Is `name` non-empty for the saved number and empty for the unsaved one? Record PASS/FAIL. On FAIL, set Phase 4 to `BLOCKED (D3)` and ask the owner.
  3. WAHA Trigger 2025.2.9: the parameter that selects events, and the output index that carries `message.any` (read `dist/nodes/WAHA/v202502/WAHATriggerV202502.js` under `n8n-data/nodes/node_modules/@devlikeapro/n8n-nodes-waha`).
  4. n8n 2.41.7 node types and latest typeVersions for: Redis, Redis Chat Memory, AI Agent, OpenAI Chat Model, Structured Output Parser, HTTP Request Tool (`toolHttpRequest` vs `httpRequestTool`), Wait, Switch, If, Filter, Set, Code (context7 + the n8n container's `node_modules`). Also: can the OpenAI model name be an expression?

**Steps.**

1. Confirm the stack is up (`docker compose ps`). Do not restart anything.
2. Ask the owner to do the phone actions, and wait for confirmation.
3. Collect facts 1–4 with sanitized queries.
4. Append the findings to this plan and report the D3 result to the owner.

**Done when.**

- The findings section exists with facts 1–4, and contains no PII or secret values.
- The D3 condition is recorded PASS/FAIL, and Phase 4's status is updated to match.
- `jq empty workflows/*.json` passes (unchanged).

**Not in this phase.** Any workflow file, compose change or credential.

### Phase 2 — Redis credential for the bot

Status: DONE
Evidence: `scripts/setup.sh` got `CRED_REDIS_ID=rD7k2Mx9QpL4vWn3` and a create-if-missing `add_cred` (host `redis`, port 6379, password from `REDIS_PASSWORD`, database 1). `bash -n scripts/setup.sh` and `docker compose config -q` pass. After running the script twice, `credentials_entity` has exactly one row `Redis account|redis` with the same id. `code-reviewer`: APPROVED (non-blocking: the password is interpolated into the JSON unescaped, same as the Postgres and WAHA lines).
Role: node-service · Depends on: none · Covers: infra for AC 6, 10–14 · Size: S
Spec: 3, 4, 5.1, 6

**Goal.** An n8n credential `Redis account` exists in fresh and current installs, created from `.env` and never overwritten.

**Contract.**

- `scripts/setup.sh`: add a constant `CRED_REDIS_ID` (16-char id, same style as the other `CRED_*_ID`), and an `exists credentials_entity "$CRED_REDIS_ID" || add_cred '{"id":…,"name":"Redis account","type":"redis","data":{"host":"redis","port":6379,"password":"<REDIS_PASSWORD from env_get>","database":1}}'` line next to the others. Verify the `redis` credential's field names for n8n 2.41.7 with context7 first.
- No new `.env` key, and existing `.env` values untouched.
- Create it in the running n8n by rerunning `scripts/setup.sh`. It only creates missing credentials, imports only missing workflows and runs `docker compose up -d` (nothing destructive).

**Steps.**

1. Read `scripts/setup.sh` (credential section).
2. Add the constant and the `add_cred` line.
3. Run `scripts/setup.sh`, then confirm with `docker compose exec -T postgres psql -U n8n -d n8n -tAc "select name,type from credentials_entity where name='Redis account'"`.

**Done when.**

- The `Redis account` credential exists with type `redis`.
- Rerunning the script doesn't duplicate or overwrite it.
- `bash -n scripts/setup.sh` and `docker compose config -q` pass.

**Not in this phase.** Any workflow.

### Phase 3 — Workflow skeleton: config, intake, filters 1–4, message types

Status: DONE
Evidence: `workflows/chatbot-waha-divercity.json` created: workflow id `B1fRwNFx0bFdHYGI`, trigger `webhookId` `33e5dd5f-b628-4552-ba1c-d5cf09b54deb`, `active: false`, no `pinData`. `jq empty workflows/*.json` passes, all connection targets exist, all 16 non-sticky nodes sit inside a sticky note, names are prefixed except `CONFIG`/`INSTRUCOES`, `PERSONA_E_REGRAS` is byte-identical to Annex A, the secrets grep shows only the `COLE_O_TOKEN_AQUI` placeholder. The normalizer's Code node was exercised in node with synthetic payloads (text, image with caption, reaction, sticker, no-`_data` audio, `@lid` with `remoteJidAlt`). The workflow was imported into n8n unpublished (not run, n8n not restarted) and lists as inactive. `code-reviewer`: APPROVED.
Deviations and additions (report in Phase 12): (1) `chatId = (fromMe && to) ? to : from` instead of `fromMe ? to : from`, because private chats arrive as `@lid` with `to = null` (Phase 1); (2) `2.2.0` dedupe added, with a third node `2.2.0 Restaurar mensagem` because Redis `incr` replaces the item; (3) `2.1 Extrair mensagem` (Set) + `2.1 Normalizar mensagem` (Code, 39 lines) instead of a single Set; (4) `2.2.1` also drops an empty `chatId`; (5) `3 Nota Atendente` sticky title is a guess, to confirm in Phase 5. Non-blocking: `telefone` can be `''` for an `@lid` without `remoteJidAlt`, so later phases must not assume it is set; an empty `idMensagem` would share one dedupe key (theoretical); a sticker without `_data` and with `hasMedia` is classified `documento` (edge case). Leftover: `/tmp/divercity-import.json` in the n8n container (harmless; `rm` was denied).
Role: n8n-workflows · Depends on: 1, 2 · Covers: AC 16, 17, 6 (type routing) · Size: M
Spec: 0, 1, 2 (2.1, 2.2 items 1–4, 2.3 routing)

**Goal.** A new, valid, unpublished workflow that receives `message.any`, loads the config, normalizes the payload, dedupes it, applies filters 1–4 and routes by type. Every branch ends explicitly.

**Contract.**

- File `workflows/chatbot-waha-divercity.json`, new workflow `id`, new trigger `webhookId` (UUID). Record both in this plan.
- Block 1 (sticky "1 CONFIG e INSTRUÇÕES — valores que o dono edita"):
  - `CONFIG` (Set, `includeOtherFields: false`): the spec 1.1 keys (see Names).
  - `INSTRUCOES` (Set):
    - `PERSONA_E_REGRAS` = the Annex A text verbatim.
    - `FATOS_DO_PARQUE` = `"Endereço: [PREENCHER]\nRegras de entrada: [PREENCHER]\nPolítica de acompanhante: [PREENCHER]\nDescontos: [PREENCHER]\nEstacionamento: [PREENCHER]"`.
    - `AVISOS_DE_HOJE` = `""`.
    - `FERIADOS` = `"2026-10-12,2026-11-02,2026-11-15,2026-11-20,2026-12-25,2027-01-01"`.
    - `MSG_HANDOFF_CLIENTE` = `"Vou chamar uma das nossas atendentes pra te ajudar com isso. Ela te responde por aqui em breve."`
    - `MSG_MIDIA` = `"Por enquanto eu só consigo ler mensagens de texto. Vou chamar uma atendente pra te ajudar."`
- Block 2 (sticky "2 Entrada e filtros — normaliza e descarta o que o bot não deve responder"):
  - `2.1 Receber evento WAHA` (WAHA Trigger, **only** `message.any`, output from Phase 1 fact 3) → `CONFIG` → `INSTRUCOES` → `2.1 Normalizar mensagem`.
  - `2.1 Normalizar mensagem` (one Set node, or two named `2.1 Extrair mensagem` + `2.1 Normalizar mensagem` like car-rental). Normalized shape:
    - `idMensagem`, `sessao`.
    - `fromMe` (bool), `source` (string, `''` if absent).
    - `chatId` (`fromMe ? to : from`), `timestamp` (seconds).
    - `tipo` (per Phase 1 fact 1; D4: reactions, polls, protocol/edit/delete, empty text and unknown → `ignorar`).
    - `tipoLabel` (`áudio`, `imagem`, `vídeo`, `documento`, `localização`, `contato`).
    - `texto` (texts only), `legenda`, `nomeContato`.
    - `telefone` (digits only: from a `@c.us`/`@s.whatsapp.net` chatId, else the Phase 1 alt field, else `''`), `ehLid`.
  - `2.2.1 Ignorar grupos e canais` (Filter): chatId does not end with `@g.us`, `@broadcast` or `@newsletter`.
  - `2.2.0 Contar entrega` (Redis incr `entrega:{idMensagem}`, expire `MAX_IDADE_MSG_SEGUNDOS × 2`) → `2.2.0 Manter primeira entrega` (Filter: count = 1). Put it right after 2.2.1 (repo idempotency invariant; report it as an addition).
  - `2.2.2 Enviada por mim?` (If): true → `3.0 Enviada por mim (checar atendente)` (NoOp end, replaced in Phase 5). False continues.
  - `2.2.3 Ignorar mensagens antigas` (Filter): `now_seconds − timestamp ≤ MAX_IDADE_MSG_SEGUNDOS`.
  - `2.2.4 Aplicar allowlist de teste` (Filter): `!MODO_TESTE || ALLOWLIST.split(',').map(trim).includes(telefone)`.
  - `2.3 Rotear por tipo` (Switch):
    - `texto` → `2.3 Texto aceito` (NoOp end, continued in Phase 7).
    - `audio|imagem|video|documento|localizacao|contato` → `2.3 Mídia recebida` (NoOp end, continued in Phase 6).
    - `figurinha` and `ignorar` → end with no action.
- Chain order (later phases insert into it): `2.2.4` → [`2.2.5 …` Phase 4] → [`3.2 …` Phase 5] → `2.3 Rotear por tipo`.

**Steps.**

1. Verify node parameters with context7 and the Phase 1 findings.
2. Write the JSON (sticky notes around blocks 1–2, positions left to right).
3. Optional: import it **unpublished** and run it manually with sanitized pinned payloads (group, old, non-allowlisted, sticker, reaction, text, audio). Never commit pinData.

**Done when.**

- `jq empty workflows/*.json` passes, and `jq '.active' workflows/chatbot-waha-divercity.json` is `false`.
- A `jq` node list shows the names above, every node is inside a sticky note, and every node has a numeric prefix except `CONFIG`/`INSTRUCOES`.
- The secrets grep finds only the `COLE_O_TOKEN_AQUI` placeholder. No `@c.us`, `@g.us` or `@lid` ids with real digits.

**Not in this phase.** Contact lookup, Redis pause, debounce, agent, sends.

### Phase 4 — Filter 5: only numbers not in the phone's agenda

Status: DONE
Evidence: 8 new `2.2.5` nodes in `workflows/chatbot-waha-divercity.json` (`Pular checagem (allowlist de teste)`, `Ignorar contatos da lista`, `Tem telefone?`, `Consultar contato`, `Consulta válida?`, `Número desconhecido?`, `Restaurar mensagem`, `Log falha consulta contato`), wired `2.2.4` → `2.2.5` → `2.3 Rotear por tipo`. `jq empty workflows/*.json` passes, `active: false`, no dangling connections, existing node ids/positions unchanged, every node inside a sticky, secrets grep clean. Conditions exercised in node with synthetic items (bypass, ignore list, empty `telefone`, saved / unsaved / `name: null` / `{}` responses). Live read-only WAHA GETs confirmed the shapes: saved `@c.us` → `id,name,lid,phoneNumber`; unsaved → `id,pushname`; malformed or empty id → HTTP 200 with an empty body. `code-reviewer`: APPROVED.
Not done: the manual n8n runs with pinned payloads were **not** executed (the workflow was not run). The n8n copy of `B1fRwNFx0bFdHYGI` was **not** updated (see Deviation below), so the new nodes exist only in the repo file.
Deviation: (1) `contactId` is `<telefone>@c.us`, not `chatId` (a lookup by the `@lid` id returns no `name` for saved contacts); (2) an extra `Tem telefone?` and `Consulta válida?` If, to fail closed on an empty `telefone` and on a response without `id`; (3) spec says `isMyContact`, the signal is `name` (D3). Propose a `Deviation:` note in `spec.md` sections 2 and Filter 5.
Divergence to resolve before Phase 11: the n8n editor copy of `B1fRwNFx0bFdHYGI` differs from the repo file (layout snapped to a 16 grid, larger stickies, `availableInMCP`, `binaryMode: separate`, some Set/Code defaults; logic and connections match). Those are the owner's manual edits and win, so the file was not imported. Before Phase 11, re-export the n8n copy into the repo (with the token-safety reset) and re-apply the Phase 4 nodes on top, or accept an import that resets the layout.
Role: n8n-workflows · Depends on: 1, 3 · Covers: AC 7, 8, 9 · Size: S
Spec: 2 (filter 5), 8 row 1

**Goal.** Saved contacts never reach the bot. A failed lookup ignores the message (fail closed). Allowlisted numbers in test mode skip the check.

**Contract (D3-A).**

- Insert between `2.2.4 Aplicar allowlist de teste` and the next node:
  - `2.2.5 Pular checagem (allowlist de teste)` (If): `MODO_TESTE && ALLOWLIST includes telefone` → true bypasses to the next node.
  - `2.2.5 Ignorar contatos da lista` (Filter): `telefone` not in `CONTATOS_IGNORADOS` (comma list of digits).
  - `2.2.5 Consultar contato` (WAHA Contacts → Get, `session = CONFIG.WAHA_SESSION`, `contactId = chatId`; `onError: continueErrorOutput`). Error output → `2.2.5 Log falha consulta contato` (Set `evento: "falha_consulta_contato"`) → end.
  - `2.2.5 Número desconhecido?` (If): response has `id`, and `name` is empty/null → continue. `name` non-empty → end silently (no reply, no pause). Response without `id` → `2.2.5 Log falha consulta contato`.
  - Keep `nomeContato` = the normalized one, else `pushname` from the response (used by the group notice).
- Add a `Deviation:` proposal to the report (the spec says `isMyContact`).

**Steps.** Insert the nodes, rewire, and run manually with pinned payloads for: saved, unsaved, allowlisted-saved, and a forced lookup error (invalid contactId).

**Done when.**

- JSON is valid and the node list matches.
- Manual runs: the saved number ends at `Número desconhecido?` false, the unsaved one continues, the allowlist one bypasses, and the error ends in `Log falha consulta contato`.

**Not in this phase.** Pause, sends.

### Phase 5 — Pause and attendant detection

Status: DONE
Evidence: block 3 added to `workflows/chatbot-waha-divercity.json` (`3.1 Buscar marca de msg do bot`, `3.1 Digitada pela atendente?`, `3.1 Pausar chat`, `3.2 Mensagem do cliente`, `3.2 Buscar pausa`, `3.2 Restaurar mensagem`, `3.2 Chat pausado?`); the NoOp `3.0` is gone and both client-path inbounds to `2.3 Rotear por tipo` go through block 3.2. `jq empty workflows/*.json` passes, `active: false`, no dangling connections, secrets grep clean. Conditions and TTL (`12` → 43200 s, `0.01` → 36 s, clamped to ≥ 1) run in node with synthetic items; a throw-away Redis key in DB 1 confirmed `set … EX`, `ttl` and the empty read of a missing key. The installed `Redis.node.js` returns one item with `{propertyName: null}` for a missing key, so unpaused chats keep flowing. `code-reviewer`: APPROVED. Not done: the workflow was not run in n8n (the n8n copy differs from the repo, so it was not imported).
Interpretations: (1) the `bot-msg:` mark is keyed by the short message id (last `_` segment of `idMensagem`, `true_<chat>_<MSGID>` → `<MSGID>`), so Phases 6 and 10 must write `bot-msg:<MSGID>` from the Send Text response `id` with the same extraction and a non-empty value; (2) the two extra nodes `3.2 Mensagem do cliente` (join point) and `3.2 Restaurar mensagem` (redundant but harmless); (3) attendant messages skip the age and allowlist filters, so they pause any chat (as the spec orders the filters). Open: the `source` value of API sends (`api`) is still unconfirmed live; the `bot-msg:` mark is the fallback.
Role: n8n-workflows · Depends on: 3 · Covers: AC 12 (pause), 13, 6 (silence while paused) · Size: S
Spec: 3

**Goal.** A message typed by a person on the park phone pauses that chat for `PAUSA_HORAS`, and a paused chat gets no reply.

**Contract.**

- Block 3 sticky: "3 Pausa e atendente humana — o bot fica calado enquanto uma pessoa atende o chat".
- Replace `3.0 Enviada por mim (checar atendente)` with:
  - `3.1 Buscar marca de msg do bot` (Redis get `bot-msg:{idMensagem}`).
  - `3.1 Digitada pela atendente?` (If): `source !== 'api'` **and** the bot-message mark is empty. This combines spec 3.1 and its fallback, so it works whether or not Phase 1 found `source`. True → `3.1 Pausar chat` (Redis set `pausa:{chatId}` = `"1"`, expire `PAUSA_HORAS × 3600`; this renews it). False → end.
- Client path: insert before `2.3 Rotear por tipo`: `3.2 Buscar pausa` (Redis get `pausa:{chatId}`) → `3.2 Chat pausado?` (If): paused → end silently. Not paused → `2.3 Rotear por tipo`.
- Redis set/get keys use the normalized `chatId` (`to` for `fromMe`).

**Steps.** Add the nodes, rewire, and run manually with pinned `fromMe` payloads (`source: app`, `source: api`, absent + mark set) and a client payload with and without the pause key.

**Done when.**

- JSON is valid and the node list matches.
- Manual runs: the app-typed message sets `pausa:` with a TTL (check with `docker compose exec -T redis sh -c 'redis-cli -a "$REDIS_PASSWORD" --no-auth-warning -n 1 ttl pausa:<test chat>'`). The API message does not. A paused client message ends at `3.2`.

**Not in this phase.** Writing `bot-msg:` marks (Phases 6 and 10 do that on every bot send).

### Phase 6 — Handoff block and media path

Status: DONE
Evidence: `2.3 Mídia recebida` is now `2.3 Preparar handoff de mídia` (Set) → block 7 (`7 Nota Resposta e handoff` sticky, 11 `7.3` nodes): prepare → stop typing → send handoff → register `bot-msg:<MSGID>` (TTL 120) → pause → delete `conv:`/`buf:` → group notice or `Log sem grupo`. `jq empty workflows/*.json` passes, `active: false`, 41 nodes with unique names, no dangling connections, every node inside a sticky and no sticky overlap, no HTTP Request toward WAHA, secrets grep clean. The `Montar aviso do grupo` Code node (19 lines, pure) ran in node on synthetic data: 9-digit and 8-digit BR numbers, foreign number, empty `telefone`, 5-item `resumo`, missing fields, `INCLUIR_LINK_WA` false/true. `code-reviewer`: APPROVED. Not done: no live run in n8n, no message sent (the n8n copy differs from the repo, so it was not imported; the first live run is Phase 11).
Interpretations: (1) media gets only `MSG_MIDIA`, no second `MSG_HANDOFF_CLIENTE`; (2) `buf:{chatId}` is cleared on handoff; (3) `7.3 Parar digitação` uses `onError: continueRegularOutput` so a typing-indicator failure doesn't block the handoff; the two Send Text nodes keep the default error behavior with no retry; (4) the `bot-msg:` key takes the Send Text response `id` (string `<fromMe>_<chat>_<MSGID>` per the installed OpenAPI, object forms handled) and uses the same last-`_`-segment extraction as the Phase 5 lookup.
Non-blocking: if `Enviar msg de handoff` fails, pause/conv/buf steps do not run and the chat stays unpaused (the error workflow gets it; pausing first would leave a client silenced without a reply); `Avisar grupo` uses the untrimmed `GRUPO_ATENDIMENTO_ID` while the If tests the trimmed one; `INCLUIR_LINK_WA` is tested by truthiness (typed boolean in CONFIG).
Role: n8n-workflows · Depends on: 5 · Covers: AC 6, 12, 13 (bot sends don't pause) · Size: M
Spec: 2.3, 5.1 ("precisa de humano"), 7 (`humano` steps 1–4)

**Goal.** A single handoff path that every source can enter, wired to the media branch.

**Contract.**

- Block 7 sticky: "7 Resposta, encerramento e handoff — envia, encerra a conversa ou pausa e chama a equipe". (Phases 9/10 add more nodes here.)
- Input contract into `7.3 Preparar handoff` (Set, accepts several inputs): `resposta` (string; empty → `MSG_HANDOFF_CLIENTE`), `motivo`, `resumo` (array, up to 3 lines), `ultimoTexto`, plus `chatId`, `telefone`, `nomeContato`, `ehLid`, `sessao`.
- Media path: `2.3 Mídia recebida` becomes `2.3 Preparar handoff de mídia` (Set) → `7.3 Preparar handoff`. The agent is not called. Values:
  - `resposta = MSG_MIDIA`. Send one message only: `MSG_MIDIA` replaces `MSG_HANDOFF_CLIENTE` (interpretation, report it).
  - `motivo = "cliente enviou {tipoLabel}"`.
  - `resumo = ["Cliente enviou {tipoLabel}" + (legenda ? ": " + legenda : "")]`.
  - `ultimoTexto = legenda`.
- Handoff order (spec 7):
  1. `7.3 Parar digitação` (WAHA Stop Typing; harmless if not typing) → `7.3 Enviar msg de handoff` (WAHA Send Text, `session = CONFIG.WAHA_SESSION`, `chatId`, `text = resposta`) → `7.3 Registrar msg do bot` (Redis set `bot-msg:{sent id}`, expire 120; sent id path from the Send Text response).
  2. `7.3 Pausar chat` (Redis set `pausa:{chatId}`, expire `PAUSA_HORAS × 3600`).
  3. `7.3 Encerrar conversa` (Redis delete `conv:{chatId}`) → `7.3 Limpar buffer` (Redis delete `buf:{chatId}`, so stale text isn't answered after the pause; interpretation, report it).
  4. `7.3 Tem grupo de atendimento?` (If `GRUPO_ATENDIMENTO_ID` non-empty). False → `7.3 Log sem grupo` (Set `evento: "grupo_nao_configurado"`). True → `7.3 Montar aviso do grupo` (Code, pure, ≤ 30 lines) → `7.3 Avisar grupo` (WAHA Send Text to `GRUPO_ATENDIMENTO_ID`).
- `7.3 Montar aviso do grupo` output `texto` (spec 7). Template lines:

  ```text
  Atendimento humano necessário
  Cliente: {nomeContato || "sem nome"}{telefoneFmt ? " — " + telefoneFmt : ""}
  Conversa: https://wa.me/{telefone}
  Motivo: {motivo}
  Resumo:
  • {resumo[i]}
  Última mensagem: "{ultimoTexto}"
  O bot parou de responder este chat por {PAUSA_HORAS}h (renova a cada mensagem da atendente).
  ```

  Rules for the template:
  - `Conversa:` goes in only if `INCLUIR_LINK_WA && telefone`.
  - One `•` line per `resumo` item, max 3. Omit `Resumo:` if `resumo` is empty.
  - Omit `Última mensagem:` if `ultimoTexto` is empty.
  - `telefoneFmt`: for `55` + 2-digit DDD + 9 digits → `+55 DD NNNNN-NNNN`; + 8 digits → `+55 DD NNNN-NNNN`; otherwise `+{digits}`.
  - If `telefone` is empty (`@lid` without an alt field), show the name only and no link.
- If a Send fails, it goes to the error workflow (no blind retries, `retryOnFail` off on sends).

**Steps.** Build the nodes, wire the media branch, and run manually with a pinned audio payload from the test chat (live send to the test chat only, `GRUPO_ATENDIMENTO_ID` empty or a test group).

**Done when.**

- JSON is valid and the node list matches.
- A manual audio run: `MSG_MIDIA` arrives once in the test chat, `pausa:` is set with a TTL, `conv:`/`buf:` are gone, and the notice goes to the test group (or `Log sem grupo` ends the run). A second audio while paused ends at `3.2`.
- The group text matches the template (check the Code node output).

**Not in this phase.** The agent's `humano` and failure inputs (Phase 9).

### Phase 7 — Debounce (group messages)

Status: DONE
Evidence: `2.3 Texto aceito` replaced by block 4 (`4 Nota Agrupar mensagens` sticky + 13 nodes): push to `buf:{chatId}` → `ultima:{chatId}` → Send Seen / Start Typing → Wait `DEBOUNCE_SEGUNDOS` → last-message check → pause re-check → read/delete buffer → join → `4.6 Texto pronto`. `jq empty workflows/*.json` passes, `active: false`, no duplicate names, no dangling connections, no sticky overlap, secrets grep clean. Expressions run in node on synthetic items (same/newer id, paused/not paused, list of 3, `[]`, `null`); a throw-away list key in Redis DB 1 confirmed `rpush`/`lrange`/`del` semantics. Installed `Redis.node.js` read: `get` returns one new item `{propertyName: value}` (missing list → `[]`), `push`/`set`/`delete` return the input item, `push` has no expire; Wait 1.1 under 65 s stays in-process. `code-reviewer`: APPROVED. Not done: no live run in n8n and no message sent.
Interpretations: every expression is anchored on `$('2.3 Rotear por tipo').first().json` because Redis `get` replaces the item; Send Seen / Start Typing use `CONFIG.WAHA_SESSION` and `onError: continueRegularOutput`; Start Typing is stopped by the send nodes of blocks 7.1/7.2/7.3 (7.3 already does).
Correction to the Phase 5 note: `3.2 Restaurar mensagem` is **required** (Redis `get` replaces the item), not redundant.
Open findings (outside this phase's contract, for the owner): (1) `buf:{chatId}` has no TTL (`push` can't set one) and `3.1 Pausar chat` does not clear it, so a text waiting when the attendant pauses the chat leaves its text in the list and it is joined into the first message after the pause expires. Options: delete `buf:` in `3.1 Pausar chat`, or add a TTL step after the push; recommendation: clear `buf:` on the attendant pause (small, Phase 5 file). (2) If the winner crashes after `4.5 Apagar buffer`, that batch is lost (the error workflow fires). (3) `DEBOUNCE_SEGUNDOS` ≥ 65 moves the wait to the database; keep it under 65.
Role: n8n-workflows · Depends on: 5 · Covers: AC 14, 6 (text then audio < 5 s) · Size: M
Spec: 4

**Goal.** Messages sent in a row get one combined handling, and a handoff during the wait wins.

**Contract.**

- Block 4 sticky: "4 Agrupar mensagens — espera DEBOUNCE_SEGUNDOS, só a última mensagem segue".
- From `2.3 Texto aceito` (replace the NoOp):
  1. `4.1 Guardar texto no buffer` (Redis push to the tail of list `buf:{chatId}`, value `texto`) → `4.1 Marcar última mensagem` (Redis set `ultima:{chatId}` = `idMensagem`, expire `MEMORIA_TTL_HORAS × 3600`).
  2. `4.2 Marcar como vista` → `4.2 Começar digitação` (WAHA Send Seen / Start Typing, `session = CONFIG.WAHA_SESSION`).
  3. `4.3 Esperar debounce` (Wait, `DEBOUNCE_SEGUNDOS` seconds).
  4. `4.4 Buscar última mensagem` (Redis get) → `4.4 É a última mensagem?` (If equal to the current `idMensagem`). False → end.
  5. `4.5 Buscar pausa de novo` (Redis get `pausa:{chatId}`) → `4.5 Ainda sem pausa?` (If). Paused → end. Otherwise `4.5 Ler buffer` (Redis get, key type list) → `4.5 Apagar buffer` (Redis delete) → `4.5 Juntar textos` (Set: `texto = list.join("\n")`; if the list is empty, use the current message `texto`, which covers the read/delete race).
- The node after `4.5 Juntar textos` is `4.6 Texto pronto` (NoOp end, continued in Phase 8).

**Steps.** Build and run manually: two pinned executions close together (the second has a newer id) → only one reaches `4.6`. With the pause key set during the wait → ends at `4.5`.

**Done when.**

- JSON is valid and the node list matches.
- Manual runs behave as above, and `buf:` is deleted after the winner reads it.

**Not in this phase.** Conversation, context, agent.

### Phase 8 — Conversation session and context

Status: DONE
Evidence: block 5 added (`5 Nota Conversa e contexto` sticky + `5.1 Buscar conversa`, `5.1 Definir id da conversa`, `5.1 Renovar conversa`, `5.2 Montar contexto`, `5.3 Contexto pronto`), wired from `4.6 Texto pronto`. `jq empty workflows/*.json` passes, `active: false`, 64 nodes with unique names, no dangling connections, no sticky overlap, secrets grep clean. The exact `5.2` Code source was run in node with a stubbed `Date` and mocked `$`: the three spec lines are byte-exact (`2026-10-12 … FERIADO … weekendPrice … sundays_holidays`, `2026-10-13 … weekdayPrice … weekdays`, `2026-10-17 sábado … weekendPrice … weekdays`); `2026-10-13T02:30Z` → `segunda-feira, 12/10/2026, 23:30` (timezone correct); a 21-day calendar from 2026-12-20 crosses the month and year boundary; a holiday on a Sunday gets one `FERIADO` tag; 00:xx prints as `00:xx`; `FERIADOS` with spaces/empties parses. A throw-away Redis key in DB 1 confirmed `set … EX`/`ttl`/`del`. `code-reviewer`: APPROVED. Not done: no live run in n8n (the `conv:` reuse/refresh on a second message is checked in Phase 12).
Notes: `5.2` is 52 lines (above the ~30-line guideline; single function, readable, kept for testability); the label `(horário de Brasília)` is fixed text while `TIMEZONE` comes from CONFIG; `DIAS_CALENDARIO` has no upper cap; `conv:` is deleted by Phase 6's `7.3 Encerrar conversa` today and by Phase 10 for `resolvido`.
Role: n8n-workflows · Depends on: 7 · Covers: AC 1–4 (deterministic part), 10, 11 · Size: M
Spec: 5.1, 5.2

**Goal.** Each text gets a conversation id with a sliding TTL, and a deterministic system message with "now" and the calendar.

**Contract.**

- Block 5 sticky: "5 Conversa e contexto — id da conversa com TTL deslizante e calendário que o modelo lê".
- From `4.6 Texto pronto`:
  1. `5.1 Buscar conversa` (Redis get `conv:{chatId}`).
  2. `5.1 Definir id da conversa` (Set: `conversaId` = the existing value, or a new `{{ $now.toMillis() }}-{{ $execution.id }}`).
  3. `5.1 Renovar conversa` (Redis set `conv:{chatId}` = `conversaId`, expire `MEMORIA_TTL_HORAS × 3600`).
  4. `5.2 Montar contexto` (Code, pure, no network, pt-BR comments).
- `5.2 Montar contexto` output: `sessionKey = "{chatId}:{conversaId}"`, `textoCliente`, `mensagemSistema`. Rules (spec 5.2), all in `CONFIG.TIMEZONE`:
  - The weekday comes from a fixed array `["domingo","segunda-feira","terça-feira","quarta-feira","quinta-feira","sexta-feira","sábado"]` applied to the date in the timezone (`Intl.DateTimeFormat('en-CA', {timeZone, …})` for Y-M-D/H:M).
  - `AGORA: {dia da semana}, {DD/MM/YYYY}, {HH:MM} (horário de Brasília)`.
  - `CALENDÁRIO`: from today, `DIAS_CALENDARIO` lines: `{YYYY-MM-DD} {dia da semana}[ | FERIADO] | preço: {tier} | horário: {faixa}`. Holidays are those in `FERIADOS`.
  - Price tier: holiday or Fri/Sat/Sun → `sexta-a-domingo/feriado (weekendPrice)`, otherwise `segunda-a-quinta (weekdayPrice)`.
  - Hours tier: holiday or Sunday → `domingos e feriados (sundays_holidays)`, otherwise `segunda-a-sábado (weekdays)`.
  - `mensagemSistema = PERSONA_E_REGRAS + "\n\nFATOS DO PARQUE\n" + FATOS_DO_PARQUE + "\n\nAVISOS DE HOJE\n" + (AVISOS_DE_HOJE || "(nenhum)") + "\n\n" + AGORA + "\n\nCALENDÁRIO\n" + lines`.
- Spec test case:
  - 2026-10-12 → `2026-10-12 segunda-feira | FERIADO | preço: sexta-a-domingo/feriado (weekendPrice) | horário: domingos e feriados (sundays_holidays)`.
  - 2026-10-13 → `2026-10-13 terça-feira | preço: segunda-a-quinta (weekdayPrice) | horário: segunda-a-sábado (weekdays)`.
- `5.2 Montar contexto` → `5.3 Contexto pronto` (NoOp end, continued in Phase 9).

**Steps.** Build, then run manually and check the calendar lines for 2026-10-12, -13 and -17 (Saturday → weekendPrice/weekdays), and that a second run reuses `conv:` and refreshes its TTL.

**Done when.**

- JSON is valid. The Code node output matches the spec test case.
- `conv:` is created on the first run and reused (TTL refreshed) on the second.

**Not in this phase.** Agent.

### Phase 9 — Agent, tools, status routing to handoff

Status: DONE
Evidence: block 6 added (`6 Nota Agente` sticky; `6.1 Responder cliente` agent 3.1 with `6.1 Modelo OpenAI`, `6.1 Memória da conversa`, `6.1 Ler resposta estruturada`; tools `consultar_passaportes` / `consultar_horarios`; `7.0 Rotear por status`, `7.0 Preparar handoff do agente`, `7.1 Resposta pronta`, `7.2 Encerramento pronto`, `6.3 Preparar falha técnica`), wired `5.3 Contexto pronto` → agent → status switch → `7.3 Preparar handoff`. `jq empty workflows/*.json` passes, `active: false`, 76 nodes with unique names, no dangling connections (including `ai_*`), every node inside a sticky, no sticky overlap, no `pinData`, `SITE_API_TOKEN` still `COLE_O_TOKEN_AQUI`, secrets grep shows only the placeholder and the two Bearer expressions. Agent 3.1 / Redis memory 1.6 / OpenAI 1.3 / parser 1.3 / toolHttpRequest 1.1 parameter names read from the installed n8n 2.41.7 package. `code-reviewer`: APPROVED. Not done: no import and no live run (the n8n copy differs from the repo; first live run is Phase 11/12).
Deviation: the tool nodes are named `consultar_passaportes` / `consultar_horarios` **without** the `6.2` prefix, because `toolHttpRequest` 1.1 derives the tool name from the node name (non-alphanumerics become `_`), so `6.2 consultar_passaportes` would reach the model as `6_2_consultar_passaportes` (not the spec's verbatim name, and it starts with a digit). Report in Phase 12.
Interpretations: Switch uses loose type validation, so a missing `output.status` goes to the fallback; `7.1`/`7.2` must read `chatId` etc. from `$('5.3 Contexto pronto').first().json` in Phase 10 (the agent item carries only `output`); the `7.x` placeholders sit inside the block 6 sticky.
Non-blocking (verify live in Phase 12): HTTP 401/5xx from a tool reaches the model as tool-output text, so "no invented price" on API failure rests on prompt rule 3, not on structure (add a guard if the model ignores it); the tool descriptions hard-code the `_child`/`_companion` and `weekdays`/`sundays_holidays` key semantics, to confirm against a real API response.
Role: n8n-workflows · Depends on: 6, 8 · Covers: AC 1–5, 15 · Size: M
Spec: 6, 7 (routing), 0.5

**Goal.** The agent answers with prices and hours only from the site API, returns the structured status, and any `humano`, invalid output or failure goes to the handoff.

**Contract.**

- Block 6 sticky: "6 Agente — responde preço e horário pela API do site e decide o status".
- `6.1 Responder cliente` (AI Agent, latest typeVersion from Phase 1): prompt `textoCliente`, system message `mensagemSistema`, structured output required, `onError: continueErrorOutput`. Sub-nodes:
  - `6.1 Modelo OpenAI` (credential `{"openAiApi":{"id":"KFZp3oDrOgr20VBL","name":"OpenAI account"}}`, model `CONFIG.OPENAI_MODEL`, temperature `CONFIG.TEMPERATURA`).
  - `6.1 Memória da conversa` (Redis Chat Memory, credential `Redis account`, custom session key `sessionKey`, context window `MEMORIA_MENSAGENS`, session TTL `MEMORIA_TTL_HORAS × 3600`).
  - `6.1 Ler resposta estruturada` (Structured Output Parser, JSON schema: `resposta` string required, `status` enum `["continua","resolvido","humano"]` required, `motivo` string, `resumo` array of strings (max 3)).
  - `6.2 consultar_passaportes` (HTTP Request Tool): `GET {API_BASE_URL}{PATH_PRECOS}?type=passaportes&perPage=100`, header `Authorization: Bearer {{ $('CONFIG').first().json.SITE_API_TOKEN }}`. Model-facing description (pt-BR): "Lista os preços de passaporte (criança e acompanhante, por duração). weekdayPrice = segunda a quinta; weekendPrice = sexta a domingo e feriados. Linhas com key terminando em `_child` = criança, `_companion` = acompanhante."
  - `6.2 consultar_horarios` (HTTP Request Tool): `GET {API_BASE_URL}{PATH_HORARIOS}?perPage=100`, same header. Description: "Lista os horários de funcionamento. Use a chave (key): weekdays = segunda a sábado; sundays_holidays = domingos e feriados. Nunca decida pelo label."
  - Use HTTP Request Tools, not a Code Tool (the repo rule is no network calls in Code nodes; spec 6 allows this fallback). Tool errors, 401s and empty data reach the model as tool output, and prompt rule 3 makes that `humano`.
- `7.0 Rotear por status` (Switch on `output.status`):
  - `humano` → `7.0 Preparar handoff do agente` (Set: `resposta`, `motivo`, `resumo`, `ultimoTexto = textoCliente`) → `7.3 Preparar handoff`.
  - `continua` → `7.1 Resposta pronta` (NoOp end, Phase 10).
  - `resolvido` → `7.2 Encerramento pronto` (NoOp end, Phase 10).
  - Fallback (missing/invalid status or empty `resposta`) → `6.3 Preparar falha técnica`.
- `6.3 Preparar falha técnica` (from the agent error output and the fallback): `resposta = ""` (→ `MSG_HANDOFF_CLIENTE`), `motivo = "falha técnica"`, `resumo = []`, `ultimoTexto = textoCliente` → `7.3 Preparar handoff`.

**Steps.** Verify the agent/parser/tool parameters with context7 (n8n 2.41.7). Build, then run manually with the real token pasted in the n8n editor only (never in the repo file), on the test chat: "Quanto é a entrada?", "quanto é na terça?", "quero fazer uma festa", and once with a wrong token.

**Done when.**

- JSON is valid. The repo file has `SITE_API_TOKEN = "COLE_O_TOKEN_AQUI"`.
- Manual runs: price questions end at `7.1 Resposta pronta` with prices that match the API, the party question and the wrong-token run reach the handoff (the test chat gets the handoff message), and no invented prices appear.

**Not in this phase.** Sending `continua`/`resolvido` replies.

### Phase 10 — Reply and close paths (`continua`, `resolvido`)

Status: DONE
Evidence: 7 nodes added in block 7 (`7.1 Parar digitação`, `7.1 Enviar resposta`, `7.1 Registrar msg do bot`, `7.2 Parar digitação`, `7.2 Enviar despedida`, `7.2 Registrar msg do bot`, `7.2 Encerrar conversa`) and wired from the `7.1`/`7.2` entry nodes; sticky 7 height 420 → 700 to enclose them. `jq empty workflows/*.json` passes, `active: false`, 83 nodes with unique names, no dangling connections, every node inside a sticky, no sticky overlap, no path from `7.2` to any `pausa:` write or `7.3 *` node, secrets grep clean. The `bot-msg:` key written here equals the key looked up by `3.1 Buscar marca de msg do bot` (last `_` segment of the id). `code-reviewer`: APPROVED. Not done: no live run (checked live in Phase 11/12).
Interpretations: `bot-msg:` is written on every bot send (spec 7 lists it only under `continua`); the entry NoOps `7.1 Resposta pronta` / `7.2 Encerramento pronto` stay as entry points (the only remaining NoOps are those, `3.2 Mensagem do cliente`, `4.6 Texto pronto`, `5.3 Contexto pronto`, all deliberate join/entry points); text and chatId come from `$('7.0 Rotear por status')` and `$('5.3 Contexto pronto')`.
Non-blocking: a failed Send Text on `7.1`/`7.2` goes to the error workflow with no dedicated path (same as `7.3`); the sticky 7 text does not mention the reply and close paths.
Role: n8n-workflows · Depends on: 9 · Covers: AC 10, 13 · Size: S
Spec: 5.1 ("dúvidas resolvidas"), 7 (`continua`, `resolvido`)

**Goal.** Normal replies and farewells are sent and marked as bot messages. A farewell ends the conversation without a pause.

**Contract.**

- `7.1 Resposta pronta` → `7.1 Parar digitação` → `7.1 Enviar resposta` (WAHA Send Text, `text = output.resposta`) → `7.1 Registrar msg do bot` (Redis set `bot-msg:{sent id}`, expire 120).
- `7.2 Encerramento pronto` → `7.2 Parar digitação` → `7.2 Enviar despedida` → `7.2 Registrar msg do bot` → `7.2 Encerrar conversa` (Redis delete `conv:{chatId}`). No pause and no group notice.
- Spec 7 lists `bot-msg:` only under `continua`. It is written on every bot send, because spec 3 says bot messages never pause (interpretation, report it).

**Steps.** Replace the NoOps, then run manually on the test chat: a price question (reply arrives), then "era só isso, obrigado" (farewell arrives, `conv:` deleted, no `pausa:`).

**Done when.**

- JSON is valid, and no NoOp placeholders remain anywhere in the workflow.
- Manual runs match the steps. The `fromMe` webhook of the bot's reply doesn't set `pausa:` (checked live in Phase 11).

**Not in this phase.** Publishing.

### Phase 11 — Hook routing, import and publish in test mode

Status: DONE
Evidence (2026-10-13): `docker-compose.yml` `WHATSAPP_HOOK_URL` → `33e5dd5f-b628-4552-ba1c-d5cf09b54deb/waha`, `docker compose config -q` passes; workflow `chatbot-waha-divercity` (83 nodes) published (`active = t`) in test mode (`MODO_TESTE = true`, `ALLOWLIST` and the real token pasted in the n8n editor only; the repo copy keeps `COLE_O_TOKEN_AQUI` and empty lists, secrets grep clean); `waha` session `Default` `WORKING`. Live test chat (allowlisted number): the bot answered "Quanto é a entrada?" with the API prices (12/10 holiday → `weekendPrice`, 12h–20h), execution 183 `success` in 14.3 s (5 s debounce + ~8 s agent); the bot's own `fromMe` messages did not pause the chat (AC 13); a handoff reached the group (AC 12 notice).
Defects found and fixed by the first live runs (Phase 9 follow-ups, in the same commit): (1) `toolHttpRequest` 1.1 cannot be run by agent 3.1 in n8n 2.41.7 (`has a "supplyData" method but no "execute" method`), so `consultar_passaportes` / `consultar_horarios` are now `n8n-nodes-base.httpRequestTool` 4.5 with `neverError: true` and the same names and manual descriptions; (2) the model answered in plain text and the structured parser failed (`Model output doesn't fit required format`), so `6.1 Ler resposta estruturada` has `autoFix: true` and `6.1 Modelo OpenAI` is also wired to it through `ai_languageModel`; a failed auto-fix still ends in `6.3` (handoff). Also applied: repo `settings` `binaryMode: separate` + `availableInMCP: true` (D6-A).
Open findings for the owner: (a) the model closed the conversation with `resolvido` on the first price answer ("Qualquer dúvida é só chamar!"), which deletes `conv:`, so a follow-up like "terça" starts a new context; the persona text is spec Annex A, so changing it is the owner's call; (b) typing indicator lasts the whole run (about 14 s: it starts before the 5 s debounce); `DEBOUNCE_SEGUNDOS` in `CONFIG` is the no-code knob, or Start Typing can move after the wait (a Phase 7 change); (c) `/tmp/divercity-import.json` and `/tmp/divercity-patched.json` remain inside the n8n container (contain the pasted values; `rm` is denied).
Role: n8n-workflows · Depends on: 2–10 · Covers: enables the live AC runs · Size: S
Spec: 2.1, 10

**Goal.** Real WAHA events reach the new, published workflow, with `MODO_TESTE = true`.

**Contract (D2-A).**

- `docker-compose.yml`: `WHATSAPP_HOOK_URL: http://n8n:5678/webhook/<new webhookId>/waha # WAHA Trigger of chatbot-waha-divercity (<webhookId>/waha)`. Events stay `message.any`. No other compose change.
- `docker compose up -d waha` (recreates only waha; the session is stored in Postgres). Never `down`, `-v` or a logout.
- Import the workflow if it's missing (`n8n import:workflow --separate --input=…`). If an n8n copy exists, diff it first, because UI edits win. Then `n8n publish:workflow --id=<id>` and `docker compose restart n8n n8n-worker` (the CLI publish needs a restart, per `setup.sh`).
- The owner pastes the real `SITE_API_TOKEN`, `ALLOWLIST` (test numbers) and optionally `GRUPO_ATENDIMENTO_ID` (test group) in the n8n editor.
- `scripts/setup.sh` keeps publishing the car-rental example on fresh installs (out of scope; reported).

**Steps.** Edit compose, run `docker compose config -q`, recreate waha, import, publish, restart, then send one test text from an allowlisted number and check an execution reaches a reply.

**Done when.**

- `docker compose config -q` passes. The WAHA session `Default` is still WORKING.
- The workflow is published, and a test-chat text gets a bot reply.

**Not in this phase.** The full AC walkthrough.

### Phase 12 — Verification and report

Status: DONE (owner closed the work on 2026-10-13; the live walkthrough of AC 1–17 was partial, see below)
Evidence: gate: `jq empty workflows/*.json`, `docker compose config -q`, `bash -n scripts/setup.sh` pass; secrets/PII grep clean (`COLE_O_TOKEN_AQUI` once, in the main workflow; `ALLOWLIST`, `CONTATOS_IGNORADOS`, `GRUPO_ATENDIMENTO_ID` empty; no `pinData`; no `dvc_` token, no real phone or group id). Final `code-reviewer` over the full diff: APPROVED, no blocking findings (AC table: every AC has an implementing node). The workflow was split into 5 workflows at the owner's request and re-exported from n8n with the token-safety reset (repo files = what is in n8n, minus secrets and test values: the n8n copy had `DEBOUNCE_SEGUNDOS = 1` and `PAUSA_HORAS = 0.001` while testing, the repo keeps `5` and `12`). End-to-end run after the split on the test chat: executions 261–265 (main → Filtros → Agrupar mensagens → Agente → Resposta e handoff), all `success`, about 5 s with a 1 s debounce.
Live results (owner's allowlisted test number, 2026-10-12/13): AC 2 PASS (12/10 holiday → `weekendPrice`, 12h–20h, prices match the API); AC 13 PASS for the bot's own messages (no pause from `fromMe` echoes); AC 12 PASS for the group notice and the pause; AC 5/15 paths exercised by a handoff (parser failure and `falha técnica`), fixed afterwards. Not live-tested: AC 1 (ask the day) after the final persona, 3, 4, 5 (party), 6 (media, sticker, text+audio), 7/8 (saved vs unsaved contact), 9, 10 (`resolvido`), 11 (TTL), 14 (burst), 15 (wrong token, API down), 16, 17, and AC 13 for a message typed on the phone.
Open for the owner (manual): restore `DEBOUNCE_SEGUNDOS = 5` and `PAUSA_HORAS = 12` in the n8n `CONFIG` if the test values are still there; fill `FATOS_DO_PARQUE` (no `[PREENCHER]`); add the city's local holidays to `FERIADOS`; set `MODO_TESTE = false` only after sign-off; revoke the test `SITE_API_TOKEN` that was pasted in the chat; back up `N8N_ENCRYPTION_KEY` and schedule Postgres backups. Known non-blocking findings: `buf:` has no TTL and `3.1 Pausar chat` does not clear it (stale text can be joined into the first message after a pause); a failed Send Text on `7.x` goes to the error workflow with no reply to the client; the error workflow can fire twice for a failure inside a sub-workflow; leftover `/tmp/dv-*.json` and `/tmp/divercity-*.json` files in the n8n container contain the pasted values (removal denied; they go away when the container is recreated).
Deviations (all recorded as `Deviation:` notes in `spec.md` section 11): 5 workflows instead of one; `name` instead of `isMyContact`; `chatId` for `@lid` chats; `entrega:` dedupe and `bot-msg:` on every send; media gets only `MSG_MIDIA`; HTTP Request Tool 4.5 and no Structured Output Parser; conversational persona; `WAHA_SESSION = Default`; `.first()`; all-Portuguese identifiers (an exception to the `CLAUDE.md` English rule).
After phase 12 (owner request, 2026-10-13, not a planned phase): `CONFIG` and `INSTRUCOES` moved from Set nodes to Data Tables (`chatbot_divercity_config`, `chatbot_divercity_instrucoes`, same node names), the site token moved to the credential `Site API token` (id `iISSUrB21uA7tonr`, created by `scripts/setup.sh`), and the idempotent installer `[chatbot] Divercity - Instalar tabelas` (`95TKiRbbJEt5mYLg`, file `chatbot-waha-divercity-install.json`) was added. The installer must be run once from the n8n editor (`n8n execute` cannot load the Data Tables module). Live: installer execution 269 `success`, both tables present, the config row holds the owner's allowlist and group (not in the repo). Workflows re-exported from n8n (6 files) with no secrets; `jq empty` passes and the secrets grep is clean. Documented in `spec.md` section 11.
Role: n8n-workflows (+ `qa-tester`, then `code-reviewer`) · Depends on: 1–11 · Covers: all ACs · Size: M
Spec: 9, 8, 10

**Goal.** Prove every acceptance criterion live on test chats, sweep for secrets/PII, and hand the owner the go-live checklist.

**Contract.**

- Gate:
  - `jq empty workflows/*.json`, `docker compose config -q`, `bash -n scripts/setup.sh`.
  - The secrets/PII grep from `project-core`, plus `grep -n "SITE_API_TOKEN" workflows/chatbot-waha-divercity.json`, which must show only the placeholder.
  - No real digits in `ALLOWLIST`, `CONTATOS_IGNORADOS` or `GRUPO_ATENDIMENTO_ID`. No `pinData`.
- Live smoke tests (test numbers only, test group): AC 1–17 in order.
  - Timing ACs: use `DEBOUNCE_SEGUNDOS = 5`.
  - AC 11/12: temporarily lower `MEMORIA_TTL_HORAS`/`PAUSA_HORAS` in the n8n editor (e.g. 0.01) and restore them after.
  - AC 15: use a wrong token in the editor, then restore it.
  - AC 7/8: one saved and one unsaved test number, with `MODO_TESTE` toggled in the editor.
  - AC 13: the owner types on the park phone, and a bot reply doesn't pause.
- Record pass/fail per AC in this plan (no PII). Re-export the n8n copy if it changed during testing, with the token-safety reset.
- Report: the spec deviations, as proposed `Deviation:` lines for the owner:
  - D3 signal (`name` instead of `isMyContact`).
  - `bot-msg:` on every send.
  - `MSG_MIDIA` as the single handoff message for media.
  - `buf:` cleared on handoff.
  - `entrega:` dedupe added.
  - `WAHA_SESSION = Default`.
  - `.first()` instead of `.item`.
  - D1 all-Portuguese identifiers (an exception to `CLAUDE.md`).
- Owner manual checklist:
  - Fill `FATOS_DO_PARQUE` (no `[PREENCHER]` left; the model could quote it).
  - Add the city's local holidays to `FERIADOS`.
  - Paste the real token and set `GRUPO_ATENDIMENTO_ID`.
  - Set `MODO_TESTE = false` only after sign-off.
  - Back up `N8N_ENCRYPTION_KEY` and schedule Postgres backups (spec 10).

**Steps.** Run the gate, run the smoke tests with the owner, have `code-reviewer` review the workflow diff against this plan, and write the results.

**Done when.**

- All gate commands pass, and every AC is marked pass (or failing with its cause and a follow-up).
- The deviation list and owner checklist are delivered.

**Not in this phase.** Switching `MODO_TESTE` off or any production rollout.
