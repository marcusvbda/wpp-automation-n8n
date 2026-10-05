---
name: whatsapp-gateway
description: Invariants for talking to the self-hosted WhatsApp gateway (Evolution API or WAHA) from n8n and the TypeScript service — inbound webhooks, outbound sends, identifiers, rate limits, test safety. Load before touching any WhatsApp send/receive logic.
---

# WhatsApp gateway — invariants

The gateway is **Evolution API or WAHA** (unofficial, self-hosted); which one
a feature uses comes from its spec. Don't assume one's endpoints for the
other — look up the exact endpoint, header and payload with context7 or the
gateway's own docs before writing a node.

## Rules that hold for both

- **Normalize at the edge.** Convert the gateway-specific webhook payload into
  one internal message shape immediately after the trigger (suggested fields:
  `messageId, chatId, senderId, fromMe, type, text, mediaUrl, timestamp,
  isGroup`). Everything downstream depends only on that shape, so swapping
  gateway touches one workflow.
- **Identifiers.** Treat chat/sender ids as opaque strings from the gateway
  (JIDs, `@c.us` etc.). Don't parse or rebuild them with regex guesses; keep
  phone numbers E.164 only where a send endpoint demands it.
- **Dedupe** on `messageId`; **ignore** `fromMe`, status/ack events and
  unsupported types unless a spec says otherwise.
- **Authenticate inbound.** Verify the webhook secret/header the gateway is
  configured to send; reject otherwise. The gateway API key lives in an n8n
  credential, never in JSON.
- **Rate-limit outbound.** Unofficial gateways risk number bans. Every send
  path has a per-chat and a global rate limit, human-like delays between bulk
  messages, and no unsolicited first-contact sends unless the spec defines
  opt-in. Report any flow that could message many contacts.
- **Test safety.** Development sends go only to the allow-listed test
  number(s) from `.env`. Dev workflows gate the send node behind that
  allow-list check. Never use real customer data in fixtures.
- **Sessions.** The gateway instance/session (QR pairing, auth state) is
  durable state: never delete, recreate or log out an instance without the
  owner asking.
- **Failures.** A failed send is recorded and routed to the error workflow; it
  is not retried blindly (risk of duplicate delivery).
- **Media.** Download/upload media through the gateway's documented endpoints;
  don't persist media in the repo.
- **PII.** No phone numbers, names or message bodies in logs, commit
  history, specs or workflow JSON; use placeholders (`5511900000000` style is
  still a number — use obviously fake values like `<TEST_NUMBER>`).
