#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# Cascadia OS — single-source version patch
# After this: edit version ONLY in pyproject.toml — everything else auto-reads it
#
# Run from repo root: bash apply-version-autoupdate.sh
# ═══════════════════════════════════════════════════════════════════════════════
set -e
REPO="$(cd "$(dirname "$0")" && pwd)"

if [[ ! -f "$REPO/cascadia/kernel/flint.py" ]]; then
  echo "ERROR: Run from inside your cascadia-os repo."
  exit 1
fi

echo "Implementing single-source version from pyproject.toml"
echo ""

python3 - <<'PYEOF'
import pathlib, re

# ── 1. cascadia/__init__.py — central version reader ─────────────────────────
init = pathlib.Path("cascadia/__init__.py")
init.write_text('''\
"""
Cascadia OS
Version is read from pyproject.toml — never hardcode it elsewhere.
"""
import pathlib, re

def _read_version() -> str:
    """Read version from pyproject.toml at repo root."""
    try:
        root = pathlib.Path(__file__).parent.parent
        text = (root / "pyproject.toml").read_text()
        m = re.search(r'^version\\s*=\\s*"([^"]+)"', text, re.MULTILINE)
        return m.group(1) if m else "0.0.0"
    except Exception:
        return "0.0.0"

__version__ = _read_version()
VERSION      = __version__
VERSION_SHORT = ".".join(__version__.split(".")[:2])  # "0.34" from "0.34.0"

__all__ = ["__version__", "VERSION", "VERSION_SHORT"]
''')
print("  cascadia/__init__.py — version reader written")

# ── 2. flint.py — replace hardcoded version strings ──────────────────────────
p = pathlib.Path("cascadia/kernel/flint.py")
src = p.read_text()

# Add import at top
if "from cascadia import VERSION" not in src:
    src = src.replace(
        "from cascadia.shared.config import load_config",
        "from cascadia import VERSION, VERSION_SHORT\nfrom cascadia.shared.config import load_config"
    )
    print("  flint.py — VERSION import added")

# Replace hardcoded version strings in HTTP responses
src = re.sub(r"'version':\s*'0\.\d+(?:\.\d+)?'", "'version': VERSION_SHORT", src)

# Replace log strings
src = re.sub(
    r"(logger\.info\('(?:FLINT ready|Watchdog active)[^']*?)v0\.\d+(?:\.\d+)?",
    r"\1v' + VERSION",
    src
)
# Fix docstring version
src = re.sub(r"(flint\.py — Cascadia OS )v0\.\d+(?:\.\d+)?", r"\1v{VERSION}", src)

p.write_text(src)
print("  flint.py — hardcoded versions replaced with VERSION")

# ── 3. watchdog.py — same treatment ──────────────────────────────────────────
p = pathlib.Path("cascadia/kernel/watchdog.py")
src = p.read_text()

if "from cascadia import VERSION" not in src:
    # Find first import line and add after it
    lines = src.split('\n')
    for i, line in enumerate(lines):
        if line.startswith('from cascadia') or line.startswith('import cascadia'):
            lines.insert(i, 'from cascadia import VERSION')
            break
    else:
        # Add after stdlib imports
        for i, line in enumerate(lines):
            if line.startswith('from cascadia.shared'):
                lines.insert(i, 'from cascadia import VERSION')
                break
    src = '\n'.join(lines)
    print("  watchdog.py — VERSION import added")

# Replace hardcoded version in log strings
src = re.sub(
    r"(Watchdog active - Cascadia OS )v0\.\d+(?:\.\d+)?",
    r"\1v' + VERSION + '",
    src
)
src = re.sub(
    r"(watchdog\.py - Cascadia OS )v0\.\d+(?:\.\d+)?",
    r"\1v{VERSION}",
    src
)

p.write_text(src)
print("  watchdog.py — hardcoded versions replaced")

# ── 4. Verify ─────────────────────────────────────────────────────────────────
print()
print("  Verifying...")
import subprocess, sys
result = subprocess.run(
    [sys.executable, "-c",
     "from cascadia import __version__, VERSION, VERSION_SHORT; "
     "print(f'  __version__ = {__version__}'); "
     "print(f'  VERSION      = {VERSION}'); "
     "print(f'  VERSION_SHORT= {VERSION_SHORT}')"],
    capture_output=True, text=True
)
if result.returncode == 0:
    print(result.stdout.strip())
else:
    print(f"  WARNING: {result.stderr.strip()}")

print()
print("  Done. To bump version: edit pyproject.toml only.")
print("  All version strings update automatically on next start.")
PYEOF

echo ""
echo "═══════════════════════════════════════════════════"
echo " Version autoupdate implemented."
echo "═══════════════════════════════════════════════════"
echo ""
echo " To bump to v0.35:"
echo "   1. Edit pyproject.toml: version = \"0.35.0\""
echo "   2. git add pyproject.toml && git commit -m \"bump: v0.35.0\""
echo "   3. Restart Cascadia — all version strings update automatically"
echo ""
echo " Verify right now:"
echo "   python3 -c \"from cascadia import __version__; print(__version__)\""
echo ""
