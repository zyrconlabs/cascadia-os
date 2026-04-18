# Cascadia OS

> **The execution layer for AI operators that actually finish the work.**

---

I was five years old the first time I took apart a telephone. Not for school. Because I needed to understand how the sound got through the wire.

Decades later — aerospace engineering in Moscow, automation projects for Amazon and the US Navy, building at 2am while my daughter slept — I kept running into the same problem: AI that was impressive in demos and unreliable in production.

I didn't want a chatbot. I wanted an operator I could trust. Something that remembers, asks before acting, and picks up where it left off after a crash. Something designed for the moment when things go wrong at three in the morning and nobody is watching.

**That's what this is.** → [Full story](./STORY.md)

---

## See it working

**One-click install — done in under a minute:**
![Install](./assets/install.png)

**Watchdog running — all 11 components healthy:**
![Watchdog](./assets/watchdog.png)

**PRISM dashboard — live system status:**
![PRISM Dashboard](./assets/prism.png)

**Crash recovery — 21/21 tests passed:**
![Crash Recovery](./assets/crash_recovery.png)

---

Most AI tools are impressive in demos. They forget context, act without guardrails, and collapse when a workflow spans more than one session.

Cascadia OS is built to a different standard — durable enough to survive crashes, supervised enough to ask before taking sensitive actions, and honest enough to tell you exactly what it can and can't do.

---

## One-Click Install

**Mac / Linux:**
```bash
curl -fsSL https://raw.githubusercontent.com/Zyrconlabs/cascadia-os/main/install.sh | bash
```

**Windows** — in PowerShell:
```powershell
irm https://raw.githubusercontent.com/Zyrconlabs/cascadia-os/main/install.bat -OutFile install.bat; .\install.bat
```

> **Requires:** Python 3.11+ and git

The installer clones the repo, creates a virtual environment, installs the package, runs the browser-based AI setup wizard, and adds a `cascadia` launcher to your PATH.

---

## Manual Start

```bash
# First-time setup (opens browser wizard at http://127.0.0.1:4010)
python -m cascadia.installer.once

# Terminal-only setup (no browser)
python -m cascadia.installer.once --no-browser

# Start the OS (watchdog keeps FLINT alive)
python -m cascadia.kernel.watchdog --config config.json

# Run all tests
python -m unittest discover -s tests -v

# Run crash and recovery drills
python tests/test_crash_recovery.py
```

---

## What it does

Cascadia OS coordinates AI operators that:

- **Remember** — context, decisions, and state persist across sessions and crashes
- **Ask** — approval gates block risky actions until a human says yes
- **Never duplicate** — idempotency enforced at the database layer, not by hope
- **Recover** — resume from the last committed step, not from scratch
- **Run supervised** — FLINT watches every process; the watchdog watches FLINT

---

## What is working right now (v0.30)

### Control plane
| Module | What it does |
|---|---|
| FLINT `kernel/flint.py` | Process supervision, tiered startup, health polling, restart/backoff, graceful shutdown |
| Watchdog `kernel/watchdog.py` | External FLINT liveness monitor — lives outside the supervision tree |

### Installer
| Module | What it does |
|---|---|
| ONCE `installer/once.py` | Browser setup wizard, RAM/GPU/Ollama detection, AI model config, directory init, manifest validation |
| setup.html `installer/setup.html` | 4-step browser UI: system scan → model selection → config editor → launch |

### Durability layer
| Module | What it does |
|---|---|
| run_store | Durable run records with process_state + run_state split |
| step_journal | Append-only step log — source of truth for resume |
| resume_manager | Safe resume-point calculation from committed steps |
| idempotency | SHA-256 keyed side effect records, UNIQUE DB constraint |
| migration | Idempotent schema migration, handles legacy DB upgrades |

### Policy and approvals
| Module | What it does |
|---|---|
| runtime_policy | allow / deny / approval_required per action type |
| approval_store | Persists approval requests and decisions, wakes blocked runs |
| dependency_manager | Detects missing operators and permissions, writes blocked state |

### Named components
| Name | Path | What it does |
|---|---|---|
| CREW | `registry/crew.py` | Operator group registry with wildcard capability validation |
| VAULT | `memory/vault.py` | Durable SQLite-backed memory, capability-gated |
| SENTINEL | `security/sentinel.py` | Risk classification: low / medium / high / critical per action |
| CURTAIN | `encryption/curtain.py` | HMAC-SHA256 envelope signing and field encryption (stdlib only) |
| BEACON | `orchestrator/beacon.py` | Capability-checked routing and operator handoffs |
| STITCH | `automation/stitch.py` | Workflow sequencing with built-in templates |
| VANGUARD | `gateway/vanguard.py` | Inbound channel normalization, outbound dispatch |
| HANDSHAKE | `bridge/handshake.py` | External API connection registry |
| BELL | `chat/bell.py` | Chat sessions and approval response collection |
| ALMANAC | `guide/almanac.py` | Component catalog, glossary (26 terms), runbooks |
| PRISM | `dashboard/prism.py` | Live dashboard at `localhost:6300/` — runs, approvals, blocked, crew |

---

## Reliability guarantees — proven by crash tests

These are tested in `tests/test_crash_recovery.py`. Not just claimed.

| Scenario | Behavior |
|---|---|
| Kill operator mid-run | Resumes from last committed step, not step 0 |
| Crash after side effect declared but not committed | Re-attempts the effect on resume |
| Crash after side effect committed | Skips the effect — never duplicates |
| Approval-required run restarted | Stays `waiting_human`, never auto-resumes |
| Poisoned or complete run | Never resumed under any condition |
| Multiple crashes in sequence | `retry_count` increments correctly each time |

---

## AI model setup

ONCE supports four paths, selected in the browser wizard or terminal fallback:

| Path | How |
|---|---|
| Local llama.cpp | Downloads Qwen 2.5 (3B / 7B / 14B) — private, no API cost |
| Zyrcon AI | Points to your running `zyrcon-engine` on `localhost:7000` |
| Cloud API | OpenAI, Anthropic, Groq, or any compatible endpoint |
| Ollama | Detects running models at `localhost:11434` automatically |

The browser wizard opens at `http://127.0.0.1:4010/` during install. Use `--no-browser` for headless or server installs.

---

## PRISM dashboard

```bash
# Live UI
open http://127.0.0.1:6300/

# API endpoints
GET  http://127.0.0.1:6300/api/prism/overview    # Full system snapshot
GET  http://127.0.0.1:6300/api/prism/runs        # Recent run states
GET  http://127.0.0.1:6300/api/prism/approvals   # Pending human decisions
GET  http://127.0.0.1:6300/api/prism/blocked     # Runs blocked on dependencies
GET  http://127.0.0.1:6300/api/prism/crew        # Active operators
GET  http://127.0.0.1:6300/api/prism/sentinel    # Risk levels
GET  http://127.0.0.1:4011/health                # FLINT liveness check
```

---

## What is partial in v0.30

Present and registered, but not fully wired end-to-end yet:

- **SENTINEL** — risk rules work; enforcement hooks into the full operator loop are v0.31
- **CURTAIN** — HMAC signing works; AES-256-GCM and asymmetric key exchange are v0.31
- **HANDSHAKE** — connection registry works; actual HTTP execution to external APIs is v0.31
- **VANGUARD** — normalization works; real channel adapters (SMTP, SMS) are v0.31
- **PRISM** — aggregation queries work; real-time WebSocket push is v0.31

---

## Roadmap

### v0.31
- SENTINEL enforcement wired end-to-end
- CURTAIN AES-256-GCM + asymmetric key exchange
- HANDSHAKE HTTP execution to external APIs
- VANGUARD SMTP and SMS channel adapters
- PRISM WebSocket real-time push
- SCOUT operator — calendar and email implementation

### v0.4+
- GRID — decentralized compute network
- DEPOT — operator marketplace
- Scheduler and trigger manager
- MicroVM operator isolation
- Multi-node HA

---

## Port reference

| Port | Band | Component |
|---|---|---|
| 4010 | 4xxx — kernel | ONCE setup wizard (install time only) |
| 4011 | 4xxx — kernel | FLINT status API |
| 5100 | 5xxx — foundation | CREW |
| 5101 | 5xxx — foundation | VAULT |
| 5102 | 5xxx — foundation | SENTINEL |
| 5103 | 5xxx — foundation | CURTAIN |
| 6200 | 6xxx — runtime | BEACON |
| 6201 | 6xxx — runtime | STITCH |
| 6202 | 6xxx — runtime | VANGUARD |
| 6203 | 6xxx — runtime | HANDSHAKE |
| 6204 | 6xxx — runtime | BELL |
| 6205 | 6xxx — runtime | ALMANAC |
| 6300 | 6xxx — visibility | PRISM (dashboard UI + API) |
| 7000+ | 7xxx — operators | SCOUT, RECON, future operators |
| 8200+ | 8xxx — expansion | GRID, DEPOT (roadmap) |

---

## Design rules

1. FLINT supervises. FLINT does not execute workflows.
2. No side effect executes twice. Idempotency is enforced at the DB layer.
3. Resume reads the journal. Resume does not guess.
4. Dangerous actions require policy clearance. Policy is separate from capability.
5. Blocking a run is explicit. Auto-resuming a blocked run is never allowed.
6. The module that owns execution does not own policy. The module that owns policy does not own storage.

---

## Docs

- [Manual](./MANUAL.md)
- [Changelog](./CHANGELOG.md)
- [Contributing](./CONTRIBUTING.md)
- [Security Policy](./SECURITY.md)
- [Support](./SUPPORT.md)
- [Story behind the project](./STORY.md)

---

*Built in Houston, Texas — [Zyrcon Labs](https://zyrconlabs.com)*
