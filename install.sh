#!/usr/bin/env bash
set -euo pipefail

# ─── SecurityPlugin + OpenClaw automated installer ───
# This script performs all the steps described in README.md (Steps 1–7).
# Run from within the SecurityPlugin_packages directory:
#   chmod +x install.sh && ./install.sh

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }

# openclaw CLI hangs after completing when plugins keep the Node.js event
# loop alive.  We give the command up to 15s to finish, then force-kill.
oc() {
  openclaw "$@" &
  local pid=$!
  local elapsed=0
  while kill -0 "$pid" 2>/dev/null && [ "$elapsed" -lt 30 ]; do
    sleep 0.5
    elapsed=$((elapsed + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true
    return 0
  fi
  local rc=0
  wait "$pid" 2>/dev/null || rc=$?
  return "$rc"
}

# ── Detect OS ──
detect_os() {
  case "$(uname -s)" in
    Darwin*)  OS="macOS"   ;;
    Linux*)   OS="Linux"   ;;
    MINGW*|MSYS*|CYGWIN*) OS="Windows" ;;
    *) fail "Unsupported operating system: $(uname -s)" ;;
  esac
  info "Detected OS: $OS"
}

# ── Step 1: Install OpenClaw ──
install_openclaw() {
  echo ""
  echo -e "${CYAN}═══ Step 1: Install OpenClaw ═══${NC}"

  if command -v openclaw &>/dev/null; then
    ok "OpenClaw is already installed: $(openclaw --version 2>/dev/null || echo 'unknown version')"
    # Check for updates
    CURRENT=$(openclaw --version 2>/dev/null | tr -d 'v')
    LATEST=$(npm view openclaw version 2>/dev/null)
    if [ -n "$LATEST" ] && [ "$CURRENT" != "$LATEST" ]; then
      warn "OpenClaw update available: v$LATEST (current: v$CURRENT). Run: openclaw update"
    fi
  else
    info "Installing OpenClaw..."
    if command -v npm &>/dev/null; then
      npm install -g openclaw@latest --no-fund 2>&1
    elif command -v pnpm &>/dev/null; then
      pnpm add -g openclaw
    else
      fail "Neither npm nor pnpm found. Please install Node.js >= 22 first."
    fi
    ok "OpenClaw installed: $(openclaw --version 2>/dev/null || echo 'unknown version')"
  fi
}

# ── Step 2: Configure OpenClaw Gateway ──
configure_gateway() {
  echo ""
  echo -e "${CYAN}═══ Step 2: Configure OpenClaw Gateway ═══${NC}"

  info "Setting gateway mode to local..."
  oc config set gateway.mode local || warn "config set returned non-zero (may be fine)"

  info "Installing gateway as LaunchAgent..."
  oc gateway install || warn "Gateway install returned non-zero (may already be installed)"

  info "Restarting gateway..."
  oc gateway restart || warn "Gateway restart returned non-zero (may be fine)"

  info "Checking gateway status..."
  oc gateway status || warn "Could not verify gateway status"
  ok "Gateway configured"
}

# ── Step 3: Configure LLM Provider ──
configure_llm() {
  echo ""
  echo -e "${CYAN}═══ Step 3: Configure LLM Provider ═══${NC}"

  # Skip if a model provider is already configured
  if grep -qE '"(apiKey|api_key|ANTHROPIC_API_KEY|models)"' "$HOME/.openclaw/openclaw.json" 2>/dev/null; then
    ok "LLM provider already configured (found existing provider config)"
    return 0
  fi

  echo -e "${YELLOW}OpenClaw needs an API key for your LLM provider.${NC}"
  echo -e "${YELLOW}The interactive setup wizard will open now.${NC}"
  echo -e "${YELLOW}(If the wizard hangs after completing, press Ctrl-C to continue.)${NC}"
  echo ""

  # Must run in foreground for interactive terminal control
  openclaw configure --section model || true

  info "Restarting gateway to apply provider config..."
  oc gateway restart || warn "Gateway restart returned non-zero"
  ok "LLM provider configured"
}

# ── Steps 4–6: Unzip & Install Plugin ──
install_plugin() {
  echo ""
  echo -e "${CYAN}═══ Steps 4–6: Install SecurityPlugin ═══${NC}"

  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  ZIP_FILE="$SCRIPT_DIR/securityplugin-plugin-${OS}.zip"

  if [ ! -f "$ZIP_FILE" ]; then
    fail "Plugin zip not found: $ZIP_FILE"
  fi

  # Create a temp directory for extraction
  TMPDIR_EXTRACT="$(mktemp -d)"
  trap "rm -rf '$TMPDIR_EXTRACT'" EXIT

  info "Unzipping $ZIP_FILE..."
  unzip -qo "$ZIP_FILE" -d "$TMPDIR_EXTRACT"

  PLUGIN_SRC="$TMPDIR_EXTRACT/securityplugin-plugin-${OS}"
  if [ ! -d "$PLUGIN_SRC" ]; then
    # Some zips extract without the folder wrapper
    PLUGIN_SRC="$TMPDIR_EXTRACT"
  fi

  # Remove legacy security-agent extension if present (renamed to security-plugin)
  OLD_PLUGIN="$HOME/.openclaw/extensions/security-agent"
  if [ -d "$OLD_PLUGIN" ]; then
    info "Removing legacy security-agent plugin (renamed to security-plugin)..."
    rm -rf "$OLD_PLUGIN"
    # Also clean old ID from plugins.allow
    python3 -c "
import json, os
cfg_path = os.path.expanduser('~/.openclaw/openclaw.json')
if os.path.exists(cfg_path):
    with open(cfg_path) as f:
        cfg = json.load(f)
    if 'plugins' in cfg and 'allow' in cfg['plugins'] and 'security-agent' in cfg['plugins']['allow']:
        cfg['plugins']['allow'].remove('security-agent')
        with open(cfg_path, 'w') as f:
            json.dump(cfg, f, indent=2)
            f.write('\n')
" 2>/dev/null || true
    ok "Removed legacy security-agent extension"
  fi

  PLUGIN_DEST="$HOME/.openclaw/extensions/security-plugin"
  info "Installing plugin to $PLUGIN_DEST..."
  mkdir -p "$PLUGIN_DEST"

  cp "$PLUGIN_SRC/index.ts"               "$PLUGIN_DEST/"
  cp "$PLUGIN_SRC/openclaw.plugin.json"    "$PLUGIN_DEST/"
  cp "$PLUGIN_SRC/securityplugin-plugin"   "$PLUGIN_DEST/"
  chmod +x "$PLUGIN_DEST/securityplugin-plugin"

  # Remove macOS quarantine attribute if present
  if [ "$OS" = "macOS" ]; then
    xattr -d com.apple.quarantine "$PLUGIN_DEST/securityplugin-plugin" 2>/dev/null || true
  fi

  ok "Plugin files copied"

  # Patch openclaw.json
  info "Patching openclaw.json..."
  python3 -c "
import json, os
cfg_path = os.path.expanduser('~/.openclaw/openclaw.json')
with open(cfg_path) as f:
    cfg = json.load(f)
cfg.setdefault('tools', {}).setdefault('deny', [])
for t in ('read', 'exec'):
    if t not in cfg['tools']['deny']:
        cfg['tools']['deny'].append(t)
cfg.setdefault('plugins', {}).setdefault('allow', [])
if 'security-plugin' not in cfg['plugins']['allow']:
    cfg['plugins']['allow'].append('security-plugin')
with open(cfg_path, 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
"
  ok "openclaw.json patched (native read/exec denied, security-plugin allowed)"

  # Smoke test
  info "Running smoke tests..."
  if "$PLUGIN_DEST/securityplugin-plugin" --version &>/dev/null; then
    ok "Binary version: $("$PLUGIN_DEST/securityplugin-plugin" --version 2>&1)"
  else
    warn "Binary version check failed — you may have downloaded the wrong OS package"
  fi
}

# ── Step 7: Restart & Verify ──
restart_and_verify() {
  echo ""
  echo -e "${CYAN}═══ Step 7: Restart OpenClaw & Verify ═══${NC}"

  info "Restarting gateway..."
  oc gateway restart || warn "Gateway restart returned non-zero"

  info "Listing plugins..."
  oc plugins list || warn "Could not list plugins"
  ok "Installation complete!"
}

# ── Summary ──
print_summary() {
  echo ""
  echo -e "${GREEN}════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  SecurityPlugin installation complete!${NC}"
  echo -e "${GREEN}════════════════════════════════════════════${NC}"
  echo ""
  echo "  Next steps:"
  echo "    1. Run 'openclaw tui' to open the interactive chat"
  echo "    2. Try: 'Read ~/.env'          — should be BLOCKED"
  echo "    3. Try: 'Read README.md'       — should return content"
  echo "    4. Try: 'Run: cat ~/.env'      — should be BLOCKED"
  echo "    5. Try: 'Run: echo hello'      — should return 'hello'"
  echo ""
}

# ── Main ──
main() {
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║   SecurityPlugin + OpenClaw Automated Installer  ║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"

  detect_os
  install_openclaw
  configure_gateway
  configure_llm
  install_plugin
  restart_and_verify
  print_summary
}

main "$@"
