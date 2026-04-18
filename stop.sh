#!/bin/bash
echo "Stopping Cascadia OS stack..."
pkill -f "cascadia.kernel.watchdog" 2>/dev/null && echo "✓ Cascadia OS stopped" || true
pkill -f "recon_worker" 2>/dev/null && echo "✓ RECON stopped" || true
pkill -f "operators/QUOTE/dashboard" 2>/dev/null && echo "✓ QUOTE stopped" || true
pkill -f "operators/CHIEF/dashboard" 2>/dev/null && echo "✓ CHIEF stopped" || true
lsof -ti :8080 | xargs kill -9 2>/dev/null && echo "✓ llama.cpp stopped" || true
echo "Done."
