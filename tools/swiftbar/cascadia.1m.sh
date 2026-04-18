#!/bin/bash
# <swiftbar.title>Cascadia OS</swiftbar.title>
# <swiftbar.version>1.0.0</swiftbar.version>
# <swiftbar.author>Zyrcon Labs</swiftbar.author>
# <swiftbar.desc>Cascadia OS system status and controls</swiftbar.desc>
# <swiftbar.dependencies>bash,curl,python3</swiftbar.dependencies>
# <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>

REPO="$HOME/cascadia-os"
FLINT="http://127.0.0.1:4011"
PRISM="http://127.0.0.1:6300"
LLAMA="http://127.0.0.1:8080"

# ── Check status ──────────────────────────────────────────────────────────────
FLINT_OK=$(curl -sf --max-time 1 "$FLINT/health" 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print('1' if d.get('ok') else '0')" 2>/dev/null || echo "0")
LLAMA_OK=$(curl -sf --max-time 1 "$LLAMA/health" 2>/dev/null | python3 -c "import json,sys; print('1' if json.load(sys.stdin).get('status')=='ok' else '0')" 2>/dev/null || echo "0")

if [[ "$FLINT_OK" == "1" ]]; then
    STATUS_DATA=$(curl -sf --max-time 2 "$FLINT/api/flint/status" 2>/dev/null)
    HEALTHY=$(echo "$STATUS_DATA" | python3 -c "import json,sys; d=json.load(sys.stdin); print(f\"{d.get('components_healthy','?')}/{d.get('components_total','?')}\")" 2>/dev/null || echo "?")
    ICON="⬡"
    LABEL="$ICON $HEALTHY"
else
    ICON="⬡"
    LABEL="$ICON offline"
fi

# ── Menu bar display ──────────────────────────────────────────────────────────
echo "$LABEL"
echo "---"

# ── System status ─────────────────────────────────────────────────────────────
if [[ "$FLINT_OK" == "1" ]]; then
    echo "✓ Cascadia OS — running | color=green"
    echo "  Components: $HEALTHY | color=#666"
else
    echo "✗ Cascadia OS — offline | color=red"
fi

if [[ "$LLAMA_OK" == "1" ]]; then
    MODEL=$(curl -sf --max-time 1 "$LLAMA/v1/models" 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['data'][0]['id'])" 2>/dev/null || echo "unknown")
    echo "✓ LLM — $MODEL | color=green"
else
    echo "✗ LLM — offline | color=red"
fi

echo "---"

# ── Operator status ────────────────────────────────────────────────────────────
echo "Operators"

check_op() {
    local name="$1" port="$2"
    local ok=$(curl -sf --max-time 1 "http://127.0.0.1:$port/api/health" 2>/dev/null | python3 -c "import json,sys; print('1' if json.load(sys.stdin).get('status')=='online' else '0')" 2>/dev/null || echo "0")
    if [[ "$ok" == "1" ]]; then
        echo "  ✓ $name | color=green href=http://localhost:$port/"
    else
        echo "  ○ $name — offline | color=#999"
    fi
}

check_op "RECON"  7001
check_op "QUOTE"  8007
check_op "CHIEF"  8006
check_op "Aurelia" 8009
check_op "Debrief" 8008

echo "---"

# ── Quick actions ─────────────────────────────────────────────────────────────
echo "Quick Actions"
echo "  Open PRISM Dashboard | href=http://localhost:6300/"
echo "  Open RECON Dashboard | href=http://localhost:7001/"

if [[ "$FLINT_OK" == "1" ]]; then
    echo "  Run Demo | bash=$REPO/demo.sh | terminal=true"
    echo "  Stop Cascadia OS | bash=$REPO/stop.sh | terminal=false | refresh=true"
else
    echo "  Start Cascadia OS | bash=$REPO/start.sh | terminal=true | refresh=true"
fi

echo "---"

# ── Pending approvals ─────────────────────────────────────────────────────────
if [[ "$FLINT_OK" == "1" ]]; then
    APPROVALS=$(curl -sf --max-time 2 "$PRISM/api/prism/overview" 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('attention_required',{}).get('pending_approvals',0))" 2>/dev/null || echo "0")
    if [[ "$APPROVALS" != "0" && "$APPROVALS" != "" ]]; then
        echo "⚡ $APPROVALS approval(s) waiting | color=orange href=http://localhost:6300/"
    fi
fi

echo "---"
echo "Cascadia OS v$(cd $REPO && python3 -c 'from cascadia import __version__; print(__version__)' 2>/dev/null || echo '0.34') | color=#999"
echo "Zyrcon Labs | color=#999"
