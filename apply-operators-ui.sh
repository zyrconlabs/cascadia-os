#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# Cascadia OS — PRISM operator cards + SwiftBar menu bar plugin
# 1. Adds /api/prism/operators endpoint to prism.py
# 2. Injects operator section into prism.html sidebar
# 3. Creates SwiftBar plugin for menu bar control
#
# Run from repo root: bash apply-operators-ui.sh
# ═══════════════════════════════════════════════════════════════════════════════
set -e
REPO="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -f "$REPO/cascadia/kernel/flint.py" ]]; then
  echo "ERROR: Run from inside your cascadia-os repo."
  exit 1
fi

echo "Adding operator cards to PRISM + SwiftBar plugin"
echo ""

# ── 1. prism.py — add /api/prism/operators endpoint ───────────────────────────
echo "[1/3] cascadia/dashboard/prism.py — adding operators endpoint"
python3 - <<'PYEOF'
import pathlib, json

p = pathlib.Path("cascadia/dashboard/prism.py")
src = p.read_text()

# Register the route
old_routes = "        self.runtime.register_route('POST', '/api/prism/approve',    self.approve_action)"
new_routes = (
    "        self.runtime.register_route('POST', '/api/prism/approve',    self.approve_action)\n"
    "        self.runtime.register_route('GET',  '/api/prism/operators',  self.operator_status)"
)
if '/api/prism/operators' not in src:
    src = src.replace(old_routes, new_routes)
    print("  route registered")

# Add the method — insert before the last method or at end of class
new_method = '''
    def operator_status(self, _: Dict[str, Any]) -> tuple[int, Dict[str, Any]]:
        """Live status of all registered operators from registry.json."""
        import urllib.request as _ur
        registry_path = Path(__file__).parent.parent / "operators" / "registry.json"
        try:
            registry = json.loads(registry_path.read_text())
            operators = registry.get("operators", [])
        except Exception:
            operators = []

        result = []
        for op in operators:
            port = op.get("port")
            health_path = op.get("health_path", "/api/health")
            status = "offline"
            detail = {}
            if port:
                try:
                    with _ur.urlopen(
                        f"http://127.0.0.1:{port}{health_path}", timeout=1
                    ) as r:
                        detail = json.loads(r.read().decode())
                        status = detail.get("status", "online")
                except Exception:
                    status = "offline"
            result.append({
                "id":          op.get("id"),
                "name":        op.get("name"),
                "category":    op.get("category"),
                "description": op.get("description"),
                "status":      status,
                "port":        port,
                "autonomy":    op.get("autonomy"),
                "op_status":   op.get("status"),  # production/beta
                "ui_url":      f"http://localhost:{port}/" if port else None,
                "sample_output": op.get("sample_output"),
            })

        online = sum(1 for o in result if o["status"] != "offline")
        return 200, {
            "operators": result,
            "total": len(result),
            "online": online,
            "generated_at": _now(),
        }

'''

# Insert before the last method in the class
if 'def operator_status' not in src:
    src = src.replace(
        '\n    def approve_action',
        new_method + '\n    def approve_action'
    )
    print("  operator_status method added")

# Make sure json is imported
if 'import json' not in src:
    src = 'import json\n' + src

p.write_text(src)
print("  prism.py saved")
PYEOF

# ── 2. prism.html — inject operator section into sidebar ─────────────────────
echo "[2/3] cascadia/dashboard/prism.html — adding operator cards"
python3 - <<'PYEOF'
import pathlib, re

p = pathlib.Path("cascadia/dashboard/prism.html")
src = p.read_text()

# ── CSS for operator cards ────────────────────────────────────────────────────
operator_css = """
/* ── OPERATOR CARDS ── */
.op-section{padding:8px 16px 4px;font-family:var(--mono);font-size:9px;font-weight:500;color:var(--gray-400);letter-spacing:.1em;text-transform:uppercase;display:flex;align-items:center;justify-content:space-between}
.op-count{font-size:9px;color:var(--gray-400);font-family:var(--mono)}
.op-card{display:flex;align-items:center;gap:10px;padding:9px 16px;cursor:pointer;border-bottom:1px solid var(--gray-100);transition:background .12s;text-decoration:none}
.op-card:hover{background:var(--gray-100)}
.op-icon{width:32px;height:32px;border-radius:8px;display:flex;align-items:center;justify-content:center;font-size:13px;font-weight:700;flex-shrink:0;color:#fff;position:relative}
.op-icon--intelligence{background:linear-gradient(135deg,#4facfe,#00f2fe)}
.op-icon--sales{background:linear-gradient(135deg,#43e97b,#38f9d7)}
.op-icon--executive{background:linear-gradient(135deg,#fa709a,#fee140)}
.op-icon--inbound{background:linear-gradient(135deg,#a18cd1,#fbc2eb)}
.op-icon--engineering{background:linear-gradient(135deg,#f093fb,#f5576c)}
.op-body{flex:1;min-width:0}
.op-name{font-size:12px;font-weight:600;color:var(--navy-800);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.op-desc{font-size:10px;color:var(--gray-500);margin-top:1px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.op-badges{display:flex;gap:4px;margin-top:3px;flex-wrap:wrap}
.op-badge{font-size:8.5px;font-family:var(--mono);padding:1px 5px;border-radius:3px;font-weight:500}
.op-badge--production{background:rgba(52,211,153,.15);color:#059669}
.op-badge--beta{background:rgba(167,139,250,.15);color:#7c3aed}
.op-badge--online{background:rgba(52,211,153,.15);color:#059669}
.op-badge--offline{background:rgba(248,113,113,.12);color:#dc2626}
.op-dot{width:7px;height:7px;border-radius:50%;flex-shrink:0}
.op-dot--online{background:var(--green);box-shadow:0 0 4px var(--green-glow)}
.op-dot--offline{background:var(--gray-300)}
"""

# Inject CSS before closing </style>
if '.op-card' not in src:
    src = src.replace('</style>', operator_css + '</style>', 1)
    print("  CSS injected")

# ── JS to fetch and render operator cards ─────────────────────────────────────
operator_js = """
/* ═══ OPERATOR CARDS ═══ */
async function refreshOperators() {
  const d = await prismFetch('/api/prism/operators');
  if (!d) return;
  const container = document.getElementById('op-cards-list');
  if (!container) return;
  const countEl = document.getElementById('op-online-count');
  if (countEl) countEl.textContent = d.online + '/' + d.total;

  const ICONS = {
    intelligence: 'RI', sales: 'QT', executive: 'AU',
    inbound: 'SC', engineering: 'JP'
  };
  const INITIALS = {
    'recon':'RC','scout':'SC','quote':'QT','chief':'CH',
    'aurelia':'AU','debrief':'DB','competition-researcher':'CR','jr-programmer':'JP'
  };

  container.innerHTML = d.operators.map(op => {
    const online = op.status !== 'offline';
    const icon = INITIALS[op.id] || op.name.slice(0,2).toUpperCase();
    const catCls = 'op-icon--' + (op.category || 'intelligence');
    const dotCls = online ? 'op-dot--online' : 'op-dot--offline';
    const statBadge = op.op_status === 'production'
      ? '<span class="op-badge op-badge--production">production</span>'
      : '<span class="op-badge op-badge--beta">beta</span>';
    const onlineBadge = online
      ? '<span class="op-badge op-badge--online">online</span>'
      : '<span class="op-badge op-badge--offline">offline</span>';
    const href = online && op.ui_url ? op.ui_url : '#';
    const target = online && op.ui_url ? ' target="_blank"' : '';
    return `<a class="op-card" href="${href}"${target}>
      <div class="op-icon ${catCls}">${icon}</div>
      <div class="op-body">
        <div class="op-name">${op.name}</div>
        <div class="op-desc">${op.description ? op.description.slice(0,52) + (op.description.length>52?'…':'') : ''}</div>
        <div class="op-badges">${statBadge}${onlineBadge}</div>
      </div>
      <div class="op-dot ${dotCls}"></div>
    </a>`;
  }).join('');
}
"""

if 'refreshOperators' not in src:
    # Insert before startLivePoll
    src = src.replace(
        'function startLivePoll() {',
        operator_js + '\nfunction startLivePoll() {'
    )
    print("  JS injected")

# ── HTML — add operator section to sidebar ────────────────────────────────────
# The sidebar list div — inject after the existing sidebar__list content
op_html_anchor = '<div class="sidebar__footer">'
op_section_html = """<div id="op-section" style="border-top:1px solid var(--gray-200);margin-top:4px">
  <div class="op-section">Operators <span class="op-count" id="op-online-count">…</span></div>
  <div id="op-cards-list"></div>
</div>
"""

if 'op-cards-list' not in src:
    src = src.replace(op_html_anchor, op_section_html + op_html_anchor, 1)
    print("  HTML operator section injected")

# ── Wire up to init ────────────────────────────────────────────────────────────
# Call refreshOperators in the init block and set interval
old_init_end = "  await refreshCells();\n  setInterval(refreshCells, POLL);\n  startLivePoll();"
new_init_end = "  await refreshCells();\n  setInterval(refreshCells, POLL);\n  startLivePoll();\n  await refreshOperators();\n  setInterval(refreshOperators, 15000);"

if 'refreshOperators()' not in src:
    if old_init_end in src:
        src = src.replace(old_init_end, new_init_end)
        print("  init wired")
    else:
        print("  WARNING: could not find init block — wire manually")

# Fix stale version in title
src = re.sub(r'PRISM — Cascadia OS v0\.\d+', 'PRISM — Cascadia OS', src)
src = re.sub(r"Health Report — Cascadia OS v0\.\d+", "Health Report — Cascadia OS", src)

p.write_text(src)
print("  prism.html saved")
PYEOF

# ── 3. SwiftBar plugin ────────────────────────────────────────────────────────
echo "[3/3] Creating SwiftBar menu bar plugin"

mkdir -p "$REPO/tools/swiftbar"

cat > "$REPO/tools/swiftbar/cascadia.1m.sh" << 'SWIFTBAR'
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
SWIFTBAR

chmod +x "$REPO/tools/swiftbar/cascadia.1m.sh"
echo "  SwiftBar plugin created: tools/swiftbar/cascadia.1m.sh"

# ── SwiftBar install instructions ─────────────────────────────────────────────
cat > "$REPO/tools/swiftbar/README.md" << 'EOF'
# Cascadia OS — SwiftBar Menu Bar Plugin

Shows live Cascadia OS status in your Mac menu bar with one-click controls.

## Install

1. Install SwiftBar: https://swiftbar.app (free, open source)
2. When SwiftBar asks for a plugin folder, choose or create `~/swiftbar-plugins/`
3. Copy the plugin:
   ```bash
   mkdir -p ~/swiftbar-plugins
   cp ~/cascadia-os/tools/swiftbar/cascadia.1m.sh ~/swiftbar-plugins/
   ```
4. SwiftBar auto-detects the plugin — Cascadia status appears in menu bar immediately

## What you'll see

```
⬡ 11/11          ← component count in menu bar
---
✓ Cascadia OS — running
  Components: 11/11
✓ LLM — zyrcon-ai-v0.1

Operators
  ✓ RECON          → opens dashboard
  ✓ QUOTE          → opens dashboard
  ✓ CHIEF          → opens dashboard
  ○ Aurelia — offline

Quick Actions
  Open PRISM Dashboard
  Run Demo
  Stop Cascadia OS

⚡ 1 approval waiting  ← if any pending
```

## Refresh rate

The `1m` in the filename means SwiftBar refreshes every 1 minute.
To change: rename to `cascadia.30s.sh` for 30 seconds.
EOF

echo "  README.md created"
echo ""
echo "═══════════════════════════════════════════════════"
echo " Done."
echo "═══════════════════════════════════════════════════"
echo ""
echo " PRISM operator cards: restart Cascadia to see them"
echo ""
echo " SwiftBar install:"
echo "   1. Install SwiftBar: https://swiftbar.app"
echo "   2. mkdir -p ~/swiftbar-plugins"
echo "   3. cp tools/swiftbar/cascadia.1m.sh ~/swiftbar-plugins/"
echo "   4. Cascadia appears in menu bar immediately"
echo ""
