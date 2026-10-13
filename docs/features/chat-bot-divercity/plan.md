# Plan — Bot de atendimento WhatsApp do Divercity Park ("Dry"): confirmação de encerramento por silêncio

Source spec: `docs/features/chat-bot-divercity/spec.md` · SHA-256 `0dbc1a6e92e56dca1c31bcc3c95fd60982488130fdd9f605dcdc2515f89112b3`
Product truth: the spec itself (no separate product doc).
Run phases with `/execute-phases docs/features/chat-bot-divercity/plan.md <phases>` — one or a few per
session. Phase status is updated in place in this file.

Scope of this plan: the bot is built and running in test mode (two earlier plans, all phases DONE, removed by the
owner; still in git: `git show 40009a0:docs/features/chat-bot-divercity/plan.md`). This plan covers **only the delta**
listed in spec section 11 "Pendente de implementação" (2026-10-13): the closing confirmation moves out of the agent's
reply and is sent as a fixed message after `CONFIRMACAO_MINUTOS` of customer silence (spec 1.1, 1.2, 5.1, 6, 7;
ACs 18–21 rewritten, 26–32 new). Everything else stays untouched.

## Status board

| Phase | Title                                                               | Role          | Depends on | Size | Status  |
| ----- | ------------------------------------------------------------------- | ------------- | ---------- | ---- | ------- |
| 1     | Installer defaults: new persona closing rules + two new columns     | n8n-workflows | none       | S    | DONE |
| 2     | Agent parser passes `aguarda_cliente`                               | n8n-workflows | none       | S    | DONE |
| 3     | New subworkflow `[chatbot] Divercity - Confirmação`                 | n8n-workflows | none       | S    | IN_PROGRESS |
| 4     | Wire the timer: start after `continua`, cancel on customer message  | n8n-workflows | 2, 3       | S    | PENDING |
| 5     | Deploy the workflow changes to the live n8n (feature still inert)   | n8n-workflows | 2, 3, 4    | S    | PENDING |
| 6     | Live Data Tables: add columns, set values, new persona (feature on) | n8n-workflows | 1, 5       | S    | PENDING |
| 7     | Verification and report                                             | n8n-workflows | 1–6        | S    | PENDING |

## Audit — 2026-10-13

| Check | Result |
| ----- | ------ |
| Versions | n8n `2.41.7` (container `n8n --version`), `EXECUTIONS_MODE: queue` with workers, Redis shared with the bull queue (queue on db 0, chatbot keys on db 1). WAHA node `@devlikeapro/n8n-nodes-waha.WAHA` 202502. No `package.json`. |
| Workflows in repo | `workflows/chatbot-waha-divercity{,-filters,-debounce,-agent,-reply,-install}.json`, all valid, clean working tree. Ids: main `B1fRwNFx0bFdHYGI`, filters `AvWLP9xiCyvHhyn8`, debounce `9tJm4MQCI1leSWEm`, agent `T36H0vXQgPRsPGNe`, reply `msQXMvHkSmTdK8Ll`, install `95TKiRbbJEt5mYLg`. Error workflow `FF0x666oa1bfHLDI` on all. |
| Data flow | Main calls each sub with `Execute Workflow` 1.4, `waitForSubWorkflow: true`; subs use `executeWorkflowTrigger` 1.1 with `inputSource: passthrough`, and rebuild `CONFIG`/`INSTRUCOES` with Set nodes from `$json.CONFIG` / `$json.INSTRUCOES`. The agent sub's `6.2 Entregar resposta` passes `output` (whole object) plus `chatId`, `telefone`, `nomeContato`, `ehLid`, `sessao`, `textoCliente`, `CONFIG`, `INSTRUCOES` to the reply sub. `conversaId` is **not** passed (read `conv:{chatId}` instead). |
| Agent output | `6.1 Interpretar resposta` (Code) returns `{ output: { resposta, status, motivo, resumo } }` and **drops any other field**, so `aguarda_cliente` must be added there (Phase 2). |
| Reply `continua` branch | `7.1 Resposta pronta → 7.1 Parar digitação → 7.1 Enviar resposta → 7.1 Registrar msg do bot` (`bot-msg:{id}`, TTL 120 s; id normalized with `split('_').pop()`). No timer today. |
| Debounce entry | `4.1 Guardar texto no buffer` (push `buf:{chatId}`) → `4.1 Marcar última mensagem`. Media messages do not pass here (they go straight to handoff, which deletes `conv:`). Stickers are dropped in the filters. |
| Memory | `6.1 Memória da conversa` = `memoryRedisChat` 1.6, `sessionKey = {chatId}:{conversaId}` (list in Redis db 1), TTL `MEMORIA_TTL_HORAS`, window `MEMORIA_MENSAGENS`. Entry format and push direction must be copied from a live key (LangChain `RedisChatMessageHistory`: entries are JSON `{type, data:{content,...}}`, newest pushed at the head); the AI entries hold the agent's raw JSON text. |
| Persona today | `PERSONA_E_REGRAS` (installer default and live row since commit `40009a0`) has an `ENCERRAMENTO` section that tells the model to end replies with "Isso resolve a sua dúvida?". This is the behavior the owner called rude; spec 5.1 rule 1 forbids it. |
| Live Data Tables | n8n reachable through n8n-mcp. `chatbot_divercity_config` (`4B59btz6FrMV1Jad`, 18 columns) has no `CONFIRMACAO_MINUTOS`; `chatbot_divercity_instrucoes` (`m3KqByTDF4n2e6vq`, 6 columns) has no `MSG_CONFIRMACAO`. Project `WmTLuU6wVL8hJ9rD`. The installer only creates tables/rows that are missing (`createIfNotExists`), so new columns on existing tables need `addColumn` (n8n-mcp, uses `N8N_MCP_ACCESS_TOKEN`). |
| Installer | `Criar tabela de configuração` / `Criar tabela de instruções` list columns; `Inserir configuração padrão` / `Inserir instruções padrão` hold the default row (`columns` mapping with values and `schema`). |
| Wait in queue mode | `Wait` 1.1 already used by the debounce (`amount` from config, default unit seconds). Waits over 65 s are persisted and resumed by the main instance, so a 2-minute wait survives in queue mode. A `Wait` inside a sub started with `waitForSubWorkflow: false` must be confirmed live (Phase 7, short interval). |
| Spec divergence (not in this plan) | Spec 1.1 says `PAUSA_HORAS` starts at `2`; the installer default is `12` and the live row was hand-set to a test value by the owner on 2026-10-13. Report only; propose a `Deviation:` note. |
| Checks that exist | `jq empty workflows/*.json`, `docker compose config -q`, the secrets grep from `project-core`, n8n-mcp `validate_workflow` on edited JSON. No tests. |

## Owner decisions

### D1 — How the workflow changes reach the live n8n — RESOLVED 2026-10-13: option A

Owner chose the recommended option for every open decision. Options considered:

Blocked: Phase 5 (now unblocked) · Options: A (recommended) the executor reads each live workflow with n8n-mcp, compares it with the repo version **before** this plan's edits (`git show HEAD:<file>`, ignoring `updatedAt`/`versionId`/positions); if equal, it shows the change summary, and after the owner approves in that session it updates the live workflow and imports the new `Confirmação` sub (new id, so nothing is overwritten); if a live workflow differs from HEAD, it stops and reports the diff (manual edits win, `CLAUDE.md`) · B the owner imports the four files in the n8n editor by hand · C `scripts/setup.sh` (imports only workflows missing in n8n: would add the new sub but not update agent/reply/debounce) · Why: updating a live workflow overwrites it; the live copies may have editor changes.

### D2 — Writing the live Data Tables — RESOLVED 2026-10-13: option A

Owner chose the recommended option. Options considered:

Blocked: Phase 6 (now unblocked) · Options: A (recommended, same procedure as the previous plan's D1) the executor adds the two columns, then reads row `id` 1 of each table, shows the diff, and after the owner approves writes only `CONFIRMACAO_MINUTOS`, `MSG_CONFIRMACAO` and `PERSONA_E_REGRAS` (every other column untouched) · B the owner adds the columns and pastes the values in the **Data tables** tab; the executor only supplies them · Why: the rows may hold hand edits (owner or the owner's spouse), and this switches the feature on in the running bot.

### D3 — Spec OD1 / OD2 (companion rules, bar items) — RESOLVED 2026-10-13: keep the current defaults

Blocks: nothing. Unchanged by this plan; the current defaults stay (bot does not talk about companions/discounts; bar = chopp and petiscos).

## Global constraints (every phase)

- Git is read-only; commits only through `/execute-phases`. No dependency, community node, image tag or n8n version change. No tests written (`CLAUDE.md`).
- Identifiers, node names, Redis keys and message copy in Portuguese, per the owner's exception (spec 11, memory). This plan's prose stays English.
- Node naming follows the block prefix convention (`7.1 ...`, `8.x ...` for the new sub). Existing node names, ids and positions stay as they are; new nodes get new UUIDs.
- Redis keys live in the `Redis account` credential (`rD7k2Mx9QpL4vWn3`, db 1). Never touch db 0, never `FLUSHDB`/`FLUSHALL`, never delete keys other than the ones named in a phase.
- Every new workflow sets `settings.errorWorkflow = "FF0x666oa1bfHLDI"`, `executionOrder: "v1"`, like the others.
- `MSG_CONFIRMACAO` is sent exactly as stored in `INSTRUCOES`, never rewritten by the model (spec 5.1 rule 3).
- Fail safe: if `CONFIRMACAO_MINUTOS` is missing, not a number or `<= 0`, or `MSG_CONFIRMACAO` is empty, no confirmation is scheduled or sent. This keeps the feature inert until Phase 6 and makes it switchable from the Data Table.
- At most one `MSG_CONFIRMACAO` per bot reply; no loops, no bulk sends (spec 5.1 rule 5, `whatsapp-gateway`).
- No secrets, phone numbers, chat ids or group ids in any file.
- Do not edit `spec.md`. Divergences are reported with a proposed `Deviation:` note.
- Live sends only in Phase 7, only to the owner's allow-listed test number, with the owner present.

## Acceptance-criteria coverage

| AC (spec 9) | Phases |
| ----------- | ------ |
| 1–9, 11–17, 22–25 (built and verified earlier; behavior unchanged) | 7 (regression smoke: 5, 6, 12, 13, 14) |
| 10 "era só isso, obrigado" → `resolvido`, no pause, no later `MSG_CONFIRMACAO` | 1, 6, 7 |
| 18 price/hour answer: no confirmation question, `continua`, `aguarda_cliente = false` | 1, 2, 6, 7 |
| 19 "sim, resolvido" after `MSG_CONFIRMACAO` → `resolvido`, `conv` deleted, no pause, new conversation | 1, 3, 6, 7 |
| 20 "não resolveu" after `MSG_CONFIRMACAO` → `humano`, pause, group notice | 1, 3, 6, 7 |
| 21 other question after `MSG_CONFIRMACAO` → answered, timer restarts, sent again after silence | 1, 3, 4, 6, 7 |
| 26 silence after a price answer → `MSG_CONFIRMACAO` once, chat not paused | 3, 4, 5, 6, 7 |
| 27 customer writes before the interval → no `MSG_CONFIRMACAO` for that reply | 3, 4, 7 |
| 28 bot asked "Qual o dia da visita?" (`aguarda_cliente = true`) → nothing sent | 1, 2, 4, 7 |
| 29 no answer to `MSG_CONFIRMACAO` → nothing else sent; new conversation after `MEMORIA_TTL_HORAS` | 3, 7 |
| 30 handoff or `resolvido` before the interval → no `MSG_CONFIRMACAO` | 3, 7 |
| 31 attendant typed (chat paused) before the interval → no `MSG_CONFIRMACAO` | 3, 7 |
| 32 changing `CONFIRMACAO_MINUTOS` in the Data Table applies to the next reply without reimport | 3, 4, 6, 7 |

## Phases

### Phase 1 — Installer defaults: new persona closing rules + two new columns

Status: DONE
Evidence: 2026-10-13. Only `workflows/chatbot-waha-divercity-install.json` changed: `CONFIRMACAO_MINUTOS` (number, default 2) and `MSG_CONFIRMACAO` (string, exact copy) added to the create-table and insert-default nodes, schema entries mirror `PAUSA_HORAS` / `MSG_MIDIA`; persona `ENCERRAMENTO` + `STATUS E FORMATO DE SAÍDA` equal the plan text (jq extract + diff: same), prefix before `ENCERRAMENTO` byte-identical to HEAD (cmp). `jq empty workflows/*.json` OK; `docker compose config -q` OK. code-reviewer: APPROVED, no findings. Nothing live touched.
Role: n8n-workflows · Depends on: none · Covers: AC 10, 18–21, 28 (prompt side) · Size: S
Spec: 1.1, 1.2, 5.1 (rules 1, 2, 7–12), 6

**Goal.** The versioned defaults in `chatbot-waha-divercity-install.json` match the spec: the persona no longer asks
"resolveu?" in the reply and emits `aguarda_cliente`; the two tables get the new columns with default values.
Repo only; nothing live changes.

**Contract.**

- File: `workflows/chatbot-waha-divercity-install.json` only.
- `Criar tabela de configuração`: append column `{ "name": "CONFIRMACAO_MINUTOS", "type": "number" }`.
  `Inserir configuração padrão`: value `CONFIRMACAO_MINUTOS: 2` and its `schema` entry, mirroring `PAUSA_HORAS`.
- `Criar tabela de instruções`: append `{ "name": "MSG_CONFIRMACAO", "type": "string" }`.
  `Inserir instruções padrão`: value exactly
  `Consegui te ajudar com o que você precisava? Se ficou alguma dúvida, é só me falar 😊`, schema entry mirroring `MSG_MIDIA`.
- `PERSONA_E_REGRAS` default: replace **only** the `ENCERRAMENTO` section and the `STATUS E FORMATO DE SAÍDA` section
  with the text below; every other section stays byte-identical.

```text
ENCERRAMENTO
- Não termine suas respostas perguntando se a dúvida foi resolvida ("Isso resolve a sua dúvida?", "Resolveu?",
  "Posso ajudar em algo mais?" ou parecido). Responda só o que o cliente perguntou. Se o cliente ficar em silêncio,
  o sistema pergunta depois, sozinho, se você conseguiu ajudar.
- Se a sua última mensagem foi essa pergunta e o cliente confirmar ("sim", "resolveu", "era só isso", "obrigado"):
  status "resolvido" com a despedida.
- Se o cliente disser que NÃO resolveu: status "humano".
- Se o cliente responder com outra pergunta: responda normalmente e use "continua".
- Se o cliente encerrar por conta própria ("era só isso, obrigado"): isso já é a confirmação; use "resolvido".

STATUS E FORMATO DE SAÍDA
- Responda SEMPRE e SOMENTE com um objeto JSON, sem texto fora dele e sem bloco de código:
  {"resposta": "...", "status": "continua", "aguarda_cliente": false, "motivo": "...", "resumo": ["..."]}
- "aguarda_cliente": true quando a sua resposta termina pedindo ao cliente algo que você precisa para continuar
  (dia da visita, duração, o que ele quer saber; cumprimentos como "Como posso ajudar?" também são true).
  false quando você já respondeu o que o cliente perguntou.
- "continua": você respondeu ou fez uma pergunta e a conversa segue. Vale para cumprimentos e para respostas de
  preço ou horário.
- "resolvido": somente quando o cliente confirmar que a dúvida foi resolvida (ver ENCERRAMENTO) ou encerrar por
  conta própria de forma explícita. "resposta" é uma despedida curta, em uma linha ("Qualquer dúvida é só chamar!").
  Nunca use "resolvido" na mesma resposta em que informa preço ou horário.
- "humano": precisa de atendente. "resposta" avisa o cliente que uma atendente vai
  continuar a conversa; "motivo" é curto; "resumo" tem até 3 linhas com o que o cliente
  perguntou e onde parou.
```

**Steps.**

1. Read the two `Criar tabela ...` and two `Inserir ...` nodes; add the columns/values following the existing entries.
2. Replace the two persona sections (JSON string, `\n` line breaks), leaving the rest of the string identical.
3. `jq empty`, then confirm with `jq` that the persona string still contains `COMO CONVERSAR`, `REGRAS`, `PASSAPORTE`,
   `HORÁRIO` unchanged and no longer contains `Isso resolve a sua dúvida?` as an instruction to ask.

**Done when.**

- Both tables' column lists and default rows include the new column with the values above.
- The persona default has the new `ENCERRAMENTO` and `STATUS E FORMATO DE SAÍDA`; `git diff` shows no other change in the string.
- `jq empty workflows/*.json` and `docker compose config -q` pass.

**Not in this phase.** Running the installer, any live Data Table write (Phase 6), any other workflow.

### Phase 2 — Agent parser passes `aguarda_cliente`

Status: DONE
Evidence: 2026-10-13. Only the `jsCode` of `6.1 Interpretar resposta` in `workflows/chatbot-waha-divercity-agent.json` changed. Local Node run of the function: explicit false → false; missing field → true; free text → `continua` + true; broken JSON → `VAZIO` + true; `{output:{...false}}` → false. `jq empty workflows/*.json` OK; n8n-mcp `validate_workflow` 0 errors. code-reviewer: APPROVED. Note: the `6.2 Entregar resposta` fallback default has no `aguarda_cliente`; Phase 4 only arms the timer on `=== false`, so undefined is safe.
Role: n8n-workflows · Depends on: none · Covers: AC 18, 28 · Size: S
Spec: 5.1 rule 2, 6 (`aguarda_cliente`)

**Goal.** `6.1 Interpretar resposta` returns `aguarda_cliente` so the reply sub can decide whether to start the timer.

**Contract.**

- File: `workflows/chatbot-waha-divercity-agent.json`, node `6.1 Interpretar resposta` only.
- Output shape becomes `{ output: { resposta, status, aguarda_cliente, motivo, resumo } }`.
- `aguarda_cliente = (obj.aguarda_cliente === false || obj.aguarda_cliente === 'false') ? false : true`
  (missing or invalid counts as `true`, spec 6). For the plain-text fallback (`status: 'continua'` from free text)
  and for `VAZIO`, `aguarda_cliente: true`.
- Update the first comment line to list the new field. No other node changes (`6.2 Entregar resposta` already
  forwards `output` whole).

**Steps.**

1. Edit the `jsCode`; keep the rest of the logic identical.
2. Run the function body locally with Node on sample inputs: `{"resposta":"x","status":"continua","aguarda_cliente":false}` → false;
   same without the field → true; `"texto livre"` → true; broken JSON → `VAZIO` with true.

**Done when.**

- The four sample cases give the results above.
- `jq empty workflows/*.json` passes; n8n-mcp `validate_workflow` on the agent JSON reports no new errors.

**Not in this phase.** Prompt text (Phase 1), reply routing (Phase 4).

### Phase 3 — New subworkflow `[chatbot] Divercity - Confirmação`

Status: IN_PROGRESS
Role: n8n-workflows · Depends on: none · Covers: AC 19–21, 26, 27, 29–32 (send side) · Size: S
Spec: 5.1 rules 3, 5, 6, 10, 13; 7 (`continua`)

**Goal.** A standalone sub that waits, re-checks the chat, and sends `MSG_CONFIRMACAO` once. Valid on its own, not
called by anything yet.

**Contract.**

- New file `workflows/chatbot-waha-divercity-confirm.json`, name `[chatbot] Divercity - Confirmação`, a new
  16-character alphanumeric workflow id (record it in this plan's evidence), inactive, `settings` like the reply sub
  (`errorWorkflow` `FF0x666oa1bfHLDI`).
- Input (passthrough, one item): `{ chatId, token, CONFIG, INSTRUCOES }`. `token` = the normalized id of the bot reply
  that started the timer.
- Nodes, in order (prefix `8`):
  1. `Receber da resposta` — `executeWorkflowTrigger` 1.1, `inputSource: passthrough`.
  2. `CONFIG`, `INSTRUCOES` — Set 3.5 raw from `$json.CONFIG` / `$json.INSTRUCOES` (same as other subs).
  3. `8.0 Dados recebidos` — Set raw: input without `CONFIG`/`INSTRUCOES` (copy of `7.0 Dados recebidos`).
  4. `8.1 Esperar silêncio` — Wait 1.1, time interval, `amount = Math.max(1, Math.round(CONFIRMACAO_MINUTOS * 60))`, `unit: seconds`.
  5. `8.2 Buscar confirmação` — Redis get `confirmar:{chatId}` → `confirmacao`.
  6. `8.2 Buscar pausa` — Redis get `pausa:{chatId}` → `pausa`.
  7. `8.2 Buscar conversa` — Redis get `conv:{chatId}` → `conversaId`.
  8. `8.2 Ainda pode perguntar?` — IF: `confirmacao === token` **and** `!pausa` **and** `conversaId` non-empty **and**
     `MSG_CONFIRMACAO` non-empty. False → end silently.
  9. `8.3 Consumir confirmação` — Redis delete `confirmar:{chatId}` (one send per reply).
  10. `8.3 Enviar confirmação` — WAHA `Chatting / Send Text`, `session = CONFIG.WAHA_SESSION`, `chatId`, `text = INSTRUCOES.MSG_CONFIRMACAO`.
      On error: continue through the error output to `8.3 Log falha no envio` (Set with `chatId` and the error; no retry, no handoff, spec 5.1 rule 13).
  11. `8.3 Registrar msg do bot` — Redis set `bot-msg:{normalized sent id}` = `1`, TTL 120 (same expression as `7.1 Registrar msg do bot`).
  12. `8.4 Gravar na memória` — Redis push to list `{chatId}:{conversaId}` of one AI entry whose content mirrors the
      agent's own AI entries (JSON text `{"resposta": MSG_CONFIRMACAO, "status": "continua", "aguarda_cliente": true, "motivo": "", "resumo": []}`).
      Entry format and head/tail direction **copied from a live memory key** (`LRANGE` of a real `{chatId}:{conversaId}`
      list on db 1, read-only) and recorded in the evidence. If no live key exists, create one by a test conversation in Phase 7 and finish this node then; do not guess the format.
- No `Send Seen`, no typing indicator.

**Steps.**

1. Build the JSON following the reply sub's conventions (credential refs by id/name, positions on a grid).
2. Read one live memory list (read-only) to fix node 12's format.
3. Validate.

**Done when.**

- File valid; n8n-mcp `validate_workflow` without errors; node names exactly as above.
- The memory entry format in node 12 matches the live format (evidence line in this plan).
- `jq empty workflows/*.json` and `docker compose config -q` pass.

**Not in this phase.** Calling the sub (Phase 4), importing it (Phase 5).

### Phase 4 — Wire the timer: start after `continua`, cancel on customer message

Status: PENDING
Role: n8n-workflows · Depends on: 2, 3 · Covers: AC 21, 26–28, 32 · Size: S
Spec: 5.1 rules 3–5, 9; 7 (`continua`)

**Goal.** After a `continua` reply with `aguarda_cliente = false`, the reply sub arms the timer and starts the
confirmation sub without waiting; any new customer text cancels it.

**Contract.**

- `workflows/chatbot-waha-divercity-reply.json`, after `7.1 Registrar msg do bot`:
  1. `7.1 Agendar confirmação?` — IF: `$('7.0 Rotear por status').first().json.output.aguarda_cliente === false`
     **and** `Number(CONFIG.CONFIRMACAO_MINUTOS) > 0` **and** `String(INSTRUCOES.MSG_CONFIRMACAO ?? '').trim() !== ''`. False → end.
  2. `7.1 Armar confirmação` — Redis set `confirmar:{chatId}` = `token` (the same normalized sent id used in
     `7.1 Registrar msg do bot`), TTL `Math.round(CONFIRMACAO_MINUTOS * 60) + 300` seconds.
  3. `7.1 Iniciar confirmação` — Execute Workflow 1.4, workflow id from Phase 3, `waitForSubWorkflow: false`, input
     `{ chatId, token, CONFIG, INSTRUCOES }`.
- `workflows/chatbot-waha-divercity-debounce.json`: new node `4.1 Cancelar confirmação` (Redis delete
  `confirmar:{chatId}`) right after `4.1 Guardar texto no buffer`, before `4.1 Marcar última mensagem`. Covers
  customer messages still in the debounce window (spec 5.1 rule 3).
- `resolvido` and handoff need no change: both delete `conv:{chatId}` and the sub checks it; the attendant sets
  `pausa:{chatId}` and the sub checks it.

**Steps.**

1. Add the nodes and connections; keep existing node positions.
2. Validate both files.

**Done when.**

- Connections: `7.1 Registrar msg do bot → 7.1 Agendar confirmação? → 7.1 Armar confirmação → 7.1 Iniciar confirmação`;
  `4.1 Guardar texto no buffer → 4.1 Cancelar confirmação → 4.1 Marcar última mensagem`.
- With `CONFIRMACAO_MINUTOS` absent (current live tables) the IF is false, so behavior is unchanged.
- `jq empty workflows/*.json`, `docker compose config -q`, n8n-mcp `validate_workflow` on both files pass.

**Not in this phase.** Deploy (Phase 5), Data Table values (Phase 6).

### Phase 5 — Deploy the workflow changes to the live n8n (feature still inert)

Status: PENDING
Role: n8n-workflows · Depends on: 2, 3, 4 · Covers: AC 26, 32 (makes them testable) · Size: S
Spec: 11 (structure deviation)

**Goal.** The live n8n runs the new agent parser, the new reply/debounce wiring and has the `Confirmação` sub. Because
the live tables have no `CONFIRMACAO_MINUTOS` yet, nothing new is sent.

**Contract (D1 = A, resolved).**

- Order: import `Confirmação` (new id) → update agent → update debounce → update reply. The main workflow and the
  filters are not touched.
- Before each update: live workflow equals `git show HEAD:<file>` on nodes/connections/settings; if not, stop and report.
- Show the owner the per-workflow change summary; update only after explicit approval in that session.
- The main workflow stays published; subs do not need publishing. Do not unpublish anything.

**Done when.**

- n8n-mcp `n8n_get_workflow` for the four workflows matches the repo files (nodes/connections).
- A normal test message from the allow-listed number still gets a normal reply and no `MSG_CONFIRMACAO` (feature inert).
- Evidence line with the approval and workflow ids.

**Not in this phase.** Data Table changes (Phase 6).

### Phase 6 — Live Data Tables: add columns, set values, new persona (feature on)

Status: PENDING
Role: n8n-workflows · Depends on: 1, 5 · Covers: AC 10, 18–21, 26, 28, 32 · Size: S
Spec: 1.1, 1.2, 5.1, 11 (Data Tables deviation)

**Goal.** The live tables carry the new columns and values and the new persona, which switches the feature on.

**Contract (D2 = A, resolved).**

- `addColumn` `CONFIRMACAO_MINUTOS` (number) on `chatbot_divercity_config` (`4B59btz6FrMV1Jad`);
  `addColumn` `MSG_CONFIRMACAO` (string) on `chatbot_divercity_instrucoes` (`m3KqByTDF4n2e6vq`).
- Read row `id` 1 of both tables; check `PERSONA_E_REGRAS` against the installer default at `HEAD` (before Phase 1);
  if it differs (hand edit), stop and show the diff — only the two persona sections may be replaced, with owner approval.
- `updateRows` filter `id = 1`: config → only `CONFIRMACAO_MINUTOS = 2`; instrucoes → only `MSG_CONFIRMACAO` and
  `PERSONA_E_REGRAS` (= the Phase 1 default). `dryRun` first, then apply after approval.
- Re-read both rows; every other column unchanged.

**Done when.**

- Both columns exist with the values above; persona equals the Phase 1 default; other columns untouched (evidence line).
- No workflow imported, published or unpublished in this phase.

**Not in this phase.** Changing `PAUSA_HORAS` or any other value.

### Phase 7 — Verification and report

Status: PENDING
Role: n8n-workflows · Depends on: 1–6 · Covers: all ACs in the table · Size: S
Spec: 5.1, 9

**Goal.** Prove the ACs live with the test number, then report.

**Contract.**

- Gate: `jq empty workflows/*.json`, `docker compose config -q`, n8n-mcp `validate_workflow` on the five chatbot
  workflows + `Confirmação`, secrets/PII grep (`project-core`) over `workflows/` and `docs/features/chat-bot-divercity/`.
- Live tests only with the owner present and the allow-listed test number, one message at a time. To speed up, the
  owner may set `CONFIRMACAO_MINUTOS` to `0.5` during the test; restore `2` at the end (and remind the owner about
  their test value of `PAUSA_HORAS`).
- Walk through: AC 18 (price answer has no question; check the execution's `aguarda_cliente = false`), 26, 27, 28, 19
  (then a new message gets a fresh greeting), 20 (pause + group notice; clear the test chat's `pausa:` key only with
  the owner's OK), 21, 30, 31, 32, 10; AC 29 by inspection of the sub's execution (no further send). Regression: 5, 6, 13, 14.
- Confirm the `Wait` in the detached sub resumes in queue mode (execution finishes after the interval).

**Done when.**

- Each AC above marked pass/fail with the execution id; failures reported, not patched in this phase.
- Report lists: divergences (the `PAUSA_HORAS` default `2` vs `12`, proposed `Deviation:` note), the owner's manual
  checklist (restore test values, set `MODO_TESTE` when going live), and anything left open.

**Not in this phase.** Fixes (a new phase is added if something fails), production rollout.
