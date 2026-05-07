#!/bin/bash
set -e

echo "=== IronClaw Install for DGX Spark ==="

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LITELLM_CONFIG="$REPO_DIR/ironclaw/litellm/litellm_config.yaml"
RECIPES_DIR="$REPO_DIR/recipes"

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
# If .env already exists, reuse the existing key
if [ -f ~/.ironclaw/.env ]; then
    EXISTING=$(grep '^SECRETS_MASTER_KEY=' ~/.ironclaw/.env | cut -d= -f2)
    [ -n "$EXISTING" ] && SECRETS_KEY="$EXISTING"
fi

cat > ~/.ironclaw/.env << EOF
DATABASE_URL=postgres://${DB_USER}:${DB_PASS}@localhost:5432/${DB_NAME}?sslmode=disable
DATABASE_BACKEND=postgres
SECRETS_MASTER_KEY=${SECRETS_KEY}
TELEGRAM_BOT_TOKEN=${TELEGRAM_TOKEN}
LLM_BACKEND=openai_compatible
LLM_BASE_URL=http://127.0.0.1:4000/v1
LLM_API_KEY=sk-no-key
LLM_MODEL=${HF_MODEL}
ONBOARD_COMPLETED=true
CLI_MODE=plain
EOF
chmod 600 ~/.ironclaw/.env

# 5. Run once to apply DB migrations, then stop
echo "--- Applying migrations ---"
export $(grep -v '^#' ~/.ironclaw/.env | xargs)
# Run briefly to create schema; --no-onboard skips the wizard
timeout 15 ironclaw run --no-onboard 2>/dev/null || true

# 6. Configure DB settings (settings table requires user_id column)
echo "--- Configuring DB settings ---"
DB_URL="postgres://${DB_USER}:${DB_PASS}@localhost:5432/${DB_NAME}?sslmode=disable"
psql "$DB_URL" << SQLEOF
INSERT INTO settings (user_id, key, value) VALUES
  ('default', 'llm_backend',              '"openai_compatible"'),
  ('default', 'llm_base_url',             '"http://127.0.0.1:4000/v1"'),
  ('default', 'llm_model',                '"${HF_MODEL}"'),
  ('default', 'selected_model',           '"${DEFAULT_MODEL}"'),
  ('default', 'channels.cli_enabled',     'false'),
  ('default', 'channels.cli_mode',        '"plain"'),
  ('default', 'channels.wasm_channels',   '["telegram"]'),
  ('default', 'channels.wasm_channels_enabled', 'true'),
  ('default', 'telegram_bot_token',       '"${TELEGRAM_TOKEN}"'),
  ('default', 'telegram_allow_from',      '["${TELEGRAM_USER_ID}"]'),
  ('default', 'telegram_polling_enabled', 'true'),
  ('default', 'activated_channels',       '["telegram"]')
ON CONFLICT (user_id, key) DO UPDATE SET value = EXCLUDED.value;
SQLEOF

# 7. Install WASM channels
echo "--- Installing WASM channels ---"
mkdir -p ~/.ironclaw/channels
ironclaw registry install telegram 2>/dev/null || \
    echo "Install telegram.wasm manually into ~/.ironclaw/channels/"

# Fix: Enable polling in telegram.capabilities.json
# (default is False, must be True for IronClaw to connect to Telegram)
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


# 8. Systemd service
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

echo ""
echo "=== IronClaw installed ==="
echo "Wait 10 seconds and send a message to your Telegram bot."
echo "You will receive a pairing code. Then run:"
echo "  ironclaw pairing approve telegram <CODE>"
