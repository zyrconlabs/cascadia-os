# Cascadia OS v0.30 — Manual

## Purpose

v0.30 is the first fully merged release. It consolidates:
- The complete kernel and durability layer from v0.21/v0.29
- The browser-based AI setup wizard (ONCE) from v0.21
- The PRISM live dashboard UI restored from v0.21
- The `_send_html` routing capability in service_runtime
- Zyrcon AI as a supported local inference backend alongside llama.cpp and Ollama

The kernel remains small and supervisory. Durable execution is proven by crash tests. The installer now guides non-technical users through AI model selection in a browser UI.

---

## Architecture

### Startup tiers

FLINT starts components in dependency order:

| Tier | Components | Depends on |
|---|---|---|
| 1 | CREW, VAULT, SENTINEL, CURTAIN | — |
| 2 | BEACON, STITCH, VANGUARD, HANDSHAKE, BELL, ALMANAC | CREW (BEACON only) |
| 3 | PRISM | CREW, SENTINEL, BEACON |

Each tier waits for all components in the previous tier to report healthy before proceeding.

### Kernel layer

Owns:
- Process lifecycle (start, health poll, restart with backoff, graceful shutdown)
- Dependency-tier startup sequencing
- External watchdog liveness monitoring
- Top-level system status at `localhost:4011`

Does not own: workflow planning, task scheduling, approval UI, installer logic.

### Durability layer

The most important part. Every run is journaled to SQLite before any side effect executes.

- `run_store.py` — run records, process_state + run_state split
- `step_journal.py` — append-only step ledger, source of truth for resume
- `resume_manager.py` — calculates safe resume point from committed steps
- `idempotency.py` — SHA-256 keyed side effect records, UNIQUE constraint prevents double-execution
- `migration.py` — idempotent schema migrations, handles legacy DB upgrades

### Policy and gating

- `runtime_policy.py` — allow / deny / approval_required per action type
- `approval_store.py` — persists approval requests and decisions, wakes blocked runs
- `dependency_manager.py` — detects missing operators/permissions, writes blocked state

---

## State model

### ProcessState
- `starting` — process launched, not yet ready
- `ready` — health check passing
- `degraded` — health check failing but process alive
- `draining` — shutdown in progress
- `offline` — process not running

### RunState
- `pending` — queued, not started
- `running` — actively executing
- `blocked` — waiting on a missing dependency or permission
- `retrying` — resuming after a crash or failure
- `waiting_human` — approval required before proceeding
- `poisoned` — permanently failed, will never resume
- `complete` — finished successfully
- `failed` — failed with no retry
- `abandoned` — timed out or manually cancelled

---

## Database schema

Tables: `meta`, `runs`, `steps`, `side_effects`, `approvals`, `run_trace`

### runs
Key columns: `run_id`, `operator_id`, `tenant_id`, `goal`, `current_step`, `input_snapshot`, `state_snapshot`, `retry_count`, `last_checkpoint`, `process_state`, `run_state`, `blocked_reason`, `blocking_entity`, `dependency_request`, `created_at`, `updated_at`

### steps
Append-only step ledger. `step_index` is 0-based.

### side_effects
One row per external action. Statuses: `planned`, `committed`, `failed`, `compensated`.

### approvals
One row per approval request/decision. Decisions: `pending`, `approved`, `denied`.

---

## Runtime flows

### Resume flow
1. Load run from `run_store`
2. Scan completed steps in ascending `step_index` order
3. Stop at the first step whose side effects are not fully committed
4. Restore state from the last fully committed step
5. Resume from `last_committed + 1`

### Approval-aware resume
- If run is `waiting_human` and approval is `pending` — does not auto-resume
- If `approved` — `approval_store` transitions run to `retrying`
- If `denied` — run transitions to `failed`

### Dependency blocking
`dependency_manager` checks required operators are installed and healthy, and requested permissions are granted. If anything is missing it writes `run_state = blocked` with `blocked_reason`, `blocking_entity`, and `dependency_request`. It does not install, fix, or retry dependencies.

---

## AI configuration

### Browser wizard (default)

Running `python -m cascadia.installer.once` opens `http://127.0.0.1:4010/` with a 4-step wizard:

1. System scan — RAM, GPU, Ollama detection, Python version
2. AI model selection — QuickStart or manual (local / cloud / Ollama / skip)
3. Config editor — editable JSON block, live validation
4. Launch — start commands, link to PRISM

### Terminal fallback

```bash
python -m cascadia.installer.once --no-browser
```

Prompts through the same four paths interactively.

### Supported AI backends

| Provider | config.json `provider` value |
|---|---|
| Local llama.cpp | `llama-cpp` |
| Zyrcon AI (zyrcon-engine) | `llama-cpp` with `base_url: http://localhost:7000` |
| Ollama | `ollama` |
| OpenAI | `openai` |
| Anthropic | `anthropic` |
| Groq | `groq` |
| Any OpenAI-compatible | `custom` |

---

## Operator manifest schema

Fields:
- `id` — unique operator identifier
- `name` — display name
- `version` — semver
- `type` — `system`, `service`, `skill`, or `composite`
- `capabilities` — list of capability strings the operator provides
- `required_dependencies` — operators that must be present and healthy
- `requested_permissions` — permissions the operator needs
- `autonomy_level` — `manual_only`, `assistive`, `semi_autonomous`, or `autonomous`
- `health_hook` — HTTP path for health checks
- `description` — human-readable description

---

## Runbook

### First-time install
```bash
python -m cascadia.installer.once
```

### Start the OS
```bash
python -m cascadia.kernel.watchdog --config config.json
```

### Check system status
```bash
curl http://127.0.0.1:4011/api/flint/status
```

### Open PRISM dashboard
```bash
open http://127.0.0.1:6300/
```

### Run tests
```bash
python -m unittest discover -s tests -v
python tests/test_crash_recovery.py
```

### Troubleshooting

- **Component restarts repeatedly** — check heartbeat paths and ports in `config.json`, inspect logs in `data/logs/`
- **Run resumes from wrong step** — inspect `steps` and `side_effects` tables
- **Approval never wakes a run** — inspect `approvals` table and run's `run_state`
- **Dependency block unclear** — inspect `blocked_reason`, `blocking_entity`, `dependency_request` in `runs` table
- **PRISM shows blank** — confirm `prism.html` is present at `cascadia/dashboard/prism.html`
- **Setup wizard 500 error** — confirm `setup.html` is present at `cascadia/installer/setup.html`

---

## Not in v0.30

Deliberately deferred:

- SENTINEL enforcement hooks into operator execution loop
- CURTAIN AES-256-GCM / asymmetric key exchange
- HANDSHAKE HTTP execution to external APIs
- VANGUARD SMTP / SMS channel adapters
- PRISM WebSocket real-time push
- SCOUT calendar and email operator implementation
- Workflow scheduler / trigger manager
- MicroVM operator isolation
- Multi-node HA / GRID

---

## Design principles

1. **Trustworthy before clever.** Prove the data model before adding features.
2. **Own your layer.** Execution does not own policy. Policy does not own storage.
3. **Explicit blocking.** A blocked run stays blocked until a human or system event resolves it.
4. **Journal first.** No side effect executes before it is written to the step journal.
5. **Idempotency at the DB layer.** Not by convention — by UNIQUE constraint.
