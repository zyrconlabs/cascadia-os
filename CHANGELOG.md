# Changelog

All notable changes to Cascadia OS are documented here.

---

## v0.30 — 2026-04-17

### Summary
Full merge of v0.21 (GitHub) and v0.29 (Mac local build). v0.21 is a strict superset of v0.29 — all capabilities from v0.29 are preserved and the following are restored or added.

### Added
- **Browser setup wizard** — `cascadia/installer/setup.html` (627 lines). Opens at `http://127.0.0.1:4010/` during first-time install. Four steps: system scan, AI model selection, config editor, launch.
- **System detection in ONCE** — `_detect_ram_gb()` supports Mac (sysctl), Linux (/proc/meminfo), Windows (ctypes). `_detect_ollama()` polls `localhost:11434/api/tags`.
- **AI setup flow** — `setup_ai()` and `_apply_llm_config()` on `OnceInstaller`. Writes LLM provider/model to `config.json` after wizard completes.
- **Terminal fallback** — `_terminal_ai_setup()` presents the same four paths (local / cloud / Ollama / skip) as prompts. Triggered by `--no-browser` flag.
- **LLM block in DEFAULT_CONFIG** — `provider`, `model`, `configured` keys included from first run.
- **`models/` directory** — added to `DEFAULT_DIRS`, created on install.
- **`_send_html()` in service_runtime** — HTTP handler can now serve HTML responses via the `__html__` envelope key, not just JSON.
- **PRISM live UI** — `serve_ui()` route registered at `GET /` in `prism.py`. Serves `prism.html` at `http://localhost:6300/`. Dashboard was headless (JSON-only) in v0.29.
- **`cascadia/dashboard/prism.html`** — 60KB single-file dashboard. Restored from v0.21.
- **Zyrcon AI listed as supported backend** — `llama-cpp` provider with `base_url: http://localhost:7000` connects to `zyrcon-engine`.
- **Port reference table** — documented in README and MANUAL.
- **`CHANGELOG.md`** — this file.

### Changed
- Version bumped to `0.30` across `once.py`, `pyproject.toml`, `setup.html`.
- README rewritten: install section updated, AI setup section added, port table added, partial/roadmap sections updated to reflect v0.30 state.
- MANUAL rewritten: AI configuration section added with all supported backends, troubleshooting expanded for PRISM and setup wizard.

### Unchanged
All 27 other modules are byte-identical between v0.21 and v0.29 and carry forward unchanged:
`flint.py`, `watchdog.py`, `run_store.py`, `step_journal.py`, `resume_manager.py`, `idempotency.py`, `migration.py`, `sentinel.py`, `curtain.py`, `beacon.py`, `stitch.py`, `vanguard.py`, `handshake.py`, `bell.py`, `almanac.py`, `vault.py`, `crew.py`, `runtime_policy.py`, `approval_store.py`, `dependency_manager.py`, `run_trace.py`, `db.py`, `envelopes.py`, `ids.py`, `logger.py`, `config.py`, `manifest_schema.py`

---

## v0.21 — 2026-04-17 (GitHub release)

- Browser-based AI setup wizard added to ONCE installer
- `_detect_ram_gb()`, `_detect_ollama()` system detection
- `SetupServer` class serving `setup.html` on port 4010
- `_terminal_ai_setup()` fallback for headless installs
- `--no-browser` CLI flag
- `_send_html()` in `service_runtime.py`
- PRISM `serve_ui()` route — dashboard accessible at `localhost:6300/`
- `setup.html` and `prism.html` shipped with the package

---

## v0.29 — 2026-04-14 (Mac local build)

- Stripped installer — setup wizard and AI detection removed for simplicity
- `prism.html` removed from dashboard (backend-only)
- `_send_html()` removed from service_runtime
- All kernel, durability, and policy modules identical to v0.21

---

## v0.2 — 2026-04-11

- FLINT process supervisor with tiered startup, health polling, restart/backoff, graceful shutdown
- Watchdog external liveness monitor
- Full durability layer: run_store, step_journal, resume_manager, idempotency, migration
- Policy and gating: runtime_policy, approval_store, dependency_manager
- Named components: CREW, VAULT, SENTINEL, CURTAIN, BEACON, STITCH, VANGUARD, HANDSHAKE, BELL, ALMANAC, PRISM
- Shared infrastructure: service_runtime, db, envelopes, ids, logger, config, manifest_schema
- 21/21 crash recovery tests passing
- Operator manifests: calendar_operator.json, gmail_operator.json, main_operator.json
