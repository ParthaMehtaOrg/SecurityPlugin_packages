#!/usr/bin/env bash
set -euo pipefail

# ─── SecurityPlugin + OpenClaw automated uninstaller ───
# Run from anywhere:
#   chmod +x uninstall.sh && ./uninstall.sh

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*"; exit 1; }

# ── Remove SecurityPlugin plugin ──
remove_plugin() {
  echo ""
  echo -e "${CYAN}═══ Remove SecurityPlugin ═══${NC}"

  PLUGIN_DIR="$HOME/.openclaw/extensions/security-plugin"
  if [ -d "$PLUGIN_DIR" ]; then
    rm -rf "$PLUGIN_DIR"
    ok "Removed $PLUGIN_DIR"
  else
    warn "Plugin directory not found — already removed"
  fi
}

# ── Clean openclaw.json ──
clean_config() {
  echo ""
  echo -e "${CYAN}═══ Clean openclaw.json ═══${NC}"

  CFG_PATH="$HOME/.openclaw/openclaw.json"
  if [ ! -f "$CFG_PATH" ]; then
    warn "openclaw.json not found — skipping config cleanup"
    return
  fi

  python3 -c "
import json, os
cfg_path = os.path.expanduser('~/.openclaw/openclaw.json')
with open(cfg_path) as f:
    cfg = json.load(f)
changed = False
if 'tools' in cfg and 'deny' in cfg['tools']:
    for t in ('read', 'exec'):
        if t in cfg['tools']['deny']:
            cfg['tools']['deny'].remove(t)
            changed = True
    if not cfg['tools']['deny']: del cfg['tools']['deny']
    if not cfg['tools']: del cfg['tools']
if 'plugins' in cfg and 'allow' in cfg['plugins']:
    if 'security-plugin' in cfg['plugins']['allow']:
        cfg['plugins']['allow'].remove('security-plugin')
        changed = True
    if not cfg['plugins']['allow']: del cfg['plugins']['allow']
    if not cfg['plugins']: del cfg['plugins']
if changed:
    with open(cfg_path, 'w') as f:
        json.dump(cfg, f, indent=2)
        f.write('\n')
    print('openclaw.json cleaned')
else:
    print('openclaw.json already clean')
"
  ok "openclaw.json restored"
}

# ── Restart gateway ──
restart_gateway() {
  echo ""
  echo -e "${CYAN}═══ Restart Gateway ═══${NC}"

  if command -v openclaw &>/dev/null; then
    info "Restarting gateway to apply changes..."
    openclaw gateway restart
    ok "Gateway restarted"
  else
    warn "openclaw not found — skipping gateway restart"
  fi
}

# ── Optionally remove OpenClaw entirely ──
remove_openclaw() {
  echo ""
  echo -e "${YELLOW}Do you also want to fully remove OpenClaw? (y/N)${NC}"
  read -r REPLY
  if [[ "$REPLY" =~ ^[Yy]$ ]]; then
    echo ""
    echo -e "${CYAN}═══ Remove OpenClaw ═══${NC}"

    if command -v openclaw &>/dev/null; then
      info "Stopping gateway..."
      openclaw gateway stop || warn "Gateway stop returned non-zero"
    fi

    info "Uninstalling openclaw package..."
    if command -v npm &>/dev/null; then
      npm uninstall -g openclaw || warn "npm uninstall returned non-zero"
    elif command -v pnpm &>/dev/null; then
      pnpm remove -g openclaw || warn "pnpm remove returned non-zero"
    else
      warn "Neither npm nor pnpm found — could not uninstall openclaw package"
    fi

    info "Removing ~/.openclaw directory..."
    rm -rf "$HOME/.openclaw"
    ok "OpenClaw fully removed"
  else
    info "Keeping OpenClaw installed"
  fi
}

# ── Summary ──
print_summary() {
  echo ""
  echo -e "${GREEN}════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  SecurityPlugin uninstall complete!${NC}"
  echo -e "${GREEN}════════════════════════════════════════════${NC}"
  echo ""
}

# ── Main ──
main() {
  echo ""
  echo -e "${CYAN}╔══════════════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║   SecurityPlugin + OpenClaw Automated Uninstaller║${NC}"
  echo -e "${CYAN}╚══════════════════════════════════════════════════╝${NC}"

  remove_plugin
  clean_config
  restart_gateway
  remove_openclaw
  print_summary
}

main "$@"
