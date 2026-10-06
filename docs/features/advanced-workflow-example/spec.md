# Advanced workflow example

Status: IMPLEMENTED · Created: 2026-10-06 · Updated: 2026-10-06 (single
workflow, WAHA community nodes, setup brings it up)

## 1. Goal

A reference n8n workflow: a WhatsApp chatbot on WAHA for a **hypothetical car
rental company** (fictional, invented for this test). It shows the repo's
conventions end to end: one central config node, one readable workflow split
into sections, direct chats only, conversation memory, human-like typing
delays and an LLM (`gpt-4o-mini`) driven by editable business rules. It is a
study example, not a production bot; all company data is invented. A fresh
clone + `scripts/setup.sh` brings it up running.

## 2. Ground rules

- R1. **Direct chats only.** Messages from groups are ignored: no reply, no
  side effect, no memory write. Only 1:1 chats are answered. Other non-direct
  chat types (broadcast/status, newsletter/channel) are ignored the same way.
- R2. **One config node.** A single Edit Fields (Set) node, "Load workflow
  config", right after the ingress, is the only place with tunable values
  (the workflow's "env"). Every other node reads settings from it and never
  hardcodes them. It holds **non-secret** values only: secrets and connection
  data (WAHA URL + API key, OpenAI key, Postgres) stay in n8n credentials,
  referenced by name (`CLAUDE.md`). A short "Keys" sticky note says this next
  to the node.
- R3. **Business rules are an input field.** The company's rules, tone and
  facts live in one config field (`businessRules`, multi-line text) injected as
  the LLM system prompt. Changing the bot's behaviour means editing only that
  field.
- R4. **Conversation memory.** The bot keeps per-chat history so the
  conversation flows naturally across messages. Memory is keyed by the
  gateway `chatId` and survives n8n restarts and queue-mode workers (see A3).
  Only the last `memoryWindow` messages are sent to the model.
- R5. **Human-like replies.** Before each reply the bot marks the chat as
  seen, shows "typing…", waits a delay proportional to the reply length
  (clamped, with jitter), stops typing, then sends. No reply is ever sent
  instantly.
- R6. **Model.** OpenAI `gpt-4o-mini` (model name is a config field,
  `llmModel`).
- R7. **One workflow, organized by sections.** The whole bot is a single
  workflow (no sub-workflows): it is a study example and one canvas is easier
  to follow. Sections are sticky-note headers (Receive · Guards · Reply ·
  Send · Outcome), left-to-right flow, English verb-first node names, no
  crossing connections. Guards use Filter nodes (drop silently) instead of
  IF + "return ignored" pairs.
- R7a. **WAHA community nodes.** Every gateway interaction uses the installed
  `@devlikeapro/n8n-nodes-waha` package: the **WAHA Trigger** for inbound
  events and the **WAHA** node (resource Chatting: Send Seen, Start Typing,
  Stop Typing, Send Text) for outbound calls. No HTTP Request or Webhook
  nodes talk to WAHA.
- R8. **Gateway safety** (`whatsapp-gateway` skill): normalize at the edge,
  dedupe on `messageId`, ignore `fromMe`, per-chat rate limit, test sends
  gated by an allow-list, failed sends go to the error workflow and are never
  blindly retried, no real numbers or PII in the repo. Inbound is **not**
  authenticated by a secret (see OD2).
- R9. The bot never initiates a conversation; it only answers inbound direct
  messages (no opt-in problem, no bulk sends).

## 3. Data model

All new.

**Config node fields** ("Load workflow config", non-secret):

| Field | Type | Default (example) | Meaning |
| --- | --- | --- | --- |
| `llmModel` | string | `gpt-4o-mini` | OpenAI chat model |
| `llmTemperature` | number | `0.4` | Sampling temperature |
| `llmMaxOutputTokens` | number | `300` | Cap on reply length |
| `memoryWindow` | number | `20` | Messages of history sent to the model |
| `typingCharsPerSecond` | number | `12` | Simulated typing speed |
| `typingMinSeconds` | number | `2` | Minimum typing time |
| `typingMaxSeconds` | number | `12` | Maximum typing time |
| `typingJitterSeconds` | number | `1` | Random ± added to the delay |
| `seenDelaySeconds` | number | `1` | Pause between "seen" and "typing" |
| `perChatMinIntervalSeconds` | number | `3` | Rate limit: minimum gap between bot replies in one chat |
| `restrictToAllowList` | boolean | `true` | Dev gate: answer only chats in `allowedChatIds` |
| `allowedChatIds` | string (comma list) | `<TEST_CHAT_ID>` | Allow-listed test chat ids (placeholder in the repo; `scripts/setup.sh` replaces it with `TEST_CHAT_IDS` from `.env` on import) |
| `unsupportedTypeReply` | string | see §5 | Fixed reply for non-text messages |
| `failureReply` | string | see §5 | Fixed reply when the LLM fails (see F4) |
| `businessRules` | string (multi-line) | see below | Company rules/system prompt (R3) |

**Example `businessRules` content (fictional company "DriveEasy Rentals",
invented):**

- Assistant name: "Duda", virtual assistant of DriveEasy Rentals. Friendly,
  concise, 1–3 short sentences per message, replies in the customer's
  language (default Brazilian Portuguese), at most one emoji per message.
- Branches (fictional): Downtown (open Mon–Sat 08:00–20:00), Airport (open
  daily 06:00–23:00). Closed on public holidays at Downtown.
- Fleet and daily rates (BRL): Economy hatch R$ 119, Compact sedan R$ 149,
  SUV R$ 229, Minivan 7 seats R$ 289, Pickup R$ 259.
- Requirements: driver's license held 2+ years, minimum age 21 (25 for SUV,
  Minivan, Pickup), credit card in the driver's name for the deposit.
- Deposit: R$ 800 (Economy/Compact), R$ 1,500 (others), released within 7 days
  after return.
- Mileage: 200 km/day included; R$ 0.80 per extra km. Fuel: return with the
  same level or pay refuel + R$ 40 fee.
- Extras: child seat R$ 25/day, extra driver R$ 30/day, full insurance R$ 45/day.
- Cancellation: free up to 24 h before pickup; after that, 1 day's rate.
- Booking: the bot **cannot** book or take payment; for a booking it collects
  pickup city, dates, car category and name, then says a human agent will
  confirm shortly.
- Out of scope for the bot: claims, accidents, legal or price negotiation →
  hand over to a human agent (phone line fictional: "see our website").
- Never invent facts not listed here; if unsure, say a human agent will help.

**Persistent stores** (new, in the existing Postgres/n8n DB):

- Conversation history per `chatId` (Postgres Chat Memory, session key =
  `chatId`; table created by the node).
- Processed message ids (dedupe): `messageId` unique, `processedAt`.
- Last reply timestamp per `chatId` (rate limit).

The two tables come from `scripts/sql/chatbot-car-rental.sql`, applied by
`scripts/setup.sh`.

**Normalized message shape** (output of the normalize step, per
`whatsapp-gateway`): `messageId, session, chatId, senderId, fromMe, type,
text, timestamp, isGroup, isDirect`. Replies use the event's `session`.

## 4. Flows

Structure (R7, R7a): one file, `workflows/chatbot-waha-car-rental.json`.

1. **Receive**: WAHA Trigger (output `message.any` only; it answers WAHA
   immediately) → Load workflow config → Normalize WAHA message (Code).
   Protocol/system messages end the run.
2. **Guards** (Filter nodes, each drops the item silently): direct chat, not
   `fromMe`, on the allow-list → record `messageId` (dedupe) → claim the
   per-chat reply slot (rate limit).
3. **Reply**: text → AI Agent (`gpt-4o-mini`, system prompt =
   `businessRules`, Postgres Chat Memory); other types → `unsupportedTypeReply`;
   LLM error or empty reply → `failureReply`. All three produce
   `{ text, replyKind }`.
4. **Send** (WAHA nodes): compute delay → Send Seen → wait → Start Typing →
   wait → Stop Typing → Send Text.
5. **Outcome**: stamp last reply time; an LLM failure or a failed send fails
   the execution once (error workflow).

**F1 — Happy path (end user on WhatsApp, text, direct chat)**
1. User sends a text to the bot's number; WAHA posts to n8n.
2. The WAHA Trigger answers WAHA immediately; the payload is normalized.
3. Guards pass (not `fromMe`, direct chat, new `messageId`, allowed, rate
   limit OK); the `messageId` is recorded as processed.
4. The agent loads the last `memoryWindow` messages for the `chatId`, calls
   the LLM, stores the exchange in memory.
5. Send segment: mark seen → wait `seenDelaySeconds` → start typing → wait
   `clamp(len(reply) / typingCharsPerSecond, min, max) ± jitter` → stop typing
   → send the reply.

**F2 — Ignored events (no reply, no memory write, no error):** group chat,
broadcast/status/channel chat, `fromMe`, duplicate `messageId`, non-message
events, chat not on the allow-list (while `restrictToAllowList` is true).
Execution ends silently at the guard that matched.

**F3 — Unsupported type** (image, audio, video, sticker, document, location,
contact, reaction, poll, etc. in a direct chat): no LLM call, no memory write;
send `unsupportedTypeReply` once through the same typing flow, subject to the
rate limit.

**F4 — LLM failure/timeout:** the execution is routed to the error workflow
(owner notified, OD1) and the user receives `failureReply` once (the fixed
text is sent via the Send segment; no LLM retry loop).

**F5 — Rate limited:** a second inbound message in the same chat within
`perChatMinIntervalSeconds` of the last bot reply is dropped silently (not
queued).

**F6 — Gateway send failure:** recorded and routed to the error workflow; the
send is not retried (R8).

**F7 — Fresh setup:** on a new clone, `scripts/setup.sh` creates `.env`,
starts the stack, creates the tables and the `Postgres account`,
`WAHA account` and `OpenAI account` credentials from `.env` (only when
missing), imports the workflows not yet in n8n (allow-list from
`TEST_CHAT_IDS`) and publishes the chatbot. Owner steps: create the n8n owner
account, pair the WAHA session, fill `OPENAI_API_KEY` and `TEST_CHAT_IDS`,
rerun the script.

## 5. Conversation surfaces

Trigger: inbound WAHA `message.any` events on the WAHA Trigger's production
URL `/webhook/<webhookId>/waha`. The `webhookId` is fixed in the workflow
JSON and `WHATSAPP_HOOK_URL` in `docker-compose.yml` points to it (A5).

- **Normal reply:** LLM text, produced from `businessRules` (language: the
  customer's, default Brazilian Portuguese).
- **`unsupportedTypeReply` (pt-BR):** "Por enquanto eu só consigo ler
  mensagens de texto. Pode me escrever o que precisa? 🙂"
- **`failureReply` (pt-BR):** "Tive um probleminha aqui. Pode repetir sua
  mensagem em instantes?"
- Groups, broadcasts, `fromMe`, duplicates: no reply.

Copy language: Brazilian Portuguese for the two fixed replies and the default
LLM language; everything else in the repo is English.

## 6. Acceptance criteria

- AC1. Given a text message in a direct chat from an allowed chat, when it
  arrives, then exactly one reply is sent to that chat, generated by
  `gpt-4o-mini` using `businessRules` as system prompt.
- AC2. Given a message in a group chat (id of a group), when it arrives, then
  no WAHA send/typing call and no LLM call is made, and no memory or dedupe
  row is written.
- AC3. Given a broadcast/status/channel chat or a `fromMe` message, when it
  arrives, then no reply is sent and no LLM call is made.
- AC4. Given the same `messageId` delivered twice, when both arrive, then only
  one reply is sent.
- AC5. Given a conversation of several messages in one chat, when the user
  asks about something said earlier (e.g. the chosen car category), then the
  reply uses that earlier context; and after an n8n restart the context is
  still available.
- AC6. Given two different chats, when each talks to the bot, then neither
  reply uses the other's history.
- AC7. Given a reply, when it is sent, then WAHA receives, in order: seen,
  start typing, stop typing, send text, with the typing duration equal to the
  clamped length-based delay (± jitter) between the start and stop calls.
- AC8. Given the config node, when `typingCharsPerSecond`, `typingMinSeconds`,
  `typingMaxSeconds`, `memoryWindow`, `llmModel` or `businessRules` is edited
  there, then the next execution uses the new value without editing any other
  node.
- AC9. Given the workflow JSON, when searched, then the only occurrences of
  the config values (model name, delays, business rules) are in the config
  node, the WAHA URL lives only in the `WAHA account` credential, and no
  secret, token or real phone number appears anywhere in the repo.
- AC10. Given a business-rules question covered by the example data (e.g.
  "Qual o valor da diária do SUV?"), when asked, then the reply states the
  invented figure (R$ 229); and given a question not covered, the bot says a
  human agent will help instead of inventing an answer.
- AC11. Given a booking request, when the user asks to book, then the bot
  collects pickup city, dates, category and name, does not claim the booking is
  confirmed, and says a human agent will confirm.
- AC12. Given an image, audio or other non-text message in a direct chat, when
  it arrives, then no LLM call occurs and `unsupportedTypeReply` is sent once
  with the typing flow.
- AC13. Given `restrictToAllowList` is true and the chat is not in
  `allowedChatIds`, when a message arrives, then nothing is sent.
- AC14. Given two messages in one chat within `perChatMinIntervalSeconds` of
  the bot's last reply, when the second arrives, then it gets no reply.
- AC15. Given the LLM call fails, when the execution runs, then the error
  workflow is triggered once and the user receives `failureReply` once, with no
  retry.
- AC16. Given the repo, when inspected, then the bot is one file
  (`workflows/chatbot-waha-car-rental.json`) with sticky-note section
  headers, no sub-workflows, the shared error workflow set in its settings,
  and every WAHA call (inbound and outbound) made by
  `@devlikeapro/n8n-nodes-waha` nodes (no HTTP Request/Webhook node for WAHA).
- AC17. Given a fresh clone, when `scripts/setup.sh` runs, the owner account
  exists and `.env` has `OPENAI_API_KEY` and `TEST_CHAT_IDS`, then the
  chatbot is published and answers a text from an allowed chat without any
  manual step in the n8n editor. Rerunning the script never overwrites
  existing credentials or workflows.

## 9. Assumptions

- A1. "gpt4 o mini" means OpenAI `gpt-4o-mini`.
- A2. The "env" edit field holds non-secret config only; keys/secrets are n8n
  credentials by name (repo rule), so "keys" in the request means
  configuration keys.
- A3. The stack runs n8n in queue mode with workers (`docker-compose.yml`), so
  in-process memory/static data is not reliable; history uses Postgres Chat
  Memory and dedupe/rate-limit state uses a database store (n8n Data Table or
  Postgres), not workflow static data. The exact node is decided in the plan
  after checking docs.
- A4. Typing delay is proportional to the reply length (clamped + jitter)
  rather than a fixed time.
- A5. The WAHA Trigger fixes its own path (`<webhookId>/waha`), so the
  `whatsapp/<gateway>/incoming` convention in the skill is not applied;
  `WHATSAPP_HOOK_URL` in compose follows the trigger.
- A6. Replies are a single message (no splitting into several bubbles).
- A7. Bot copy is Brazilian Portuguese; the business rules are written in
  English and instruct the model to reply in the customer's language.
- A8. Memory and example data are fictional; no real company is modelled.
- A9. Unsupported types get one fixed reply instead of silence, so users know
  why nothing happened.

## 10. Decisions

- OD1 — Error notifications: n8n execution log only, via
  `system-error-handler` (no WhatsApp sends from error paths).
- OD2 — Inbound authentication: **none** (owner, 2026-10-06). The WAHA
  Trigger only reads the request body, so it cannot check a secret header or
  HMAC. Inbound safety relies on n8n being bound to `127.0.0.1` plus the
  Docker network, and on the UUID in the trigger URL. Deviation from the
  `whatsapp-gateway` skill ("authenticate inbound"), accepted for this study
  setup; a public deployment needs a reverse proxy that checks a secret, or
  a Webhook node with Header Auth in front.
- OD3 — Keep `message.any` as the only subscribed event; `fromMe` is
  filtered in the workflow.

## Ideas not included

- Debounce/merge several rapid user messages into one LLM turn.
- Per-chat concurrency lock so two executions of one chat never overlap.
- Audio transcription / image understanding for non-text messages.
- "Handover to human" mode that pauses the bot for a chat.
- Splitting long replies into several bubbles with their own typing delays.
- Business-hours awareness (answering differently outside branch hours).
