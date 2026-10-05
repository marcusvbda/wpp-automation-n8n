---
name: project-core
description: Stack detail, repo layout, the checks that exist in this repo, and token discipline. Load before verifying a change or choosing how to verify it.
---

# Project core

Supports `CLAUDE.md`, never replaces it. Global rules (git, data, secrets,
deps, tests, language) stay there.

## Stack detail

- n8n self-hosted via Docker Compose (image tag pinned by the owner).
- WhatsApp through a self-hosted gateway: Evolution API or WAHA (see
  `whatsapp-gateway`; which one is chosen per feature spec).
- TypeScript/Node helper service and scripts (package manager, Node version
  and layout are set by the first scaffold — read `package.json` before
  assuming).
- Secrets and per-environment values live in `.env` (git-ignored); keys are
  documented in `.env.example`.

## Repo layout (target — create only what a task needs)

```text
workflows/        n8n workflow JSON, one file per workflow (kebab-case name)
services/         TypeScript/Node helper service(s) and custom nodes
scripts/          export/import and setup scripts
docker-compose.yml, .env.example
docs/features/<feature>/spec.md, plan.md
```

Don't create these folders ahead of need and don't restructure without the
owner asking.

## Deterministic verification

Nothing is scaffolded yet, so **no project script exists**. Don't invent
commands. Until the scaffold lands, use only:

| Purpose                 | Command                                                           |
| ----------------------- | ----------------------------------------------------------------- |
| Workflow JSON validity  | `jq empty workflows/*.json`                                       |
| Secrets/PII sweep       | `grep -rnEi "apikey\|api_key\|token\|Bearer \|@s\.whatsapp\.net" workflows/` and review hits |
| Compose file validity   | `docker compose config -q`                                        |

Once `package.json` exists, add its real scripts here (typecheck, lint,
build, test) in the same table and keep this section the single source for
"what to run". Running existing tests is always fine; creating/modifying
tests is not (see `CLAUDE.md`).

## Tooling

Use context7 (`resolve-library-id`, `query-docs`) for n8n, Evolution API,
WAHA and npm library docs. Use playwright MCP only to inspect the n8n editor
or gateway dashboard when the task needs it, never to send real messages.

## Token discipline

- Load a skill only when its domain is relevant.
- Review the task diff, not the repository.
- Deterministic checks first; AI review for judgement only.
- One integrated review per feature/plan end, not a full-repo review per task.
- A stalled subagent gets **one** resume max; then verify the concern directly
  with a targeted `Read`/`Grep`.
- Don't read whole exported workflow JSON when a `jq` query for the nodes in
  question answers it.
- **Embed contracts in delegation prompts** (node names, webhook paths,
  payload shapes, AC text, invariants) instead of telling a subagent to go
  read `docs/` or skills — that is what burns its turn budget.
