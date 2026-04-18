#!/bin/bash
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
    "$LLAMA_BIN" \
        --model "$LLAMA_MODEL" \
        --host 127.0.0.1 --port 8080 \
        --ctx-size 4096 --n-gpu-layers 99 \
        --alias zyrcon-ai-v0.1 \
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
