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
