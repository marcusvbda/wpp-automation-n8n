-- Stores for the chatbot-waha-car-rental example: dedupe of processed WAHA message ids
-- and per-chat last-reply time for the rate limit. The conversation memory table is created
-- by n8n's Postgres Chat Memory node, not here. Idempotent and additive.
-- Apply: docker compose exec -T postgres psql -U n8n -d n8n -v ON_ERROR_STOP=1 -f - < scripts/sql/chatbot-car-rental.sql

CREATE TABLE IF NOT EXISTS chatbot_processed_messages (
  message_id   text        PRIMARY KEY,
  processed_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS chatbot_chat_reply_state (
  chat_id       text        PRIMARY KEY,
  last_reply_at timestamptz NOT NULL
);
