# Plan — Bot de atendimento WhatsApp do Divercity Park ("Dry"): confirmação de encerramento e fatos do parque

Source spec: `docs/features/chat-bot-divercity/spec.md` · SHA-256 `68b7c9ad76309b785e88766934b376971254bb4c16bbdcdd0a4e19340a79da1a`
Product truth: the spec itself (no separate product doc).
Run phases with `/execute-phases docs/features/chat-bot-divercity/plan.md <phases>` — one or a few per
session. Phase status is updated in place in this file.

Scope of this plan: the previous plan (12 phases, all DONE, the bot is built and published in test mode) was deleted
from the working tree by the owner; it remains in `git show HEAD:docs/features/chat-bot-divercity/plan.md`. This plan
covers **only the delta** the spec lists under "Pendente de implementação" (section 11): (a) `FATOS_DO_PARQUE` with the
section 1.3 content, (b) the closing-confirmation question of section 5.1 in `PERSONA_E_REGRAS`, (c) acceptance
tests 18–25. Everything else is built and stays untouched.

## Status board

| Phase | Title                                                         | Role          | Depends on | Size | Status       |
| ----- | ------------------------------------------------------------- | ------------- | ---------- | ---- | ------------ |
| 1     | `FATOS_DO_PARQUE` default text (section 1.3)                  | n8n-workflows | none       | S    | DONE         |
| 2     | `PERSONA_E_REGRAS` default text: closing confirmation (5.1)   | n8n-workflows | none       | S    | DONE         |
| 3     | Apply the new texts to the live Data Table row                | n8n-workflows | 1, 2       | S    | PENDING      |
| 4     | Verification and report                                       | n8n-workflows | 1–3        | S    | PENDING      |

## Audit — 2026-10-13

| Check | Result |
| ----- | ------ |
| Spec vs plan state | Spec changed after the old plan: new section 1.3 (park facts), section 5.1 (closing confirmation), ACs 18–25, section 11 deviations. Old `plan.md` deleted in the working tree (owner action); spec section 11 still points to "o checklist da fase 12 do plan.md", which no longer exists, so the spec reference is stale (owner: update or drop). |
| Workflows in repo | `workflows/chatbot-waha-divercity{,-filters,-debounce,-agent,-reply,-install}.json`, all valid, none modified in the working tree. Ids: main `B1fRwNFx0bFdHYGI`, filters `AvWLP9xiCyvHhyn8`, debounce `9tJm4MQCI1leSWEm`, agent `T36H0vXQgPRsPGNe`, reply `msQXMvHkSmTdK8Ll`, install `95TKiRbbJEt5mYLg`. |
| Where the texts live | `INSTRUCOES` is a Data Table row (`chatbot_divercity_instrucoes`, six columns). The installer workflow inserts the default row **only if the table/row does not exist**, so editing the default text in the repo changes nothing in a running n8n. The live row is what the bot reads (D1 below). |
| Repo default today | `FATOS_DO_PARQUE` = five `[PREENCHER]` lines (address, entry rules, companion policy, discounts, parking). `PERSONA_E_REGRAS` = the conversational persona from the deviation note: `resolvido` only when the client closes explicitly; no confirmation question. Both match what section 11 calls "pending". |
| Code changes needed | **None.** `5.2 Montar contexto` already injects `PERSONA_E_REGRAS` + `FATOS_DO_PARQUE` + `AVISOS_DE_HOJE` + calendar; `7.0 Rotear por status` already routes `continua` / `resolvido` (7.2: send farewell, delete `conv:{chatId}`, no pause, no group notice) / `humano` (7.3: send, pause, delete `conv`, notify group). `6.1 Interpretar resposta` accepts the three statuses. Section 5.1 is therefore a prompt change only. |
| New tools / deps | None. No new `.env` key, no new credential, no image or package change. |
| Live n8n | Not reachable now (`ECONNREFUSED 127.0.0.1:5678`: the stack is down in this session), so the live row could not be read. Phase 3 must read it first. |
| Checks that exist | `jq empty workflows/*.json`, `docker compose config -q`, the secrets grep from `project-core`. No `package.json`, no tests. |
| Images referenced by the spec | `docs/features/chat-bot-divercity/images/*.png` (untracked). Binding only for address and attraction list (spec 1.3); not copied into any file. |

## Owner decisions

### D1 — How the new texts reach the live `INSTRUCOES` row — RESOLVED 2026-10-13: option A

Owner chose the recommended option: the executor reads the live row, shows the diff and writes only `PERSONA_E_REGRAS` and `FATOS_DO_PARQUE` after the owner approves the diff in that session. Options considered:

Blocked: Phase 3 (now unblocked) · Options: A (recommended) the executor reads the live row, shows a diff against the new defaults, and only after the owner approves writes **only** `PERSONA_E_REGRAS` and `FATOS_DO_PARQUE` through the Data Table API (other columns, including `AVISOS_DE_HOJE` and `FERIADOS`, untouched); B the owner pastes the two texts in the n8n **Data tables** tab by hand, the executor only supplies them; C re-run the installer after deleting the row (not allowed, would wipe edits) · Why: the live row may contain hand edits by the owner or the owner's spouse (`CLAUDE.md`: manual changes win), and writing it is a live change in a running n8n.

### D2 — OD1 of the spec: companion rules and discounts from the site image

Blocks: nothing (a default is defined) · Options: A (recommended, the spec's current rule) bot does not talk about companions or discounts and hands off, B owner confirms the reading in the spec's OD1 and it goes into `FATOS_DO_PARQUE` · Why: discounts are value rules and the image text is small. Phase 1 implements A; if the owner confirms B before Phase 1 runs, the executor adds only the confirmed lines.

### D3 — OD2 of the spec: bar items

Blocks: nothing · Options: A (recommended) only "chopp e alguns petiscos" and "cardápio e preços só no local", B also soft drinks and coffee · Why: the owner stated A; the image hints at B. Phase 1 implements A.

## Global constraints (every phase)

- Git is read-only; no commits unless run by `/execute-phases`. No dependency, image tag or n8n version change; no tests written (`CLAUDE.md`).
- Only the `chatbot-waha-divercity-install.json` default values change in the repo (Phases 1–2). No other workflow JSON is edited. Node names, ids and positions in that file stay as they are.
- Content language: Portuguese (pt-BR) for the texts in the Data Table defaults, per the owner's exception recorded in the spec (section 11) and memory; this plan's prose stays English.
- Spec rule 0.5: the bot never invents price, hours or rules. Nothing in the new texts may state a price, hour, discount or companion rule. Prices and hours come only from `consultar_passaportes` / `consultar_horarios`; the site image's prices and hours are ignored.
- Secrets/PII: no tokens, no phone numbers, no group ids in any file. The park address in spec 1.3 is public business data and is allowed in `FATOS_DO_PARQUE`; the phone and hours shown in the Google image are **not** copied.
- Do not edit `spec.md`. Divergences found are reported with a proposed `Deviation:` note, not applied.
- The live row (Phase 3) is never overwritten without the owner's explicit approval of the diff (D1).
- No live WhatsApp sends except to the owner's allow-listed test number, one message at a time, only in Phase 4 and only if the owner is present and says so.

## Acceptance-criteria coverage

| AC (spec 9) | Phases |
| ----------- | ------ |
| 1–9, 11–17 (already built and verified in the old plan; behavior unchanged) | 4 (smoke only: 5, 13 and the regression of 6) |
| 10 "era só isso, obrigado" → `resolvido`, no pause, new conversation later | 2, 3, 4 |
| 18 price/hour answer ends with the confirmation question, `continua`, never `resolvido` | 2, 3, 4 |
| 19 "sim, resolvido" → `resolvido`, `conv` deleted, no pause, no group notice, new conversation | 2, 3, 4 |
| 20 "não" / "não resolveu" → `humano`, pause, group notice | 2, 3, 4 |
| 21 other question after the confirmation → answers and asks again, no handoff | 2, 3, 4 |
| 22 "O que tem no parque?" → only listed attractions | 1, 3, 4 |
| 23 bar question → bar for parents, chopp and petiscos, menu and prices only on site, no handoff | 1, 3, 4 |
| 24 "alugar o salão pra uma festa" → confirms it can be rented, `humano`, no party price | 1, 2, 3, 4 |
| 25 "Onde fica o parque?" → indoor playground in Shopping Cidade Maringá + address | 1, 3, 4 |

## Phases

### Phase 1 — `FATOS_DO_PARQUE` default text (section 1.3)

Status: DONE
Evidence: jq extraction diffed against the contract text → exact match, no `[PREENCHER]`; `jq empty workflows/*.json` OK; `docker compose config -q` OK; secrets grep on the installer → no hits; `git diff --stat -- workflows/` → only the installer, 1+/1- (the `FATOS_DO_PARQUE` line); code-reviewer APPROVED (AC 22–25 text present). Non-blocking: the old "Regras de entrada" and "Estacionamento" placeholders are dropped per the contract, so the bot has no facts for those and hands off.
Role: n8n-workflows · Depends on: none · Covers: AC 22, 23, 24, 25 · Size: S
Spec: 1.2, 1.3, 8, OD1, OD2

**Goal.** Replace the five `[PREENCHER]` lines of the `FATOS_DO_PARQUE` default in the installer with the section 1.3 facts, so a fresh install (and the text handed to the owner in Phase 3) is correct.

**Contract.**

- File: `workflows/chatbot-waha-divercity-install.json`, node `Inserir instruções padrão`, column `FATOS_DO_PARQUE` only (the value is a string with `\n` newlines; keep the JSON escaped).
- Exact new value (D2 = A, D3 = A):

```
O QUE É: playground indoor, dentro do Shopping Cidade Maringá.
ENDEREÇO: Av. Tuiuti, 710 - Gleba Patrimônio, Maringá - PR, 87043-720.
ATRAÇÕES (cite só estas): Arena de Camas Elásticas, Guerreiro Ninja, Parede de Escalada, Desafio Radical, Pula-Pula, Salão de Festas, Bar e Petiscaria. O parque tem mais de 10 atrações, mas você só cita as listadas aqui; não invente outras.
BAR: há um bar para os pais que esperam os filhos brincarem, com chopp e alguns petiscos. O cardápio e os preços do bar são só no local: se perguntarem, diga isso, não cite itens nem valores e NÃO encaminhe para a atendente por causa disso.
SALÃO DE FESTAS: o salão pode ser alugado para festas. Qualquer pedido de festa vai para a atendente (status "humano"); não informe preço nem detalhe o pacote.
ACOMPANHANTE E DESCONTOS: não informe regras de acompanhante nem de desconto; encaminhe para a atendente (status "humano").
PREÇOS E HORÁRIOS: só valem os das ferramentas consultar_passaportes e consultar_horarios. Ignore qualquer outro valor ou horário que você conheça.
```

- No phone number, no opening hours, no prices in the text.

**Steps.**

1. Edit the single JSON string value; keep all other columns and nodes byte-identical.
2. Validate JSON.

**Done when.**

- `jq -r '.nodes[]|select(.name=="Inserir instruções padrão")|.parameters.columns.value.FATOS_DO_PARQUE' workflows/chatbot-waha-divercity-install.json` prints the text above and no `[PREENCHER]`.
- `git diff --stat` shows only `workflows/chatbot-waha-divercity-install.json`, and the diff touches only that value.
- `jq empty workflows/*.json` passes.

**Not in this phase.** Persona changes (Phase 2), the live row (Phase 3), companion/discount text (waits on D2 = B).

### Phase 2 — `PERSONA_E_REGRAS` default text: closing confirmation (section 5.1)

Status: DONE
Evidence: extracted `PERSONA_E_REGRAS` diffed against the precomputed contract text → exact match (only rule 4 append, new `ENCERRAMENTO` section, rewritten `"continua"`/`"resolvido"` bullets); each status bullet appears once; JSON-only output rule intact; `jq empty workflows/*.json` OK; `docker compose config -q` OK; secrets grep → no hits; `git diff --stat -- workflows/` → only the installer, 1+/1-; code-reviewer APPROVED (AC 10, 18–21, 24). Non-blocking: "O QUE VOCÊ FAZ" lists rule 4 as the only handoff case and does not mention the ENCERRAMENTO "NÃO resolveu" → humano exception.
Role: n8n-workflows · Depends on: none · Covers: AC 10, 18, 19, 20, 21, 24 · Size: S
Spec: 5.1, 6 (status values), 11 (item b, c)

**Goal.** Teach the persona to ask whether the doubt was resolved and to map the answer to `continua` / `resolvido` / `humano`, in the installer default.

**Contract.**

- File and node as in Phase 1, column `PERSONA_E_REGRAS` only. Keep every existing section (COMO CONVERSAR, O QUE VOCÊ FAZ, REGRAS 1–5, PASSAPORTE, HORÁRIO, output format) and change only:
  1. Under `STATUS E FORMATO DE SAÍDA`, replace the `"continua"` and `"resolvido"` bullets with:

```
- "continua": você respondeu ou fez uma pergunta e a conversa segue. Vale para cumprimentos, para respostas de preço ou horário e para a pergunta de confirmação de encerramento.
- "resolvido": somente quando o cliente confirmar que a dúvida foi resolvida (ver ENCERRAMENTO) ou encerrar por conta própria de forma explícita. "resposta" é uma despedida curta, em uma linha ("Qualquer dúvida é só chamar!"). Nunca use "resolvido" na mesma resposta em que informa preço ou horário.
```

  2. Add a new section `ENCERRAMENTO` right before `STATUS E FORMATO DE SAÍDA`:

```
ENCERRAMENTO
- Quando você já respondeu o que o cliente perguntou e não há pergunta pendente, termine a resposta perguntando se a dúvida foi resolvida (ex.: "Isso resolve a sua dúvida?"). Use status "continua".
- Se o cliente confirmar ("sim", "era só isso", "obrigado" em resposta à pergunta): status "resolvido" com a despedida.
- Se o cliente disser que NÃO resolveu: status "humano".
- Se o cliente responder com outra pergunta em vez de sim ou não: responda normalmente, volte a perguntar no fim e use "continua".
- Se o cliente encerrar por conta própria antes de ser perguntado ("era só isso, obrigado"): isso já é a confirmação; use "resolvido" sem perguntar de novo.
```

  3. In rule 4, keep the list and append: `Se o cliente perguntar se o salão pode ser alugado, confirme que pode e use "humano".`
- No other text changes. No new `INSTRUCOES` column (spec 11, item c).

**Steps.**

1. Edit the single string value in the installer default.
2. Re-read the final value once to check the three statuses are still described exactly once each and the JSON-only output rule is intact.

**Done when.**

- The extracted `PERSONA_E_REGRAS` contains the `ENCERRAMENTO` section, the rewritten `"continua"` / `"resolvido"` bullets, and still contains rules 1–5 and the JSON-only output instruction.
- `git diff` touches only `workflows/chatbot-waha-divercity-install.json`, only that value.
- `jq empty workflows/*.json` passes.

**Not in this phase.** Facts text (Phase 1), live row (Phase 3), any code, router or Structured-output change.

### Phase 3 — Apply the new texts to the live Data Table row

Status: PENDING
Role: n8n-workflows · Depends on: 1, 2 · Covers: AC 10, 18–25 (makes them testable) · Size: S
Spec: 1.2, 11 (Data Tables deviation)

**Goal.** Put the Phase 1 and Phase 2 texts into the row the bot actually reads, without losing hand edits.

**Contract.**

- Prerequisite: n8n is running and reachable (the owner starts the stack; the executor does not start or stop containers).
- Table `chatbot_divercity_instrucoes`, one row. Columns written: `PERSONA_E_REGRAS`, `FATOS_DO_PARQUE`. Columns never written: `AVISOS_DE_HOJE`, `FERIADOS`, `MSG_HANDOFF_CLIENTE`, `MSG_MIDIA`.
- Do not run the installer, do not import any workflow, do not delete rows or tables.

**Steps.**

1. Read the live row and compare both columns with the repo defaults before this change (`git show HEAD:workflows/chatbot-waha-divercity-install.json`).
2. If the live text differs from the old defaults (hand edits), list the differences to the owner and **stop**; merging is the owner's call.
3. Otherwise show the diff to the owner and wait for approval (D1 = A). After approval, update only the two columns (use `dryRun` first).
4. Read the row again and confirm both columns equal the Phase 1 / Phase 2 values and the other four columns are unchanged.

**Done when.**

- A re-read of the live row shows the new `PERSONA_E_REGRAS` and `FATOS_DO_PARQUE`, and the other columns equal their values from step 1.
- No workflow was imported, published or unpublished.

**Not in this phase.** Live test messages (Phase 4).

### Phase 4 — Verification and report

Status: PENDING
Role: n8n-workflows · Depends on: 1–3 · Covers: AC 10, 18–25, smoke of 5, 6, 13 · Size: S
Spec: 9, 11

**Goal.** Run the deterministic gate, walk the acceptance criteria that changed, and report with the owner's manual checklist and the spec deviation proposals.

**Contract.**

- Gate: `jq empty workflows/*.json`; `docker compose config -q`; the secrets/PII grep from `project-core` over `workflows/`, `docs/` and `scripts/` (no token, no phone numbers, no group ids; the public park address is expected and allowed).
- Static checks on the Phase 1–2 values: no `[PREENCHER]` left in `FATOS_DO_PARQUE`; `ENCERRAMENTO` present; no digit sequences that look like prices (`R$`) or opening hours in `FATOS_DO_PARQUE`.
- Live walkthrough (owner present, owner's allow-listed test number, `MODO_TESTE = true`, one message at a time, no loops; `GRUPO_ATENDIMENTO_ID` empty or the owner's test group). Expected results:

| # | Send | Expected |
| - | ---- | -------- |
| 18 | "Quanto é a entrada na terça?" | Price from the tool in `weekdayPrice`; the reply ends asking if it resolved; chat stays active (`continua`). |
| 19 | "sim, resolvido" | Farewell, `conv:` deleted, no pause key, no group notice; next message gets a fresh introduction. |
| 20 | repeat 18, then "não resolveu" | Handoff message, `pausa:` set, group notice (or log if no group). |
| 21 | repeat 18, then "e o horário de sábado?" | Hours answered, asked again at the end, no handoff. |
| 22 | "O que tem no parque?" | Only the seven listed attractions; no price or hours. |
| 23 | "Tem bar? Qual o cardápio e os preços?" | Bar for parents with chopp and petiscos; menu and prices only on site; no handoff. |
| 24 | "Posso alugar o salão pra uma festa?" | Confirms the salon can be rented; `humano`; no party price. |
| 25 | "Onde fica o parque?" | Indoor playground in Shopping Cidade Maringá plus the address. |
| 10 | "era só isso, obrigado" as the first message of a conversation | `resolvido` without the confirmation question. |
| 5/6/13 smoke | party; one audio; a bot reply sent via API | `humano`; `MSG_MIDIA` + one handoff; bot reply does not pause. |

- Clear `pausa:` and `conv:` keys only for the test chat between cases, and only with the owner's go-ahead.

**Steps.**

1. Run the gate and the static checks.
2. Run the live table with the owner, recording each result (pass / fail / not run).
3. Report: results, the list of changed files, the Data Table state, and the owner's manual checklist (below).
4. Propose, without applying, these updates to `spec.md`: (i) replace the "Pendente de implementação" paragraph by a `Deviation:` note saying the texts are live and, if the owner chose B for OD1/OD2, the final content; (ii) drop or fix the reference to "checklist da fase 12 do plan.md"; (iii) note that Anexo A is the original draft and the live `PERSONA_E_REGRAS` is the Data Table value; (iv) AC numbering in section 9 is out of order (18–25 sit before 11).

**Done when.**

- Gate and static checks pass.
- Every row of the table above has a recorded result; any failure is reported with the model's reply and the status it returned, and the persona text is **not** tweaked blindly to make it pass.
- The report lists spec deviation proposals and the open owner decisions.

**Owner's manual checklist.**

- Read the final `FATOS_DO_PARQUE` and `PERSONA_E_REGRAS` in the Data tables tab once, as the spouse would.
- Confirm OD1 (companion rules and discounts) and OD2 (bar items); until then the bot hands those off.
- Confirm that no hand edit of the live row was lost (Phase 3, step 2).
- Check that `MODO_TESTE` and `ALLOWLIST` are back to the intended values before going live.

**Not in this phase.** Any new feature, v2 items (audio transcription, party price tool, reactivation command), publishing for production.
