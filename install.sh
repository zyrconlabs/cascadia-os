#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Cascadia OS — One-Click Installer  (Mac & Linux)
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/zyrconlabs/cascadia-os/main/install.sh | bash
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO="zyrconlabs/cascadia-os"   # ← replace with your GitHub username/repo
BRANCH="main"
INSTALL_DIR="$HOME/cascadia-os"
VENV_DIR="$INSTALL_DIR/.venv"
MIN_PYTHON="3.11"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[cascadia]${NC} $*"; }
success() { echo -e "${GREEN}[cascadia]${NC} $*"; }
warn()    { echo -e "${YELLOW}[cascadia]${NC} $*"; }
die()     { echo -e "${RED}[cascadia] ERROR:${NC} $*" >&2; exit 1; }

echo ""
echo "  ╔══════════════════════════════════════╗"
echo "  ║       Cascadia OS v0.34 Installer     ║"
echo "  ╚══════════════════════════════════════╝"
echo ""


# ── 0. Mac prerequisites — Homebrew and SwiftBar ──────────────────────────────
if [[ "$(uname)" == "Darwin" ]]; then
    # Install Homebrew if not present
    if ! command -v brew &>/dev/null; then
        info "Homebrew not found — installing..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        # Add brew to PATH for Apple Silicon and Intel
        if [[ -f "/opt/homebrew/bin/brew" ]]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
        elif [[ -f "/usr/local/bin/brew" ]]; then
            eval "$(/usr/local/bin/brew shellenv)"
        fi
        success "Homebrew installed"
    else
        success "Homebrew found: $(brew --version | head -1)"
    fi

    # Install SwiftBar if not present
    if [[ ! -d "/Applications/SwiftBar.app" ]] && [[ ! -d "$HOME/Applications/SwiftBar.app" ]]; then
        info "SwiftBar not found — installing via Homebrew..."
        brew install --cask swiftbar
        success "SwiftBar installed"
    else
        success "SwiftBar found"
    fi

    # Open SwiftBar so it registers and creates its plugin folder
    if [[ ! -d "$HOME/Library/Application Support/SwiftBar/Plugins" ]]; then
        info "Launching SwiftBar to initialise plugin folder..."
        open -a SwiftBar
        sleep 3
    fi
fi

# ── 1. Check Python ───────────────────────────────────────────────────────────
info "Checking Python version..."
PYTHON=""
for cmd in python3.12 python3.11 python3; do
    if command -v "$cmd" &>/dev/null; then
        ver=$("$cmd" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
        major=${ver%%.*}; minor=${ver##*.}
        if [[ $major -ge 3 && $minor -ge 11 ]]; then
            PYTHON="$cmd"
            success "Found Python $ver at $(command -v $cmd)"
            break
        fi
    fi
done

if [[ -z "$PYTHON" ]]; then
    die "Python $MIN_PYTHON+ is required. Install it from https://python.org and re-run this script."
fi

# ── 2. Check Git ──────────────────────────────────────────────────────────────
info "Checking git..."
command -v git &>/dev/null || die "git is required. Install it and re-run."
success "git found."

# ── 3. Clone or update ────────────────────────────────────────────────────────
if [[ -d "$INSTALL_DIR/.git" ]]; then
    info "Existing installation found at $INSTALL_DIR — pulling latest..."
    git -C "$INSTALL_DIR" pull --ff-only origin "$BRANCH"
else
    info "Cloning Cascadia OS into $INSTALL_DIR..."
    git clone --branch "$BRANCH" --depth 1 "https://github.com/$REPO.git" "$INSTALL_DIR"
fi

cd "$INSTALL_DIR"

# ── 4. Virtual environment ────────────────────────────────────────────────────
if [[ ! -d "$VENV_DIR" ]]; then
    info "Creating virtual environment..."
    "$PYTHON" -m venv "$VENV_DIR"
fi
source "$VENV_DIR/bin/activate"
success "Virtual environment ready."

# ── 5. Install package ────────────────────────────────────────────────────────
info "Installing Cascadia OS..."
pip install --quiet --upgrade pip
pip install --quiet -e .
success "Package installed."

# ── 6. Config ─────────────────────────────────────────────────────────────────
if [[ ! -f "$INSTALL_DIR/config.json" ]]; then
    cp "$INSTALL_DIR/config.example.json" "$INSTALL_DIR/config.json"
    warn "config.json created from example. Edit it before starting."
else
    info "config.json already exists — skipping."
fi

# ── 7. First-time setup ───────────────────────────────────────────────────────
info "Running first-time setup (cascadia.installer.once)..."
"$VENV_DIR/bin/python" -m cascadia.installer.once --dir "$INSTALL_DIR"
success "Setup complete."

# ── 8. Launcher script ───────────────────────────────────────────────────────
LAUNCHER="$HOME/.local/bin/cascadia"
mkdir -p "$HOME/.local/bin"
cat > "$LAUNCHER" <<EOF
#!/usr/bin/env bash
source "$VENV_DIR/bin/activate"
exec "$VENV_DIR/bin/python" -m cascadia.kernel.watchdog --config "$INSTALL_DIR/config.json" "\$@"
EOF
chmod +x "$LAUNCHER"

# ── 9. Open PRISM after start hint ──────────────────────────────────────────
info "Starting Cascadia OS..."
source "$VENV_DIR/bin/activate"
nohup "$VENV_DIR/bin/python" -m cascadia.kernel.watchdog --config "$INSTALL_DIR/config.json" > "$INSTALL_DIR/data/logs/watchdog.log" 2>&1 &
sleep 4
if [[ "$(uname)" == "Darwin" ]]; then open "http://127.0.0.1:6300" 2>/dev/null || true; fi


# ── 11. Flint menu bar controller ─────────────────────────────────────────────
PLUGIN_SRC="$INSTALL_DIR/cascadia/flint/cascadia.5s.sh"
chmod +x "$PLUGIN_SRC"

SWIFTBAR_DIR="$HOME/Library/Application Support/SwiftBar/Plugins"
XBAR_DIR="$HOME/Library/Application Support/xbar/plugins"
ARGOS_DIR="$HOME/.config/argos"
INSTALLED_FLINT=false

if [[ "$(uname)" == "Darwin" ]]; then
    if [[ -d "$SWIFTBAR_DIR" ]]; then
        # Symlink — one source of truth, repo changes reflect instantly in SwiftBar
        ln -sf "$PLUGIN_SRC" "$SWIFTBAR_DIR/cascadia.5s.sh"
        chmod +x "$PLUGIN_SRC"
        success "Flint plugin linked → SwiftBar (symlink — no copy needed)"
        INSTALLED_FLINT=true
    elif [[ -d "$XBAR_DIR" ]]; then
        ln -sf "$PLUGIN_SRC" "$XBAR_DIR/cascadia.5s.sh"
        chmod +x "$PLUGIN_SRC"
        success "Flint plugin linked → xbar (symlink)"
        INSTALLED_FLINT=true
    fi
    if [[ "$INSTALLED_FLINT" = false ]]; then
        echo ""
        info "Menu bar controller (Flint) not auto-installed."
        echo "  Install SwiftBar: brew install swiftbar"
        echo "  Then run: bash install.sh   (it will auto-link on next run)"
        echo "  Or link manually:"
        echo "    mkdir -p \"$SWIFTBAR_DIR\""
        echo "    ln -sf \"$PLUGIN_SRC\" \"$SWIFTBAR_DIR/cascadia.5s.sh\""
        echo "  Or run without SwiftBar: python -m cascadia.flint.tray"
    fi
elif [[ "$(uname)" == "Linux" ]]; then
    if [[ -d "$ARGOS_DIR" ]]; then
        ln -sf "$PLUGIN_SRC" "$ARGOS_DIR/cascadia.5s.sh"
        chmod +x "$PLUGIN_SRC"
        success "Flint plugin linked → Argos (symlink)"
        INSTALLED_FLINT=true
    fi
    if [[ "$INSTALLED_FLINT" = false ]]; then
        echo ""
        info "Menu bar controller not auto-installed."
        echo "  Install Argos (GNOME) or link manually:"
        echo "    ln -sf \"$PLUGIN_SRC\" ~/.config/argos/cascadia.5s.sh"
        echo "  Or run: python -m cascadia.flint.tray"
    fi
fi


# ── 12. Auto-start on login (launchd + SwiftBar login item) ───────────────────
if [[ "$(uname)" == "Darwin" ]]; then
    PLIST_DIR="$HOME/Library/LaunchAgents"
    PLIST_PATH="$PLIST_DIR/com.zyrconlabs.cascadia.plist"
    PYTHON_BIN="$(which python3)"
    mkdir -p "$PLIST_DIR"

    cat > "$PLIST_PATH" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.zyrconlabs.cascadia</string>
    <key>ProgramArguments</key>
    <array>
        <string>${PYTHON_BIN}</string>
        <string>-m</string>
        <string>cascadia.kernel.watchdog</string>
        <string>--config</string>
        <string>${INSTALL_DIR}/config.json</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${INSTALL_DIR}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${INSTALL_DIR}/data/logs/flint.log</string>
    <key>StandardErrorPath</key>
    <string>${INSTALL_DIR}/data/logs/flint.log</string>
</dict>
</plist>
PLIST

    # Unload old agent if present, load new one
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    launchctl load "$PLIST_PATH" 2>/dev/null && \
        success "Cascadia registered as login agent — starts automatically at boot" || \
        info "launchctl load failed — run manually: launchctl load $PLIST_PATH"

    # Add SwiftBar to Login Items so it auto-launches at boot
    # Find SwiftBar — check common locations
    SWIFTBAR_APP=""
    for candidate in "/Applications/SwiftBar.app" "$HOME/Applications/SwiftBar.app"; do
        if [[ -d "$candidate" ]]; then
            SWIFTBAR_APP="$candidate"
            break
        fi
    done
    if [[ -z "$SWIFTBAR_APP" ]]; then
        SWIFTBAR_APP=$(mdfind "kMDItemCFBundleIdentifier == 'com.ameba.SwiftBar'" 2>/dev/null | head -1)
    fi

    if [[ -n "$SWIFTBAR_APP" ]]; then
        osascript << APPLESCRIPT 2>/dev/null && \
            success "SwiftBar added to Login Items — launches automatically at boot" || \
            info "Could not add SwiftBar to Login Items — add manually in System Settings → General → Login Items"
tell application "System Events"
    if not (exists login item "SwiftBar") then
        make new login item at end of login items with properties ¬
            {name:"SwiftBar", path:"${SWIFTBAR_APP}", hidden:false}
    end if
end tell
APPLESCRIPT
    else
        info "SwiftBar not found — install with: brew install swiftbar"
        info "Then run install.sh again to register it as a login item"
    fi
fi

# ── 10. Done ──────────────────────────────────────────────────────────────────
echo ""
success "════════════════════════════════════════"
success " Cascadia OS v0.34 installed successfully"
success "════════════════════════════════════════"
echo ""
echo "  Start:   cascadia"
echo "  Config:  $INSTALL_DIR/config.json"
echo "  Logs:    $INSTALL_DIR/logs/"
echo ""
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
    for profile in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
        if [[ -f "$profile" ]] && ! grep -q ".local/bin" "$profile"; then
            echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> "$profile"
            info "Added ~/.local/bin to $profile"
            break
        fi
    done
    export PATH="$HOME/.local/bin:$PATH"
fi
