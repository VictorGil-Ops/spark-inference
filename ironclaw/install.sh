#!/bin/bash
set -e

echo "=== IronClaw Install for DGX Spark ==="

DB_USER="ironclaw_user"
DB_PASS="ironclaw"
DB_NAME="ironclaw"
TELEGRAM_TOKEN="${1:-}"
TELEGRAM_USER_ID="${2:-}"

if [ -z "$TELEGRAM_TOKEN" ] || [ -z "$TELEGRAM_USER_ID" ]; then
    echo "Usage: ./install.sh <telegram_bot_token> <telegram_user_id>"
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
LLM_BASE_URL=http://127.0.0.1:8000/v1
LLM_API_KEY=sk-no-key
LLM_MODEL=nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-NVFP4
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
  ('default', 'llm_base_url',             '"http://127.0.0.1:8000/v1"'),
  ('default', 'llm_model',                '"nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-NVFP4"'),
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
