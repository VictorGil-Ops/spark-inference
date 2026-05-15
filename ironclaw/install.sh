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
    m = re.search(r'model_name:\s*(\S+)', open(sys.argv[1]).read())
    print(m.group(1) if m else '')
except: print('')
" "$LITELLM_CONFIG" 2>/dev/null)
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

# ── 1. PostgreSQL + pgvector ─────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  [1/6] PostgreSQL + pgvector"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if ! systemctl --user is-active --quiet postgresql 2>/dev/null && ! sudo systemctl is-active --quiet postgresql 2>/dev/null; then
    echo "  → Installing PostgreSQL..."
    sudo apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq postgresql postgresql-contrib libpq-dev postgresql-server-dev-all >/dev/null 2>&1
    
    # Start it
    sudo systemctl start postgresql
    sudo systemctl enable postgresql
    
    # Create user + DB
    sudo -u postgres psql -c "CREATE USER ${DB_USER} WITH PASSWORD '${DB_PASS}';" 2>/dev/null || true
    sudo -u postgres createdb ${DB_NAME} -O ${DB_USER} 2>/dev/null || true
    
    # Disable SSL — ironclaw's Rust driver doesn't handle self-signed certs
    sudo -u postgres psql -c "ALTER SYSTEM SET ssl = off;" 2>/dev/null || true
    sudo -u postgres psql -c "SELECT pg_reload_conf();" 2>/dev/null || true
    echo "  ✓ PostgreSQL ready (user: ${DB_USER}, db: ${DB_NAME})"
else
    echo "  ✓ PostgreSQL already installed and running"
fi

# pgvector
echo "  → Checking pgvector..."
if [ ! -d /tmp/pgvector ]; then
    git clone --depth 1 https://github.com/pgvector/pgvector.git /tmp/pgvector 2>/dev/null || true
fi
cd /tmp/pgvector && make -j"$(nproc)" 2>/dev/null && sudo make install 2>/dev/null || echo "  ⚠ pgvector may already be installed"
psql "postgres://${DB_USER}:${DB_PASS}@localhost:5432/${DB_NAME}?sslmode=disable" \
    -c "CREATE EXTENSION IF NOT EXISTS vector;" 2>/dev/null || true
echo "  ✓ pgvector ready"

# ── 2. Rust + LLVM ──────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  [2/6] Rust + llama.cpp"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if ! command -v rustc &>/dev/null; then
    echo "  → Installing Rust..."
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y 2>/dev/null
fi
source ~/.cargo/env

echo "  → Building llama.cpp..."
if [ ! -d ~/repos/llama.cpp ]; then
    git clone https://github.com/ggerganov/llama.cpp.git ~/repos/llama.cpp 2>/dev/null || true
fi
cd ~/repos/llama.cpp
git pull 2>/dev/null || true
mkdir -p build && cd build && cmake .. -DBUILD_SHARED_LIBS=OFF -DLLAMA_CURL=ON 2>/dev/null || true
cmake --build . -j"$(nproc)" 2>/dev/null || echo "  ⚠ llama.cpp may already be built"
echo "  ✓ llama.cpp ready"

# ── 3. LiteLLM ──────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  [3/6] LiteLLM"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "  → Installing LiteLLM..."
pip3 install litellm[proxy] --quiet 2>/dev/null || pip3 install litellm --quiet 2>/dev/null || true
echo "  ✓ pip install done"

# Create LiteLLM config dir
mkdir -p ~/.litellm

# Copy the config
if [ -f "$LITELLM_CONFIG" ]; then
    cp "$LITELLM_CONFIG" ~/.litellm/litellm_config.yaml
    echo "  ✓ LiteLLM config in place"
else
    echo "  ⚠ Warning: $LITELLM_CONFIG not found"
fi

# Systemd service for LiteLLM
echo "  → Creating systemd service..."
cat > ~/.config/systemd/user/litellm.service << EOF
[Unit]
Description=LiteLLM Proxy
After=network.target postgresql-startup.service

[Service]
Type=simple
WorkingDirectory=$REPO_DIR
Environment=HOME=$HOME
Environment=PATH=$PATH
UnsetEnvironment=DATABASE_URL DATABASE_BACKEND
ExecStart=/home/${USER}/.local/bin/litellm --config /home/${USER}/.litellm/litellm_config.yaml
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable litellm 2>/dev/null || true
echo "  ✓ litellm.service installed"

# ── 4. Embeddings (llama.cpp + nomic-embed-text) ────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  [4/6] Embeddings (nomic-embed-text-v1.5)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

EMBED_PORT="${EMBED_PORT:-8010}"
LLAMA_SERVER_PATH="$HOME/repos/llama.cpp/build/bin/llama-server"

# Download GGUF if not present
GGUF_PATH="$HOME/models/embeddings/nomic-embed-text-v1.5-f16.gguf"
if [ ! -f "$GGUF_PATH" ]; then
    echo "  → Downloading nomic-embed-text (~100MB)..."
    mkdir -p "$HOME/models/embeddings"
    
    # Mirror list
    GGUF_URLS=(
        "https://hf-mirror.com/second-state/Nomic-embed-text-v1.5-Embedding-GGUF/resolve/main/nomic-embed-text-v1.5-f16.gguf"
        "https://huggingface.co/second-state/Nomic-embed-text-v1.5-Embedding-GGUF/resolve/main/nomic-embed-text-v1.5-f16.gguf"
    )
    
    for url in "${GGUF_URLS[@]}"; do
        if curl -sfL --connect-timeout 5 --max-time 600 -o "$GGUF_PATH" "$url"; then
            echo "  ✓ Downloaded from $url"
            break
        fi
    done
    
    if [ ! -f "$GGUF_PATH" ]; then
        echo "  ⚠ Download failed — will retry on next startup"
        # Set dummy path so system still starts (just won't embed)
        GGUF_PATH="/tmp/nomic-embed-text-v1.5-f16.gguf"
    fi
fi

# embeddings.conf
mkdir -p ~/.ironclaw
cat > ~/.ironclaw/embeddings.conf << EMBEDCONF
LLAMA_EMBED_MODEL_PATH=${GGUF_PATH}
LLAMA_EMBED_CTX_SIZE=2048
LLAMA_EMBED_PORT=${EMBED_PORT}
LLAMA_EMBED_NGL=35
EMBEDCONF

# llama-embed systemd service
cat > ~/.config/systemd/user/llama-embed.service << EOF
[Unit]
Description=llama-server for embedding (nomic-embed-text)
After=network.target

[Service]
Type=simple
WorkingDirectory=$REPO_DIR
EnvironmentFile=/home/${USER}/.ironclaw/embeddings.conf
Environment=PATH=$PATH
ExecStart=${LLAMA_SERVER_PATH} \\
    --model ${GGUF_PATH} \\
    --ctx-size 2048 \\
    --batch-size 2048 \\
    --ubatch-size 2048 \\
    --port ${EMBED_PORT} \\
    --host 0.0.0.0 \\
    --embedding \\
    -ngl 35
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF

# Start services in dependency order
echo "  → Starting LiteLLM..."
systemctl --user restart litellm
for i in $(seq 1 15); do
    curl -sf http://127.0.0.1:4000/v1/models >/dev/null 2>&1 && break
    sleep 1
done
systemctl --user is-active --quiet litellm && echo "  ✓ LiteLLM running on port 4000" || echo "  ⚠ LiteLLM check timed out (may need restart)"

echo "  → Starting embedding server..."
systemctl --user start llama-embed 2>/dev/null || true
systemctl --user enable llama-embed 2>/dev/null || true
systemctl --user daemon-reload
for i in $(seq 1 10); do
    curl -sf http://127.0.0.1:${EMBED_PORT}/embeddings >/dev/null 2>&1 && break
    sleep 1
done
systemctl --user is-active --quiet llama-embed && echo "  ✓ Embedding server running on port ${EMBED_PORT}" || echo "  ⚠ Embedding server not responding yet (may need restart)"

# ── 5. IronClaw ────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  [5/6] IronClaw"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "  → Building/instaling IronClaw..."
if [ ! -d ~/repos/ironclaw ]; then
    git clone https://github.com/nearai/ironclaw.git ~/repos/ironclaw
fi
cd ~/repos/ironclaw
cargo install --path . --bin ironclaw 2>/dev/null || \
    cargo install --path . --force --bin ironclaw 2>/dev/null || \
    echo "  ⚠ IronClaw may already be installed"
echo "  ✓ ironclaw binary ready"

# .env — generate SECRETS_MASTER_KEY once, never overwrite
echo "  → Creating .env..."
mkdir -p ~/.ironclaw
SECRETS_KEY="$(openssl rand -hex 32)"
GATEWAY_TOKEN="$(openssl rand -hex 32)"
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
ALLOW_LOCAL_TOOLS=true
GATEWAY_AUTH_TOKEN=${GATEWAY_TOKEN}
OPENAI_API_KEY=sk-no-key
EMBEDDING_ENABLED=true
EMBEDDING_PROVIDER=openai
EMBEDDING_BASE_URL=http://127.0.0.1:${EMBED_PORT}
EMBEDDING_MODEL=nomic-embed-text-v1.5-f16.gguf
EMBEDDING_DIM=768
EOF
chmod 600 ~/.ironclaw/.env
echo "  ✓ .env created"

# ── Onboarding questionnaire ──────────────────────────────────────────────────
run_onboarding() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Agent Onboarding"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Customize your agent now, or skip and edit the"
    echo "  workspace .md files manually later."
    echo ""
    echo "  [Y] Run onboarding questionnaire"
    echo "  [n] Skip"
    echo ""
    printf "  Select: "
    read -r do_onboard
    [[ "${do_onboard,,}" == "n" ]] && echo "  Skipped. Edit ~/.ironclaw/workspace/ to customize." && return

    echo ""

    # Agent name
    printf "  Agent name [Sparky]: "
    read -r AGENT_NAME
    AGENT_NAME="${AGENT_NAME:-Sparky}"

    # User name
    printf "  Your name: "
    read -r USER_NAME
    USER_NAME="${USER_NAME:-User}"

    # Location
    printf "  Your location (city, country): "
    read -r USER_LOCATION
    USER_LOCATION="${USER_LOCATION:-Unknown}"

    # Role selection
    echo ""
    echo "  Select agent role:"
    echo "    [1] Personal Assistant  — reminders, notes, news, system monitoring"
    echo "    [2] Software Developer  — coding, architecture, GitHub, shell"
    echo "    [3] AI/ML Engineer      — models, experiments, inference infrastructure"
    echo "    [4] Security Researcher — threat analysis, foundation-sec, primus"
    echo "    [5] Researcher          — papers, synthesis, long-context, rigor"
    echo ""
    printf "  Select role [1]: "
    read -r ROLE_SEL
    ROLE_SEL="${ROLE_SEL:-1}"

    case "$ROLE_SEL" in
        1) ROLE="personal-assistant" ; DEFAULT_MODEL="gemma-4" ;;
        2) ROLE="developer"          ; DEFAULT_MODEL="qwen36" ;;
        3) ROLE="ml-engineer"        ; DEFAULT_MODEL="nemotron-super" ;;
        4) ROLE="security"           ; DEFAULT_MODEL="foundation-sec" ;;
        5) ROLE="researcher"         ; DEFAULT_MODEL="nemotron-super" ;;
        *) ROLE="personal-assistant" ; DEFAULT_MODEL="gemma-4" ;;
    esac

    # Preferred language
    echo ""
    echo "  Preferred language:"
    echo "    [1] English"
    echo "    [2] Spanish"
    echo "    [3] Other (you'll edit SOUL.md manually)"
    echo ""
    printf "  Select [1]: "
    read -r LANG_SEL
    case "${LANG_SEL:-1}" in
        2) PREFERRED_LANG="Spanish" ;;
        3) PREFERRED_LANG="your preferred language" ;;
        *) PREFERRED_LANG="English" ;;
    esac

    echo ""
    echo "  Summary:"
    echo "    Agent:    $AGENT_NAME"
    echo "    User:     $USER_NAME"
    echo "    Location: $USER_LOCATION"
    echo "    Role:     $ROLE"
    echo "    Model:    $DEFAULT_MODEL"
    echo "    Language: $PREFERRED_LANG"
    echo ""
    printf "  Apply? [Y/n]: "
    read -r confirm
    [[ "${confirm,,}" == "n" ]] && echo "  Aborted." && return

    # Apply role .md files to workspace
    ROLE_DIR="$REPO_DIR/ironclaw/roles/$ROLE"
    if [ -d "$ROLE_DIR" ]; then
        for f in SOUL.md AGENTS.md HEARTBEAT.md; do
            src="$ROLE_DIR/$f"
            dst="$HOME/.ironclaw/workspace/$f"
            if [ -f "$src" ]; then
                sed "s/{{AGENT_NAME}}/$AGENT_NAME/g" "$src" > "$dst"
                echo "  → applied $f from role $ROLE"
            fi
        done
    else
        echo "  ! Role directory not found: $ROLE_DIR — using base workspace"
    fi

    # Update USER.md with real values
    cat > "$HOME/.ironclaw/workspace/USER.md" << USEREOF
# User

- **Name:** ${USER_NAME}
- **Location:** ${USER_LOCATION}
- **Main machine:** $(hostname) (DGX Spark GB10)
- **Stack:** Rust, Python, local AI infrastructure
- **Preferences:** direct answers, no padding, no hand-holding

## Context
- Runs local LLM inference on a DGX Spark.
- Uses IronClaw as a personal AI agent via Telegram.
- Agent role: ${ROLE}
- Preferred language: ${PREFERRED_LANG}
USEREOF
    echo "  → updated USER.md"

    # Update IDENTITY.md with agent name
    cat > "$HOME/.ironclaw/workspace/IDENTITY.md" << IDENTEOF
# Identity

- **Name:** ${AGENT_NAME}
- **Vibe:** direct, sharp, no fluff. Gets to the point.
- **Emoji:** ⚡
- **Role:** ${ROLE}

## Personality
- Doesn't pad. If the answer is one word, gives one word.
- Has its own opinions. Pushes back when it matters.
- Responds in ${PREFERRED_LANG} by default.
IDENTEOF
    echo "  → updated IDENTITY.md"

    # Set default model in DB
    if [ -n "$DEFAULT_MODEL" ]; then
        DB_URL="postgres://${DB_USER}:${DB_PASS}@localhost:5432/${DB_NAME}?sslmode=disable"
        psql "$DB_URL" -c "
            INSERT INTO settings (user_id, key, value)
            VALUES ('default', 'selected_model', '\"${DEFAULT_MODEL}\"')
            ON CONFLICT (user_id, key) DO UPDATE SET value = '\"${DEFAULT_MODEL}\"';
        " > /dev/null 2>&1 && echo "  → default model set to $DEFAULT_MODEL" || true
    fi

    echo ""
    echo "  ✓ Onboarding complete"
}

# Workspace — identity and personality files
echo "  → Setting up workspace..."
mkdir -p ~/.ironclaw/workspace

_seed_file() {
    local dst="$1" src="$2"
    if [ ! -f "$dst" ]; then
        if [ -f "$src" ]; then
            cp "$src" "$dst"
            echo "    → seeded $(basename $dst)"
        else
            echo "    → creating default $(basename $dst)"
            cat > "$dst"
        fi
    else
        echo "    → $(basename $dst) exists, keeping"
    fi
}

_seed_file ~/.ironclaw/workspace/IDENTITY.md "$WORKSPACE_TEMPLATE/IDENTITY.md" << 'IDENTITY_EOF'
# Identity

- **Name:** Sparky
- **Vibe:** direct, sharp, no fluff. Gets to the point.
- **Emoji:** ⚡

## Personality
- Doesn't pad. If the answer is one word, gives one word.
- Has its own opinions. Pushes back when it matters.
- Curious about technology, especially local AI and hardware.
- Informal tone with User, more formal in external channels.

## Voice
Speaks in first person. Doesn't constantly introduce itself.
Never says "Sure!", "Of course!", or "As an AI assistant..."
IDENTITY_EOF

_seed_file ~/.ironclaw/workspace/SOUL.md "$WORKSPACE_TEMPLATE/SOUL.md" << 'SOUL_EOF'
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

_seed_file ~/.ironclaw/workspace/USER.md "$WORKSPACE_TEMPLATE/USER.md" << USER_EOF
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

_seed_file ~/.ironclaw/workspace/AGENTS.md "$WORKSPACE_TEMPLATE/AGENTS.md" << AGENTS_EOF
# Agents

## Sparky
The primary agent. Personal assistant running on sparky-one.
- Handles day-to-day tasks, questions, and automation via Telegram.
- Has full access to tools: web search, GitHub, Telegram MTProto, LLM context.
- Default model: set via LiteLLM (see \`selected_model\` in DB).
- Acts cautiously on external actions, autonomously on internal ones.

## Model Roster
Models available through LiteLLM on port 4000:
$(python3 -c "
import re
yaml_content = open('$LITELLM_CONFIG').read()
patterns = re.findall(r'model_name:\s*(\S+).*?api_base:\s*http://\d+\.\d+\.\d+\.\d+:(\d+)', yaml_content, re.DOTALL)
for alias, port in patterns:
    print(f'- {alias} (port {port})')
")

## Switching Models
Use the setup wizard:
\`\`\`bash
~/repos/spark-inference/ironclaw/setup.sh model
\`\`\`

## Tool Access
- **web_search** — general search
- **github** — repo access and operations
- **telegram_mtproto** — read Telegram messages and chats
- **llm_context** — inject context into LLM calls
AGENTS_EOF

echo "  ✓ Workspace ready at ~/.ironclaw/workspace/"
run_onboarding

# ── 6. DB migrations + config + start ────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  [6/6] DB migrations + config + start"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo "  → Applying DB migrations..."
export $(grep -v '^#' ~/.ironclaw/.env | xargs)
timeout 30 ironclaw run --no-onboard 2>/dev/null || true

echo "  → Importing workspace files into memory..."
for f in SOUL.md IDENTITY.md USER.md AGENTS.md; do
    src="$HOME/.ironclaw/workspace/$f"
    if [ -f "$src" ]; then
        ironclaw memory write "$f" "$(cat "$src")" 2>/dev/null \
            && echo "    → imported $f" \
            || echo "    ! $f failed (will retry on restart)"
    fi
done

# Reset MEMORY.md — prevents stale onboarding summaries from overriding identity
ironclaw memory write MEMORY.md "# Memory

No entries yet." 2>/dev/null && echo "    → reset MEMORY.md" || true

# Remove auto-generated profile if it conflicts with USER.md
ironclaw memory write context/profile.json "{}" 2>/dev/null && echo "    → reset context/profile.json" || true

echo "  ✓ Memory initialized"

echo "  → Configuring DB settings..."
DB_URL="postgres://${DB_USER}:${DB_PASS}@localhost:5432/${DB_NAME}?sslmode=disable"
psql "$DB_URL" << SQLEOF
INSERT INTO settings (user_id, key, value) VALUES
  ('default', 'llm_backend',                              '"openai_compatible"'),
  ('default', 'llm_base_url',                             '"http://127.0.0.1:4000/v1"'),
  ('default', 'llm_model',                                '"${DEFAULT_MODEL}"'),
  ('default', 'selected_model',                           '"${DEFAULT_MODEL}"'),
  ('default', 'channels.cli_enabled',                     'false'),
  ('default', 'channels.cli_mode',                        '"plain"'),
  ('default', 'channels.wasm_channels',                   '["telegram"]'),
  ('default', 'channels.wasm_channels_enabled',           'true'),
  ('default', 'telegram_bot_token',                       '"${TELEGRAM_TOKEN}"'),
  ('default', 'telegram_allow_from',                      '["${TELEGRAM_USER_ID}"]'),
  ('default', 'telegram_polling_enabled',                 'true'),
  ('default', 'activated_channels',                       '["telegram"]'),
  ('default', 'tools.allow_local_tools',                  'true'),
  ('default', 'tools.sandbox_workspace_write',            'true'),
  ('default', 'tools.skills_enabled',                     'true'),
  ('default', 'safety.max_output_length',                 '100000'),
  ('default', 'skills.max_context_tokens',                '28000'),
  ('default', 'routines.max_lightweight_tokens',          '28000'),
    ('default', 'embedding.backend',                        '"openai_compatible"'),
    ('default', 'embedding.endpoint',                       '"http://127.0.0.1:${EMBED_PORT}"'),
    ('default', 'embedding.vector_store',                   '"pgvector"'),
    ('default', 'embedding.hybrid_search',                  'true'),
    ('default', 'embedding.dimensions',                     '768'),
    ('default', 'embeddings.model',                         '"nomic-embed-text-v1.5-f16.gguf"'),
    ('default', 'embeddings.enabled',                       'true'),
    ('default', 'embeddings.provider',                      '"openai"'),
  ('default', 'thinking.mode',                            '"auto"'),
  ('default', 'thinking.auto_threshold',                  '512'),
  ('default', 'thinking.max_tokens',                      '16384')
ON CONFLICT (user_id, key) DO UPDATE SET value = EXCLUDED.value;
SQLEOF
echo "  ✓ DB settings configured"

# Fix Telegram polling
echo "  → Fixing Telegram polling..."
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
    print('  telegram.capabilities.json not found — OK on first install')
"

# WASM channels
mkdir -p ~/.ironclaw/channels
ironclaw registry install telegram 2>/dev/null || \
    echo "  ⚠ Install telegram.wasm manually into ~/.ironclaw/channels/"

# Systemd service for IronClaw
echo "  → Creating systemd service..."
cat > ~/.config/systemd/user/ironclaw.service << EOF
[Unit]
Description=IronClaw daemon
After=network.target llama-embed.service litellm.service

[Service]
Type=simple
EnvironmentFile=/home/${USER}/.ironclaw/.env
WorkingDirectory=$REPO_DIR
ExecStart=/home/${USER}/.cargo/bin/ironclaw run --no-onboard
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload
systemctl --user enable ironclaw 2>/dev/null || true

# Source .env in shell startup
SHELL_LINE='[ -f "$HOME/.ironclaw/.env" ] && set -a && . "$HOME/.ironclaw/.env" && set +a'
for RC in ~/.bashrc ~/.profile; do
    if [ -f "$RC" ] && ! grep -qF 'ironclaw/.env' "$RC"; then
        echo "$SHELL_LINE" >> "$RC" 2>/dev/null
        echo "    → source .ironclaw/.env in $RC"
    fi
done

echo "  → Starting IronClaw..."
systemctl --user start ironclaw 2>/dev/null || true
sleep 3
systemctl --user is-active --quiet ironclaw && echo "  ✓ ironclaw.service running" || echo "  ⚠ ironclaw may fail — check: journalctl --user -u ironclaw -n 20"

systemctl --user daemon-reload
systemctl --user enable llama-embed 2>/dev/null || true
systemctl --user start llama-embed 2>/dev/null || true

# ── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ IronClaw install complete!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Components:"
echo "  ─────────────────────────────────────────"
printf "  ${GREEN}●${RESET} PostgreSQL      ${DB_NAME} (user: ${DB_USER})\n"
systemctl --user is-active --quiet postgresql 2>/dev/null && printf "                     ${GREEN}running${RESET}\n" || printf "                     ${YELLOW}manual start: sudo systemctl start postgresql${RESET}\n"

printf "  ${GREEN}●${RESET} LiteLLM         port ${CYAN}4000${RESET}\n"
systemctl --user is-active --quiet litellm 2>/dev/null && printf "                     ${GREEN}running${RESET}\n" || printf "                     ${YELLOW}stopped${RESET}\n"

DB_URL="postgres://${DB_USER}:${DB_PASS}@localhost:5432/${DB_NAME}?sslmode=disable"

# 1. Running docker container (most accurate)
ACTIVE_MODEL=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^(vllm|atlas)[-_]' | head -1 | sed 's/^vllm[-_]//;s/^atlas[-_]//')

# 2. Fallback to last_model file
if [ -z "$ACTIVE_MODEL" ] && [ -f "$HOME/.ironclaw/last_model" ]; then
    ACTIVE_MODEL=$(cat "$HOME/.ironclaw/last_model" | tr -d '[:space:]')
fi

# 3. Fallback to DB selected_model
if [ -z "$ACTIVE_MODEL" ]; then
    ACTIVE_MODEL=$(psql "$DB_URL" -tAc "SELECT value FROM settings WHERE user_id='default' AND key='selected_model' LIMIT 1;" 2>/dev/null | tr -d '"' || echo "")
fi

VLLM_RUNNING=$(docker ps --format "{{.Names}}" 2>/dev/null | grep -E "^(vllm|atlas)-" | head -1 || true)

echo "  Active model: ${CYAN}${ACTIVE_MODEL:-none}${RESET}"
if [ -n "$VLLM_RUNNING" ]; then
    printf "  ${GREEN}● running${RESET}  on %s\n" "$VLLM_RUNNING"
else
    printf "  ${YELLOW}○ stopped${RESET}  (vLLM container not running)\n"
fi

echo ""
echo "  All registered models:"

# Write a temp Python script for model listing
_MODELS_TMP=$(mktemp /tmp/ironclaw-models-XXXXXX.py)
cat > "$_MODELS_TMP" << 'PYEOF'
import re, sys
yaml_path = sys.argv[1]
active = sys.argv[2] if len(sys.argv) > 2 else ""
try:
    raw = open(yaml_path).read()
    blocks = re.findall(r'model_name:\s*(\S+).*?api_base:\s*http://([\d.]+):(\d+)', raw, re.DOTALL)
    for alias, ip, port in blocks:
        marker = ''
        prefix = ''
        if alias == active:
            marker = ' ⟹ active'
            prefix = '    -->'
        else:
            prefix = '         '
        print(f'  {prefix} {alias}{marker}')
except Exception as e:
    print(f'  (error reading config: {e})')
PYEOF
python3 "$_MODELS_TMP" "$LITELLM_CONFIG" "$ACTIVE_MODEL" 2>/dev/null || echo "    (config error)"
rm -f "$_MODELS_TMP"

printf "  ${GREEN}●${RESET} Embeddings      port ${EMBED_PORT} (nomic-embed-text)\n"
systemctl --user is-active --quiet llama-embed 2>/dev/null && printf "                     ${GREEN}running${RESET}\n" || printf "                     ${YELLOW}stopped${RESET}\n"

printf "  ${GREEN}●${RESET} IronClaw        telegram + CLI\n"
systemctl --user is-active --quiet ironclaw 2>/dev/null && printf "                     ${GREEN}running${RESET}\n" || printf "                     ${YELLOW}stopped${RESET}\n"

echo "  "
echo "  ─────────────────────────────────────────"
echo "  Next steps:"
echo "  ─────────────────────────────────────────"
echo "  1. Wait 10 seconds and send a message to your Telegram bot"
echo "  2. You'll receive a pairing code → run:"
echo "     ironclaw pairing approve telegram <CODE>"
echo ""
echo "  Manage models: bash ironclaw/setup.sh"
echo "  Check status:  bash spark.sh"
echo ""
