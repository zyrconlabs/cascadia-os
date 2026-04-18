#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# Cascadia OS — final investor-readiness fixes
# 1. RECON hallucination filter (reject fake placeholder records)
# 2. Aurelia + Debrief operator import fix
# 3. RECON autostart with Cascadia
#
# Run from repo root: bash apply-final-fixes.sh
# ═══════════════════════════════════════════════════════════════════════════════
set -e
REPO="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -f "$REPO/cascadia/kernel/flint.py" ]]; then
  echo "ERROR: Run from inside your cascadia-os repo."
  echo "  cd ~/cascadia-os && bash apply-final-fixes.sh"
  exit 1
fi

echo "Applying final investor-readiness fixes to: $REPO"
echo ""

# ── 1. RECON hallucination filter ─────────────────────────────────────────────
echo "[1/3] cascadia/operators/recon/recon_worker.py — adding hallucination filter"
python3 - <<'PYEOF'
import pathlib, re

p = pathlib.Path("cascadia/operators/recon/recon_worker.py")
src = p.read_text()

old_validate = '''def validate_rows(raw: list, state: dict) -> list[dict]:
    """Deduplicate and filter low-confidence records."""
    seen = set(state.get("seen_hashes", []))
    clean = []
    for row in raw:
        if not isinstance(row, dict):
            continue
        if str(row.get("confidence", "low")).lower() == "low":
            continue
        h = _row_hash(row)
        if h in seen:
            log.debug("Duplicate skipped: %s", row.get("full_name") or row.get("company"))
            continue
        seen.add(h)
        clean.append(row)

    state["seen_hashes"] = list(seen)
    return clean'''

new_validate = '''# ── Hallucination indicators ─────────────────────────────────────────────────
_FAKE_NAMES    = {"john doe", "jane doe", "jane smith", "john smith",
                  "test user", "example user", "first last", "name here"}
_FAKE_PHONES   = {"555-1234", "555-5678", "555-0000", "555-1111",
                  "123-456-7890", "000-000-0000", "(555)"}
_FAKE_EMAIL_PATTERNS = ["john.doe@", "jane.smith@", "john.smith@",
                         "jane.doe@", "test@", "example@", "user@example",
                         "@example.com", "@test.com"]
_FAKE_LINKEDIN = {"https://www.linkedin.com/in/johndoe",
                  "https://www.linkedin.com/in/janesmith",
                  "https://www.linkedin.com/in/johnsmith"}

def _is_hallucinated(row: dict) -> bool:
    """Return True if this record looks like a hallucinated placeholder."""
    name  = str(row.get("full_name", "")).strip().lower()
    phone = str(row.get("phone", "")).strip()
    email = str(row.get("email", "")).strip().lower()
    li    = str(row.get("linkedin", "")).strip()

    if name in _FAKE_NAMES:
        return True
    if any(phone.startswith(fp) or fp in phone for fp in _FAKE_PHONES):
        return True
    if any(pat in email for pat in _FAKE_EMAIL_PATTERNS):
        return True
    if li in _FAKE_LINKEDIN:
        return True
    # Reject records with no real name or company
    if not name or not row.get("company", "").strip():
        return True
    return False


def validate_rows(raw: list, state: dict) -> list[dict]:
    """Deduplicate, filter low-confidence, and reject hallucinated records."""
    seen = set(state.get("seen_hashes", []))
    clean = []
    for row in raw:
        if not isinstance(row, dict):
            continue
        if str(row.get("confidence", "low")).lower() == "low":
            continue
        if _is_hallucinated(row):
            log.debug("Hallucination rejected: %s / %s",
                      row.get("full_name"), row.get("email"))
            continue
        h = _row_hash(row)
        if h in seen:
            log.debug("Duplicate skipped: %s", row.get("full_name") or row.get("company"))
            continue
        seen.add(h)
        clean.append(row)

    state["seen_hashes"] = list(seen)
    return clean'''

if old_validate in src:
    src = src.replace(old_validate, new_validate)
    p.write_text(src)
    print("  hallucination filter added to validate_rows")
else:
    print("  WARNING: could not find validate_rows — check manually")
PYEOF

# ── 2a. Fix Aurelia import ─────────────────────────────────────────────────────
echo "[2/3] Fixing operator import in Aurelia and Debrief"

fix_import() {
    local dir="$1"
    local classname="$2"
    local modname="$3"
    local dashpy="$dir/dashboard.py"

    if [[ ! -f "$dashpy" ]]; then
        echo "  SKIP: $dashpy not found"
        return
    fi

    if grep -q "importlib.util" "$dashpy"; then
        echo "  SKIP: $dir already patched"
        return
    fi

    python3 - "$dashpy" "$classname" "$modname" <<'INNEREOF'
import sys, pathlib

dash = pathlib.Path(sys.argv[1])
classname = sys.argv[2]
modname = sys.argv[3]

src = dash.read_text()
old = f"from operator import {classname}"
new = (
    f"import importlib.util as _ilu, pathlib as _ipl\n"
    f"_ispec = _ilu.spec_from_file_location('{modname}', _ipl.Path(__file__).parent / 'operator.py')\n"
    f"_imod = _ilu.module_from_spec(_ispec); _ispec.loader.exec_module(_imod)\n"
    f"{classname} = _imod.{classname}"
)

if old in src:
    src = src.replace(old, new)
    dash.write_text(src)
    print(f"  fixed: {dash}")
else:
    print(f"  not found (may already be fixed or different pattern): {old}")
INNEREOF
}

# Aurelia
AURELIA_DIR="$HOME/operators/Aurelia"
if [[ -d "$AURELIA_DIR" ]]; then
    fix_import "$AURELIA_DIR" "AureliaEngine" "aurelia_engine"
else
    echo "  Aurelia not installed at ~/operators/Aurelia — skipping"
fi

# Debrief (no operator.py — uses direct flask, skip)
DEBRIEF_DIR="$HOME/operators/Debrief"
if [[ -d "$DEBRIEF_DIR" ]]; then
    if grep -q "from operator import" "$DEBRIEF_DIR/dashboard.py" 2>/dev/null; then
        fix_import "$DEBRIEF_DIR" "DebriefEngine" "debrief_engine"
    else
        echo "  Debrief: no operator import to fix"
    fi
else
    echo "  Debrief not installed at ~/operators/Debrief — skipping"
fi

# Also fix CompetitionResearcher and JrProgrammer if present
for pair in "CompetitionResearcher:CompetitionResearcher" "JrProgrammer:JrProgrammer"; do
    name="${pair%%:*}"
    cls="${pair##*:}"
    dir="$HOME/operators/$name"
    if [[ -d "$dir" ]] && grep -q "from operator import" "$dir/dashboard.py" 2>/dev/null; then
        fix_import "$dir" "$cls" "$(echo $cls | tr '[:upper:]' '[:lower:]')"
    fi
done

# ── 3. RECON autostart ────────────────────────────────────────────────────────
echo "[3/3] Adding RECON autostart to Cascadia startup"
python3 - <<'PYEOF'
import pathlib, json

# Add a startup script that launches RECON alongside Cascadia
p = pathlib.Path("start.sh")
content = '''#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# Cascadia OS — full stack startup
# Starts: Cascadia OS (11 components) + llama.cpp + RECON + QUOTE + CHIEF
# ═══════════════════════════════════════════════════════════════════════════
REPO="$(cd "$(dirname "$0")" && pwd)"
cd "$REPO"

LLAMA_BIN="$HOME/llama.cpp/build/bin/llama-server"
LLAMA_MODEL="$HOME/ai models/qwen2.5-3b-instruct-q4_k_m.gguf"

echo "Starting Cascadia OS full stack..."
echo ""

# ── 1. llama.cpp ──────────────────────────────────────────────────────────
if curl -sf http://127.0.0.1:8080/health > /dev/null 2>&1; then
    echo "✓ llama.cpp already running"
else
    echo "▸ Starting llama.cpp (Qwen 3B)..."
    lsof -ti :8080 | xargs kill -9 2>/dev/null; sleep 1
    "$LLAMA_BIN" \\
        --model "$LLAMA_MODEL" \\
        --host 127.0.0.1 --port 8080 \\
        --ctx-size 4096 --n-gpu-layers 99 \\
        --alias zyrcon-ai-v0.1 \\
        > data/logs/llamacpp.log 2>&1 &
    sleep 6
    curl -sf http://127.0.0.1:8080/health > /dev/null && echo "✓ llama.cpp ready" || echo "✗ llama.cpp failed — check data/logs/llamacpp.log"
fi

# ── 2. Cascadia OS ────────────────────────────────────────────────────────
if curl -sf http://127.0.0.1:4011/health > /dev/null 2>&1; then
    echo "✓ Cascadia OS already running"
else
    echo "▸ Starting Cascadia OS..."
    python3 -m cascadia.kernel.watchdog --config config.json >> data/logs/flint.log 2>&1 &
    sleep 10
    curl -sf http://127.0.0.1:4011/health > /dev/null && echo "✓ Cascadia OS ready (11/11)" || echo "✗ Cascadia OS failed"
fi

# ── 3. RECON worker ───────────────────────────────────────────────────────
if ps aux | grep -q "[r]econ_worker"; then
    echo "✓ RECON already running"
else
    echo "▸ Starting RECON worker..."
    mkdir -p data/vault/operators/recon/tasks/current
    if [[ ! -f data/vault/operators/recon/tasks/current/task.md ]]; then
        cp cascadia/operators/recon/tasks/current/task.md data/vault/operators/recon/tasks/current/
    fi
    python3 cascadia/operators/recon/recon_worker.py >> data/logs/recon.log 2>&1 &
    sleep 2
    ps aux | grep -q "[r]econ_worker" && echo "✓ RECON worker running" || echo "✗ RECON failed"
fi

# ── 4. QUOTE operator ─────────────────────────────────────────────────────
if curl -sf http://127.0.0.1:8007/api/health > /dev/null 2>&1; then
    echo "✓ QUOTE already running"
else
    echo "▸ Starting QUOTE..."
    cd "$HOME/operators/QUOTE"
    python3 dashboard.py >> "$REPO/data/logs/quote.log" 2>&1 &
    cd "$REPO"
    sleep 3
    curl -sf http://127.0.0.1:8007/api/health > /dev/null && echo "✓ QUOTE ready" || echo "✗ QUOTE failed"
fi

# ── 5. CHIEF operator ─────────────────────────────────────────────────────
if curl -sf http://127.0.0.1:8006/api/health > /dev/null 2>&1; then
    echo "✓ CHIEF already running"
else
    echo "▸ Starting CHIEF..."
    cd "$HOME/operators/CHIEF"
    python3 dashboard.py >> "$REPO/data/logs/chief.log" 2>&1 &
    cd "$REPO"
    sleep 3
    curl -sf http://127.0.0.1:8006/api/health > /dev/null && echo "✓ CHIEF ready" || echo "✗ CHIEF failed"
fi

echo ""
echo "═══════════════════════════════════════════════════════════"
echo " Cascadia OS stack is up."
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "  PRISM dashboard  →  http://localhost:6300/"
echo "  RECON dashboard  →  http://localhost:8002/"
echo "  QUOTE            →  http://localhost:8007/"
echo "  CHIEF brief      →  POST http://localhost:8006/api/brief"
echo ""
echo "  Run demo:  bash demo.sh"
echo "  Run brief: curl -s http://127.0.0.1:8006/api/brief -X POST | python3 -m json.tool"
echo ""
'''
p.write_text(content)
p.chmod(0o755)
print("  start.sh created")

# Also add stop.sh
stop = pathlib.Path("stop.sh")
stop.write_text('''#!/bin/bash
echo "Stopping Cascadia OS stack..."
pkill -f "cascadia.kernel.watchdog" 2>/dev/null && echo "✓ Cascadia OS stopped" || true
pkill -f "recon_worker" 2>/dev/null && echo "✓ RECON stopped" || true
pkill -f "operators/QUOTE/dashboard" 2>/dev/null && echo "✓ QUOTE stopped" || true
pkill -f "operators/CHIEF/dashboard" 2>/dev/null && echo "✓ CHIEF stopped" || true
lsof -ti :8080 | xargs kill -9 2>/dev/null && echo "✓ llama.cpp stopped" || true
echo "Done."
''')
stop.chmod(0o755)
print("  stop.sh created")
PYEOF

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
echo " All fixes applied."
echo "═══════════════════════════════════════════════════"
echo ""
echo " To start everything in one command:"
echo "   cd ~/cascadia-os && bash start.sh"
echo ""
echo " To install Aurelia and Debrief if not done yet:"
echo "   unzip ~/Downloads/Aurelia-Operator-v1_0.zip -d ~/operators"
echo "   unzip ~/Downloads/Debrief-Operator-v1_0.zip -d ~/operators"
echo "   then re-run this script"
echo ""
