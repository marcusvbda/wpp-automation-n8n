# Advanced workflow example

Status: DRAFT · Created: 2026-10-06

## 1. Goal

A reference n8n workflow: a WhatsApp chatbot on WAHA for a **hypothetical car
rental company** (fictional, invented for this test). It shows the repo's
conventions end to end: one central config node, a segmented structure, direct
chats only, conversation memory, human-like typing delays and an LLM
(`gpt-4o-mini`) driven by editable business rules. It is a test/example, not a
production bot; all company data is invented.

## 2. Ground rules

- R1. **Direct chats only.** Messages from groups are ignored: no reply, no
  side effect, no memory write. Only 1:1 chats are answered. Other non-direct
  chat types (broadcast/status, newsletter/channel) are ignored the same way.
- R2. **One config node.** A single Edit Fields (Set) node, "Load workflow
  config", right after the ingress, is the only place with tunable values
  (the workflow's "env"). Every other node reads settings from it and never
  hardcodes them. It holds **non-secret** values only: secrets (WAHA API key,
  OpenAI key, webhook secret) stay in n8n credentials, referenced by name
  (`CLAUDE.md`). A short "Keys" sticky note says this next to the node.
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
- R7. **Segmented and organized.** The solution is split into an orchestrator
  workflow plus sub-workflows, one per responsibility, with sticky-note
  section headers in each canvas, left-to-right flow, English verb-first node
  names and no crossing connections.
- R8. **Gateway safety** (`whatsapp-gateway` skill): inbound authenticated
  (OD2), normalize at the edge, dedupe on `messageId`, ignore `fromMe`,
  per-chat rate limit, test sends gated by an allow-list, failed sends go to
  the error workflow and are never blindly retried, no real numbers or PII in
  the repo.
- R9. The bot never initiates a conversation; it only answers inbound direct
  messages (no opt-in problem, no bulk sends).

## 3. Data model

All new.

**Config node fields** ("Load workflow config", non-secret):

| Field | Type | Default (example) | Meaning |
| --- | --- | --- | --- |
| `wahaBaseUrl` | string | `http://waha:3000` | WAHA API base URL inside the compose network |
| `wahaSession` | string | `default` | WAHA session name |
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
| `allowedChatIds` | string (comma list) | `<TEST_CHAT_ID>` | Allow-listed test chat ids (placeholder; real values from `.env`/owner, never committed) |
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

**Normalized message shape** (output of the ingress, per `whatsapp-gateway`):
`messageId, chatId, senderId, fromMe, type, text, timestamp, isGroup,
isDirect`.

## 4. Flows

Structure (R7). Names are proposals; files follow `<area>-<purpose>.json`
(`chatbot-waha-car-rental` + one sub-workflow per segment):

1. **Orchestrator** (`chatbot-waha-car-rental`): Webhook → Load workflow
   config → Ingress → Guards → Reply → Send. Respond to the webhook
   immediately, then do the slow work.
2. **Ingress sub-workflow**: authenticate (OD2), keep only `message` events,
   normalize WAHA payload to the shape in §3.
3. **Guards sub-workflow**: ignore `fromMe`, ignore non-direct chats (R1),
   dedupe, allow-list gate, per-chat rate limit.
4. **Reply sub-workflow**: AI Agent (`gpt-4o-mini`, system prompt =
   `businessRules`, Postgres Chat Memory).
5. **Send sub-workflow**: seen → typing → delay → stop typing → send text.

**F1 — Happy path (end user on WhatsApp, text, direct chat)**
1. User sends a text to the bot's number; WAHA posts to n8n.
2. n8n answers the webhook immediately; the payload is authenticated and
   normalized.
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

**F7 — Authentication failure:** rejected in the first nodes with no further
processing (per OD2).

## 5. Conversation surfaces

Trigger: inbound WAHA `message` events on the production webhook
`/webhook/waha` (the path already set in `docker-compose.yml`
`WHATSAPP_HOOK_URL`; see A5).

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
  the config values (model name, delays, session name, base URL, business
  rules) are in the config node, and no secret, token or real phone number
  appears anywhere in the repo.
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
- AC16. Given the repo, when inspected, then the orchestrator and each
  sub-workflow exist as separate files in `workflows/`, each with sticky-note
  section headers, and every workflow sets the shared error workflow in its
  settings.

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
- A5. Webhook path stays `/webhook/waha` (already in `docker-compose.yml`);
  the `whatsapp/<gateway>/incoming` convention in the skill is not applied
  because the current compose is the source of truth.
- A6. Replies are a single message (no splitting into several bubbles).
- A7. Bot copy is Brazilian Portuguese; the business rules are written in
  English and instruct the model to reply in the customer's language.
- A8. Memory and example data are fictional; no real company is modelled.
- A9. Unsupported types get one fixed reply instead of silence, so users know
  why nothing happened.

## 10. Open decisions

- OD1 — Where does the error workflow notify the owner? · options: owner's
  WhatsApp test chat, email, n8n execution log only · recommendation: n8n
  execution log + email (no WhatsApp sends from error paths). No shared error
  workflow exists yet in `workflows/`.
- OD2 — How is the inbound webhook authenticated? The current compose sends
  `message.any` to `http://n8n:5678/webhook/waha` with no secret or HMAC, and
  the skill requires verification. · options: (a) WAHA HMAC
  (`WHATSAPP_HOOK_HMAC_KEY`) or a custom header configured in compose + Header
  Auth on the Webhook node, (b) rely on the internal Docker network only ·
  recommendation: (a); it needs a compose/`.env` change the owner must approve.
- OD3 — Should `message.any` (which includes the bot's own `fromMe` messages)
  stay as the only subscribed event, or switch to `message`? · recommendation:
  keep `message.any` as is and filter `fromMe` in the workflow (no compose
  change).

## Ideas not included

- Debounce/merge several rapid user messages into one LLM turn.
- Per-chat concurrency lock so two executions of one chat never overlap.
- Audio transcription / image understanding for non-text messages.
- "Handover to human" mode that pauses the bot for a chat.
- Splitting long replies into several bubbles with their own typing delays.
- Business-hours awareness (answering differently outside branch hours).
