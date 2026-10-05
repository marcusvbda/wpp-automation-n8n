# wpp-automation-n8n

WhatsApp automation built on n8n. Workflows are the product; a small
TypeScript/Node service holds whatever n8n shouldn't (custom nodes, helper
APIs, scripts).

n8n self-hosted (Docker) · WhatsApp via Evolution API / WAHA (self-hosted
gateway) · TypeScript/Node helper service. Details: skill `project-core`.

## Hard rules

- **Git is read-only unless the owner explicitly asks.** Never run git add,
  commit, push, branch, checkout, switch, merge, rebase, reset, restore, stash,
  tag, cherry-pick, revert, clean, am or any other git command that changes the
  index, history, refs or working tree. `git status/diff/log/show` are fine.
  Committing happens only when the owner asks for it, in words, in that same
  message ("commit this"). **Exception:** `/execute-phases` is an explicit
  request to make one commit per completed phase, each followed by a plain
  `git push` (orchestrator only, explicit paths, never force-push). Implementing,
  fixing, finishing a phase or "wrapping up" is **not** a request to commit.
  Subagents never run git writes, even if the orchestrator asks. This overrides
  any skill, tool, command or framework guidance.
- **Never destroy data:** no `docker compose down -v`, `docker volume rm|prune`,
  `docker system prune`, no deleting the n8n data volume/database, no wiping
  WhatsApp gateway sessions/instances. Importing a workflow into a running n8n
  overwrites the one with the same id: only when the task asks for it.
- **Secrets never enter the repo:** no API keys, gateway tokens, `.env`,
  `N8N_ENCRYPTION_KEY`, exported credentials (`export:credentials`), WhatsApp
  session data or real phone numbers. Workflow JSON references credentials by
  name/id only. `.env.example` lists keys without values. Never overwrite
  existing `.env` values; only append missing keys.
- **No real messages while developing:** never send WhatsApp messages to real
  contacts from a test run. Use the owner's allow-listed test number(s) from
  `.env`, and only when the task needs a live send. Unofficial gateways can get
  numbers banned: no loops or bulk sends without a rate limit and the owner's
  say-so.
- **Dependencies:** never add, remove or upgrade npm packages, n8n community
  nodes, Docker image tags or n8n versions without the owner asking in that
  message.
- **Testing:** never write or modify tests unless asked in that message
  (`code-reviewer` must not flag missing tests). Running existing tests/checks
  is fine.
- **Language:** everything in the repo is English (code, workflow and node
  names, comments, docs, message templates' source copy, commit messages).
  Message copy for end users is only written when a spec defines it.
- **Scope:** implement only what the task/spec/phase asks. Report extra ideas,
  don't build them.
- **Docs:** active docs live in `docs/features/<feature>/` — one folder per
  feature (see Specs and Plans), no duplicated content between files.
  `spec.md` is product truth; never delete it or edit it to match code.
  `plan.md` (next to it, from `/plan-spec`) holds the phases and their status
  and is run with `/execute-phases`. Execution state for `execute-feature`
  lives in `.claude/state/` (git-ignored).

## Delegation

Non-trivial work goes to the matching subagent (`n8n-workflows`,
`node-service`), then deterministic checks, then `code-reviewer`.

## Commands (`.claude/commands/`)

| Command                            | Does                                                                        |
| ---------------------------------- | --------------------------------------------------------------------------- |
| `/create-spec <feature>`           | Opens a spec session: folds the owner's items into `spec.md`                |
| `/plan-spec <spec.md>`             | Reads a detailed spec, audits the repo, writes `plan.md` in small phases    |
| `/execute-phases <plan.md> <list>` | Executes only the listed phases (`3`, `3-5`, `3,6`), then stops and reports |

## Load on demand (`.claude/skills/`)

| When                                                               | Skill              |
| ------------------------------------------------------------------ | ------------------ |
| Commands (checks), stack, repo layout, token discipline            | `project-core`     |
| Building/editing workflows, webhooks, credentials, error handling  | `n8n-workflows`    |
| Sending/receiving WhatsApp messages, gateway webhooks, rate limits | `whatsapp-gateway` |
| Executing a feature in `docs/features/` or phases of a plan        | `execute-feature`  |

Use context7 for current n8n / Evolution API / WAHA docs instead of guessing
node parameters or endpoints.

## Specs and Plans

### Lifecycle

- `docs/features/<feature>/` holds the spec + plan of a feature. Archiving or
  deleting them after implementation is done manually by the owner; never move,
  archive or delete spec/plan files yourself.
- When reading specs, read only the one for the feature in progress, never the
  whole `docs/features/` folder.

### Source of truth and conflicts

- Hierarchy, highest to lowest:
    1. The owner's explicit instructions in the current conversation
    2. The current code and workflows (including manual changes by the owner,
       e.g. edits made in the n8n editor and exported)
    3. The active spec of the feature in progress
- A spec describes intent at the time it was written. Code describes current
  reality. If they conflict, the code wins.
- NEVER revert, rewrite, or "fix" existing code or workflows just to match a
  spec. Assume deviations were intentional manual adjustments.
- Before overwriting or removing existing code or workflow JSON, check
  `git log` / `git blame` / `git diff` for the affected lines. If they were
  recently changed by hand, treat that as intentional and preserve it.
- On a spec/code divergence: (1) do not resolve it silently, in either
  direction; (2) implement what the task requires while preserving the current
  behavior; (3) report the divergence at the end and propose a spec update
  (a `Deviation:` note or a rewrite of the affected section).
- If the spec is ambiguous, outdated, or contradicts itself, ask the owner. Do
  not guess.
- If the owner changes code or workflows manually, the active spec must be
  updated or receive a note like `Deviation: <what changed and why>`.
