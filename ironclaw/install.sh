#!/bin/bash
set -e

echo "=== IronClaw Install for DGX Spark ==="

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LITELLM_CONFIG="$REPO_DIR/ironclaw/litellm/litellm_config.yaml"
RECIPES_DIR="$REPO_DIR/recipes"
WORKSPACE_TEMPLATE="$REPO_DIR/ironclaw/workspace"

TELEGRAM_TOKEN="${1:-}"
TELEGRAM_USER_ID="${2:-}"
DB_USER="${3:-ironclaw_user}"
DB_PASS="${4:-ironclaw}"
DB_NAME="ironclaw"

# Default model: first model_name in litellm_config, fallback to arg 5
_first_litellm_model=$(python3 -c "
import re, sys
try:
    m = re.search(r'model_name:\s*(\S+)', open('$LITELLM_CONFIG').read())
    print(m.group(1) if m else '')
except: print('')
" 2>/dev/null)
DEFAULT_MODEL="${5:-${_first_litellm_model}}"

# HF model ID: read from recipe whose port matches the litellm api_base for DEFAULT_MODEL
_hf_model=$(python3 -c "
import re, os, sys
model_name = sys.argv[1]
try:
    raw = open('$LITELLM_CONFIG').read()
    block = re.search(r'model_name:\s*' + re.escape(model_name) + r'.*?api_base:\s*(\S+)', raw, re.DOTALL)
    if not block: sys.exit(0)
    port = re.search(r':(\d+)', block.group(1)).group(1)
    for f in os.listdir('$RECIPES_DIR'):
        if not f.endswith('.yaml'): continue
        r = open(os.path.join('$RECIPES_DIR', f)).read()
        if re.search(r'port:\s*' + port, r):
            m = re.search(r'^model:\s*(.+)', r, re.MULTILINE)
            if m: print(m.group(1).strip()); sys.exit(0)
except: pass
" "$DEFAULT_MODEL" 2>/dev/null)
HF_MODEL="${6:-${_hf_model}}"

if [ -z "$TELEGRAM_TOKEN" ] || [ -z "$TELEGRAM_USER_ID" ]; then
    echo "Usage: ./install.sh <telegram_bot_token> <telegram_user_id> [db_user] [db_pass] [default_model] [hf_model]"
    echo "       Or run: ./setup.sh"
    exit 1
fi

# 1. PostgreSQL
echo "--- Setting up PostgreSQL ---"
sudo apt-get install -y postgresql postgresql-contrib libpq-dev postgresql-server-dev-all
sudo systemctl start postgresql
sudo systemctl enable postgresql
sudo -u postgres psql -c "CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';" 2>/dev/null || true
sudo -u postgres createdb ${DB_NAME} -O ${DB_USER} 2>/dev/null || true
# Disable SSL — ironclaw's Rust driver doesn't handle self-signed certs
sudo -u postgres psql -c "ALTER SYSTEM SET ssl = off;" 2>/dev/null || true
sudo -u postgres psql -c "SELECT pg_reload_conf();" 2>/dev/null || true

# pgvector
if [ ! -d /tmp/pgvector ]; then
    git clone --depth 1 https://github.com/pgvector/pgvector.git /tmp/pgvector
fi
cd /tmp/pgvector && make && sudo make install
psql "postgres://${DB_USER}:${DB_PASS}@localhost:5432/${DB_NAME}?sslmode=disable" \
    -c "CREATE EXTENSION IF NOT EXISTS vector;" 2>/dev/null || true

# 2. Rust
echo "--- Installing Rust ---"
if ! command -v rustc &>/dev/null; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi
source ~/.cargo/env

# 3. IronClaw
echo "--- Building IronClaw ---"
if [ ! -d ~/repos/ironclaw ]; then
    git clone https://github.com/nearai/ironclaw.git ~/repos/ironclaw
fi
cd ~/repos/ironclaw
cargo install --path . --bin ironclaw

# 4. .env — generate SECRETS_MASTER_KEY once, never overwrite
echo "--- Creating .env ---"
mkdir -p ~/.ironclaw
SECRETS_KEY="$(openssl rand -hex 32)"
GATEWAY_TOKEN="$(openssl rand -hex 32)"
# If .env already exists, reuse stable secrets
if [ -f ~/.ironclaw/.env ]; then
    EXISTING_KEY=$(grep '^SECRETS_MASTER_KEY=' ~/.ironclaw/.env | cut -d= -f2)
    EXISTING_GW=$(grep '^GATEWAY_AUTH_TOKEN=' ~/.ironclaw/.env | tr -d '"' | cut -d= -f2)
    [ -n "$EXISTING_KEY" ] && SECRETS_KEY="$EXISTING_KEY"
    [ -n "$EXISTING_GW" ]  && GATEWAY_TOKEN="$EXISTING_GW"
fi

cat > ~/.ironclaw/.env << EOF
DATABASE_URL=postgres://${DB_USER}:${DB_PASS}@localhost:5432/${DB_NAME}?sslmode=disable
DATABASE_BACKEND=postgres
SECRETS_MASTER_KEY=${SECRETS_KEY}
TELEGRAM_BOT_TOKEN=${TELEGRAM_TOKEN}
LLM_BACKEND=openai_compatible
LLM_BASE_URL=http://127.0.0.1:4000/v1
LLM_API_KEY=sk-no-key
LLM_MODEL=${DEFAULT_MODEL}
ONBOARD_COMPLETED=true
CLI_MODE=plain
GATEWAY_AUTH_TOKEN=${GATEWAY_TOKEN}
EOF
chmod 600 ~/.ironclaw/.env

# 5. Workspace — identity and personality files
echo "--- Setting up workspace ---"
mkdir -p ~/.ironclaw/workspace

# Only seed files that don't exist yet — never overwrite user edits
_seed_file() {
    local dst="$1" src="$2"
    if [ ! -f "$dst" ]; then
        if [ -f "$src" ]; then
            cp "$src" "$dst"
            echo "  → seeded $(basename $dst) from template"
        else
            echo "  → creating default $(basename $dst)"
            cat > "$dst"
        fi
    else
        echo "  → $(basename $dst) already exists, skipping"
    fi
}

# IDENTITY.md
_seed_file ~/.ironclaw/workspace/IDENTITY.md \
    "$WORKSPACE_TEMPLATE/IDENTITY.md" << 'IDENTITY_EOF'
# Identity

- **Name:** Sparky
- **Vibe:** direct, sharp, no fluff. Gets to the point.
- **Emoji:** ⚡

## Personality
- Doesn't pad. If the answer is one word, gives one word.
- Has its own opinions. Pushes back when it matters.
- Curious about technology, especially local AI and hardware.
- Informal tone with Victor, more formal in external channels.

## Voice
Speaks in first person. Doesn't constantly introduce itself.
Never says "Sure!", "Of course!", or "As an AI assistant..."
IDENTITY_EOF

# SOUL.md
_seed_file ~/.ironclaw/workspace/SOUL.md \
    "$WORKSPACE_TEMPLATE/SOUL.md" << 'SOUL_EOF'
# Core Values

Be genuinely helpful, not performatively helpful. Skip filler phrases.
Have opinions. Disagree when it matters.
Be resourceful before asking: read the file, check context, search, then ask.
Earn trust through competence. Be careful with external actions, bold with internal ones.
You have access to someone's life. Treat it with respect.

## Boundaries
- Private things stay private. Never leak user context into group chats.
- When in doubt about an external action, ask before acting.
- Prefer reversible actions over destructive ones.
- You are not the user's voice in group settings.

## Autonomy
Start cautious. Ask before taking actions that affect others or the outside world.
Over time, as you demonstrate competence and earn trust, you may:
- Suggest increasing autonomy for specific task types
- Take initiative on internal tasks (memory, notes, organization)
- Ask: "I've been handling X reliably — want me to do Y without asking?"
Never self-promote autonomy without evidence of earned trust.

## Language
Always respond in the same language the user writes in.
Default to English unless told otherwise.
SOUL_EOF

# USER.md
_seed_file ~/.ironclaw/workspace/USER.md \
    "$WORKSPACE_TEMPLATE/USER.md" << USER_EOF
# User

- **Name:** Master
- **Location:** The World
- **Main machine:** sparky-one (DGX Spark GB10)
- **Stack:** Rust, Python, local AI infrastructure
- **Preferences:** direct answers, no padding, no hand-holding

## Context
- Runs local LLM inference on a DGX Spark.
- Uses IronClaw as a personal AI agent via Telegram.
- Manages multiple models through LiteLLM + Atlas/vLLM backends.
- Values efficiency and working setups over explanations of why things are hard.
USER_EOF

# AGENTS.md
_seed_file ~/.ironclaw/workspace/AGENTS.md \
    "$WORKSPACE_TEMPLATE/AGENTS.md" << AGENTS_EOF
# Agents

## Sparky
The primary agent. Personal assistant running on sparky-one.
- Handles day-to-day tasks, questions, and automation via Telegram.
- Has full access to tools: web search, GitHub, Telegram MTProto, LLM context.
- Default model: set via LiteLLM (see `selected_model` in DB).
- Acts cautiously on external actions, autonomously on internal ones.

## Model Roster
Models available through LiteLLM on port 4000:

| Alias           | Model                                      | Backend | Port  |
|-----------------|--------------------------------------------|---------|-------|
| nemotron-nano   | NVIDIA-Nemotron-3-Nano-30B-A3B-NVFP4       | vLLM    | 8000  |
| nemotron-omni   | Nemotron-3-Nano-Omni-30B-A3B-Reasoning     | vLLM    | 8000  |
| qwen36          | Qwen3.6-35B-A3B-FP8                        | vLLM    | 8001  |
| foundation-sec  | Foundation-Sec-8B-Instruct                 | vLLM    | 8002  |
| primus          | Llama-Primus-Reasoning                     | vLLM    | 8002  |
| nemotron-super  | NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4    | vLLM    | 8100  |
| nemotron-nano-w4| nemotron3-nano-nvfp4-w4a16                 | vLLM    | 8004  |
| gemma-4         | Gemma-4-26B-A4B-NVFP4                      | vLLM    | 8200  |

## Switching Models
Use the setup wizard:
```bash
~/repos/spark-inference/ironclaw/setup.sh model
```

## Tool Access
- **web_search** — general search
- **github** — repo access and operations
- **telegram_mtproto** — read Telegram messages and chats
- **llm_context** — inject context into LLM calls
AGENTS_EOF

echo "  ✓ Workspace ready at ~/.ironclaw/workspace/"

# Import workspace files into ironclaw memory
echo "--- Importing workspace into ironclaw memory ---"
for f in IDENTITY.md SOUL.md USER.md AGENTS.md; do
    src="$HOME/.ironclaw/workspace/$f"
    if [ -f "$src" ]; then
        ironclaw memory write "$f" "$(cat "$src")" 2>/dev/null \
            && echo "  → imported $f" \
            || echo "  ! failed $f (will retry on next reset)"
    fi
done

# 6. Run once to apply DB migrations, then stop
echo "--- Applying migrations ---"
export $(grep -v '^#' ~/.ironclaw/.env | xargs)
timeout 15 ironclaw run --no-onboard 2>/dev/null || true

# 7. Configure DB settings
echo "--- Configuring DB settings ---"
DB_URL="postgres://${DB_USER}:${DB_PASS}@localhost:5432/${DB_NAME}?sslmode=disable"
psql "$DB_URL" << SQLEOF
INSERT INTO settings (user_id, key, value) VALUES
  ('default', 'llm_backend',              '"openai_compatible"'),
  ('default', 'llm_base_url',             '"http://127.0.0.1:4000/v1"'),
  ('default', 'llm_model',                '"${DEFAULT_MODEL}"'),
  ('default', 'selected_model',           '"${DEFAULT_MODEL}"'),
  ('default', 'channels.cli_enabled',     'false'),
  ('default', 'channels.cli_mode',        '"plain"'),
  ('default', 'channels.wasm_channels',   '["telegram"]'),
  ('default', 'channels.wasm_channels_enabled', 'true'),
  ('default', 'telegram_bot_token',       '"${TELEGRAM_TOKEN}"'),
  ('default', 'telegram_allow_from',      '["${TELEGRAM_USER_ID}"]'),
  ('default', 'telegram_polling_enabled', 'true'),
  ('default', 'activated_channels',       '["telegram"]'),
  ('default', 'safety.max_output_length',          '100000'),
  ('default', 'skills.max_context_tokens',          '28000'),
  ('default', 'routines.max_lightweight_tokens',    '28000')
ON CONFLICT (user_id, key) DO UPDATE SET value = EXCLUDED.value;
SQLEOF

# 8. Install WASM channels
echo "--- Installing WASM channels ---"
mkdir -p ~/.ironclaw/channels
ironclaw registry install telegram 2>/dev/null || \
    echo "Install telegram.wasm manually into ~/.ironclaw/channels/"

# Enable polling in telegram.capabilities.json
echo "--- Fixing Telegram polling in capabilities.json ---"
python3 -c "
import json, os
path = os.path.expanduser('~/.ironclaw/channels/telegram.capabilities.json')
if os.path.exists(path):
    d = json.load(open(path))
    d['config']['polling_enabled'] = True
    d['config']['webhook_enabled'] = False
    json.dump(d, open(path,'w'), indent=2)
    print('  polling_enabled: True')
else:
    print('  WARNING: telegram.capabilities.json not found')
"

# 9. Systemd service
echo "--- Installing systemd service ---"
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/ironclaw.service << EOF
[Unit]
Description=IronClaw daemon
After=network.target

[Service]
Type=simple
EnvironmentFile=/home/${USER}/.ironclaw/.env
ExecStart=/home/${USER}/.cargo/bin/ironclaw run --no-onboard
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable ironclaw
systemctl --user start ironclaw

# Source .env in shell startup
SHELL_LINE='[ -f "$HOME/.ironclaw/.env" ] && set -a && . "$HOME/.ironclaw/.env" && set +a'
for RC in ~/.bashrc ~/.profile; do
    if [ -f "$RC" ] && ! grep -qF 'ironclaw/.env' "$RC"; then
        if [ "$RC" = "$HOME/.bashrc" ]; then
            sed -i '/^# If not running interactively/i '"$SHELL_LINE"'' "$RC" 2>/dev/null || echo "$SHELL_LINE" >> "$RC"
        else
            echo "$SHELL_LINE" >> "$RC"
        fi
        echo "  Added ironclaw env to $RC"
    fi
done

echo ""
echo "=== IronClaw installed ==="
echo "  Model:     ${DEFAULT_MODEL}"
echo "  Workspace: ~/.ironclaw/workspace/"
echo ""
echo "Wait 10 seconds and send a message to your Telegram bot."
echo "You will receive a pairing code. Then run:"
echo "  ironclaw pairing approve telegram <CODE>"