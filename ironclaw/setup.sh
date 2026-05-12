#!/bin/bash
# setup.sh — IronClaw setup wizard and model switcher
# Usage: ./ironclaw/setup.sh             — main menu
#        ./ironclaw/setup.sh model       — change default model directly
#        ./ironclaw/setup.sh embeddings  — configure embeddings directly
#        ./ironclaw/setup.sh models      — manage inference models
#        ./ironclaw/setup.sh role        — switch agent role directly

set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LITELLM_CONFIG="$HOME/.litellm/litellm_config.yaml"
RECIPES_DIR="$REPO_DIR/recipes"
ENV_FILE="$HOME/.ironclaw/.env"
IRONCLAW_CONFIG="$HOME/.ironclaw/config.toml"

GREEN='\033[32m'
CYAN='\033[36m'
BOLD='\033[1m'
YELLOW='\033[33m'
RESET='\033[0m'

ok()   { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
info() { printf "  → %s\n" "$*"; }
warn() { printf "  ${YELLOW}!${RESET} %s\n" "$*"; }
ask()  { printf "${CYAN}%s${RESET} " "$*"; }

# ── Read LiteLLM model names from config ──────────────────────────────────────
litellm_models() {
    python3 -c "
import re
try:
    raw = open('$LITELLM_CONFIG').read()
    for m in re.findall(r'model_name:\s*(.+)', raw):
        print(m.strip())
except Exception:
    pass
" 2>/dev/null || true
}

# ── Read current selected_model from DB ───────────────────────────────────────
current_model() {
    local db_url="$1"
    psql "$db_url" -tAc \
        "SELECT value FROM settings WHERE user_id='default' AND key='selected_model';" \
        2>/dev/null | tr -d '"' || echo ""
}

# ── Change default model ──────────────────────────────────────────────────────
change_model() {
    if [ ! -f "$ENV_FILE" ]; then
        echo "IronClaw is not installed. Run setup first."
        exit 1
    fi

    set -o allexport; source "$ENV_FILE"; set +o allexport
    local db_url="${DATABASE_URL:-}"
    if [ -z "$db_url" ]; then
        echo "DATABASE_URL not found in $ENV_FILE"
        exit 1
    fi

    local cur
    cur=$(current_model "$db_url")

    mapfile -t MODELS < <(litellm_models)
    if [ ${#MODELS[@]} -eq 0 ]; then
        echo "No models found in $LITELLM_CONFIG"
        exit 1
    fi

    printf "\n${BOLD}=== Change Default Model ===${RESET}\n"
    printf "  ${CYAN}→ Add models in:${RESET} ~/.litellm/litellm_config.yaml\n\n"
    for i in "${!MODELS[@]}"; do
        local name="${MODELS[$i]}"
        if [ "$name" = "$cur" ]; then
            printf "  ${GREEN}●${RESET} %-2s  %s  ${CYAN}← current${RESET}\n" "$((i+1))" "$name"
        else
            printf "    %-2s  %s\n" "$((i+1))" "$name"
        fi
    done

    echo ""
    echo "  [q] Cancel"
    echo ""
    ask "Select model (1-${#MODELS[@]}):"
    read -r sel

    [[ "$sel" == "q" || "$sel" == "Q" ]] && echo "Cancelled." && return

    if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "${#MODELS[@]}" ]; then
        echo "Invalid selection."
        exit 1
    fi

    local chosen="${MODELS[$((sel-1))]}"

    local resolved recipe_slug hf_model
    resolved=$(python3 -c "
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
            if m: print(f[:-5] + '\t' + m.group(1).strip()); sys.exit(0)
except: pass
" "$chosen" 2>/dev/null)
    recipe_slug="${resolved%%$'\t'*}"
    hf_model="${resolved#*$'\t'}"

    psql "$db_url" -c \
        "INSERT INTO settings (user_id, key, value)
         VALUES ('default', 'selected_model', '\"${chosen}\"')
         ON CONFLICT (user_id, key) DO UPDATE SET value = '\"${chosen}\"';" > /dev/null
    ok "selected_model set to '${chosen}'"

    if [ -n "$hf_model" ]; then
        sed -i "s|^LLM_MODEL=.*|LLM_MODEL=\"${hf_model}\"|" "$ENV_FILE"
        ok "LLM_MODEL updated to '${hf_model}'"
    fi

    if [ -n "$recipe_slug" ]; then
        mkdir -p "$HOME/.ironclaw"
        echo "$recipe_slug" > "$HOME/.ironclaw/last_model"
        ok "last_model saved: ${recipe_slug}"
    fi

    info "Restarting LiteLLM..."
    systemctl --user restart litellm
    for i in $(seq 1 15); do
        sleep 1
        curl -sf http://127.0.0.1:4000/v1/models -H "Authorization: Bearer sk-no-key" >/dev/null 2>&1 && break
    done
    ok "LiteLLM ready"

    info "Restarting IronClaw..."
    systemctl --user restart ironclaw
    sleep 2
    if systemctl --user is-active --quiet ironclaw; then
        ok "IronClaw running with model: ${chosen}"
    else
        echo "  ✗ IronClaw failed to start — check: journalctl --user -u ironclaw -n 20"
        exit 1
    fi
}

# ── Configure embeddings ──────────────────────────────────────────────────────
configure_embeddings() {
    if [ ! -f "$ENV_FILE" ]; then
        echo "IronClaw is not installed. Run setup first."
        exit 1
    fi

    printf "\n${BOLD}=== Configure Embeddings ===${RESET}\n\n"

    # Show current state
    local cur_enabled cur_provider cur_model
    cur_enabled=$(python3 -c "
import re
try:
    raw = open('$IRONCLAW_CONFIG').read()
    m = re.search(r'\[embeddings\].*?enabled\s*=\s*(\w+)', raw, re.DOTALL)
    print(m.group(1) if m else 'false')
except: print('false')
" 2>/dev/null)
    cur_provider=$(python3 -c "
import re
try:
    raw = open('$IRONCLAW_CONFIG').read()
    m = re.search(r'\[embeddings\].*?provider\s*=\s*\"([^\"]+)\"', raw, re.DOTALL)
    print(m.group(1) if m else 'nearai')
except: print('nearai')
" 2>/dev/null)

    if [ "$cur_enabled" = "true" ]; then
        printf "  Current: ${GREEN}enabled${RESET} (provider: ${cur_provider})\n\n"
    else
        printf "  Current: ${YELLOW}disabled${RESET}\n\n"
    fi

    echo "  [1] Option A — Local (llama.cpp + nomic-embed-text-v1.5, ~100MB GGUF)"
    echo "  [2] Option B — NEAR AI cloud (requires API key)"
    echo "  [3] Disable embeddings"
    echo "  [q] Cancel"
    echo ""
    ask "Select:"
    read -r sel

    case "$sel" in
        1) _embeddings_local ;;
        2) _embeddings_nearai ;;
        3) _embeddings_disable ;;
        q|Q) echo "Cancelled." ; return ;;
        *) echo "Invalid." ; return ;;
    esac
}

_embeddings_local() {
    printf "\n${BOLD}--- Option A: Local embeddings (llama.cpp + nomic-embed-text-v1.5, ~100MB GGUF) ---${RESET}\n\n"

    # Check if nomic-embed-text is already in LiteLLM config
    local has_nomic
    has_nomic=$(python3 -c "
import re
try:
    raw = open('$LITELLM_CONFIG').read()
    print('yes' if re.search(r'model_name:\s*nomic-embed-text', raw) else 'no')
except: print('no')
" 2>/dev/null)

    # Ask for port
    ask "llama-server port for embeddings [8010]:"
    read -r embed_port
    embed_port="${embed_port:-8010}"

    # Ask for model name alias
    ask "LiteLLM alias for embeddings [nomic-embed-text]:"
    read -r embed_alias
    embed_alias="${embed_alias:-nomic-embed-text}"

    # Ensure llama.cpp is installed
    if ! command -v llama-server &>/dev/null; then
        info "Installing llama.cpp..."
        if [ ! -d ~/repos/llama.cpp ]; then
            git clone https://github.com/ggerganov/llama.cpp ~/repos/llama.cpp
        fi
        cd ~/repos/llama.cpp
        cmake --build . --target llama-server --config Release 2>/dev/null || make llama-server -j$(nproc) 2>/dev/null
        if command -v llama-server &>/dev/null; then
            ok "llama.cpp built"
        else
            fail "llama-server not found — install it first: git clone https://github.com/ggerganov/llama.cpp && make -j"
            return 1
        fi
    fi

    # Check or download GGUF nomic-embed-text-v1.5
    local gguf_path=""
    gguf_path=$(find ~/models -name '*nomic-embed-text*' -name '*.gguf' 2>/dev/null | head -1)
    if [ -z "$gguf_path" ]; then
        gguf_path=$(find ~/.cache/huggingface/hub -name '*nomic-embed-text*' -name '*.gguf' 2>/dev/null | head -1)
    fi

    if [ -n "$gguf_path" ] && [ -f "$gguf_path" ]; then
        ok "Found nomic-embed-text GGUF: $gguf_path"
    else
        info "Downloading nomic-embed-text-v1.5 GGUF (~100MB)..."
        mkdir -p ~/models/embeddings
        gguf_path="$HOME/models/embeddings/nomic-embed-text-v1.5-f16.gguf"

        if [ ! -f "$gguf_path" ]; then
            echo ""
            info "Select nomic-embed-text GGUF repo:"
            echo "  [1] second-state/Nomic-embed-text-v1.5-Embedding-GGUF (HuggingFace)"
            echo "  [2] I manually downloaded the GGUF elsewhere"
            read -r gguf_src
            case "$gguf_src" in
                2) echo "  Full path to GGUF:"; read -r gguf_path; echo "" ;;
                *) gguf_url="https://hf-mirror.com/second-state/Nomic-embed-text-v1.5-Embedding-GGUF/resolve/main/nomic-embed-text-v1.5-f16.gguf" ;;
            esac
            if [[ "$gguf_src" != "2" ]]; then
                info "Downloading from HF mirror (this may take a few minutes)..."
                curl -L -o "$gguf_path" "$gguf_url" 2>/dev/null || wget -O "$gguf_path" "$gguf_url" 2>/dev/null
            fi

            if [ ! -f "$gguf_path" ] || [ "$(_filesize "$gguf_path")" -lt 10000000 ]; then
                fail "GGUF download failed or invalid"
                return 1
            fi
        fi
    fi

    # Write embeddings.conf for systemd
    mkdir -p "$HOME/.ironclaw"
    cat > "$HOME/.ironclaw/embeddings.conf" << EOFCONF
LLAMA_EMBED_MODEL_PATH=${gguf_path}
LLAMA_EMBED_CTX_SIZE=2048
LLAMA_EMBED_PORT=${embed_port}
LLAMA_EMBED_NGL=35
EOFCONF
    ok "Wrote ${HOME}/.ironclaw/embeddings.conf"

    # Create and install systemd service for llama-server
    local llama_server_path="$HOME/repos/llama.cpp/build/bin/llama-server"
    mkdir -p ~/.config/systemd/user
    cat > ~/.config/systemd/user/llama-embed.service << EOFN
[Unit]
Description=llama-server for embedding (nomic-embed-text)
After=network.target

[Service]
Type=simple
User=%U
EnvironmentFile=${HOME}/.ironclaw/embeddings.conf
ExecStart=${llama_server_path} \\
    --model %E{LLAMA_EMBED_MODEL_PATH} \\
    --ctx-size %E{LLAMA_EMBED_CTX_SIZE} \\
    --port %E{LLAMA_EMBED_PORT} \\
    --host 0.0.0.0 \\
    --embedding \\
    -ngl %E{LLAMA_EMBED_NGL}
Restart=always
RestartSec=10
StandardOutput=journal

[Install]
WantedBy=default.target
EOFN

    systemctl --user daemon-reload
    systemctl --user enable llama-embed

    # Stop any previous nohup process
    if [ -f /tmp/llama-server-embed.pid ]; then
        kill "$(cat /tmp/llama-server-embed.pid)" 2>/dev/null || true
        rm -f /tmp/llama-server-embed.pid
    fi

    # Start service via systemd
    info "Starting llama-server via systemd on port ${embed_port}..."
    systemctl --user start llama-embed
    sleep 1

    _wait_for_port "$embed_port" "llama-server (embeddings)"
    ok "llama-server ready on port ${embed_port}"

    # Add nomic-embed-text to LiteLLM config if not already there
    if [ "$has_nomic" = "no" ]; then
        cat >> "$LITELLM_CONFIG" << EOF

  - model_name: ${embed_alias}
    litellm_params:
      model: openai/nomic-ai/nomic-embed-text-v1.5
      api_base: http://127.0.0.1:${embed_port}
      api_key: sk-no-key
EOF
        ok "Added ${embed_alias} to LiteLLM config"
        info "Restarting LiteLLM..."
        systemctl --user restart litellm
        sleep 3
        ok "LiteLLM restarted"
    else
        ok "nomic-embed-text already in LiteLLM config"
    fi

    # Update config.toml
    _update_embeddings_config "true" "openai_compatible" \
        "${embed_alias}" "http://127.0.0.1:${embed_port}" "sk-no-key"

    ok "Embeddings configured: local nomic-embed-text-v1.5 (llama.cpp, systemd-managed)"
    _restart_ironclaw
}

_embeddings_nearai() {
    printf "\n${BOLD}--- Option B: NEAR AI cloud embeddings ---${RESET}\n\n"

    ask "NEAR AI API key:"
    read -r nearai_key
    [ -z "$nearai_key" ] && echo "API key required." && return

    ask "Embedding model [text-embedding-3-small]:"
    read -r nearai_model
    nearai_model="${nearai_model:-text-embedding-3-small}"

    _update_embeddings_config "true" "nearai" "$nearai_model" "" "$nearai_key"

    # Store API key in .env if not already there
    if ! grep -q 'NEARAI_API_KEY' "$ENV_FILE" 2>/dev/null; then
        echo "NEARAI_API_KEY=${nearai_key}" >> "$ENV_FILE"
        ok "NEARAI_API_KEY added to .env"
    else
        sed -i "s|^NEARAI_API_KEY=.*|NEARAI_API_KEY=${nearai_key}|" "$ENV_FILE"
        ok "NEARAI_API_KEY updated in .env"
    fi

    ok "Embeddings configured: NEAR AI cloud (${nearai_model})"
    _restart_ironclaw
}

_embeddings_disable() {
    _update_embeddings_config "false" "nearai" "text-embedding-3-small" "" ""
    ok "Embeddings disabled"
    _restart_ironclaw
}

# Patch the [embeddings] block in config.toml
_update_embeddings_config() {
    local enabled="$1" provider="$2" model="$3" base_url="$4" api_key="$5"

    if [ ! -f "$IRONCLAW_CONFIG" ]; then
        warn "config.toml not found at $IRONCLAW_CONFIG — creating embeddings block"
        mkdir -p "$(dirname "$IRONCLAW_CONFIG")"
        touch "$IRONCLAW_CONFIG"
    fi

    # Build new embeddings block
    local new_block
    new_block="[embeddings]\nenabled = ${enabled}\nprovider = \"${provider}\"\nmodel = \"${model}\""
    [ -n "$base_url" ] && new_block="${new_block}\nbase_url = \"${base_url}\"\napi_key = \"${api_key}\""

    # Replace existing [embeddings] block or append
    python3 -c "
import re, sys

config_path = '$IRONCLAW_CONFIG'
new_block = '''${new_block}'''

raw = open(config_path).read()

# Replace existing [embeddings] block (everything until next [section] or EOF)
pattern = r'\[embeddings\][^\[]*'
if re.search(pattern, raw):
    raw = re.sub(pattern, new_block + '\n\n', raw)
else:
    raw = raw.rstrip() + '\n\n' + new_block + '\n'

open(config_path, 'w').write(raw)
print('  config.toml updated')
"
    ok "config.toml updated"
}

_filesize() {
    local file="$1"
    if [ -f "$file" ]; then
        stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0
    else
        echo 0
    fi
}

_restart_ironclaw() {
    info "Restarting IronClaw..."
    systemctl --user restart ironclaw
    sleep 3
    if systemctl --user is-active --quiet ironclaw; then
        ok "IronClaw running"
    else
        warn "IronClaw failed to start — check: journalctl --user -u ironclaw -n 20"
    fi
}

# ── Install wizard ────────────────────────────────────────────────────────────
run_install() {
    printf "\n${BOLD}=== IronClaw Install Wizard ===${RESET}\n\n"

    local cur_token="" cur_user_id="" cur_db_user="ironclaw_user" cur_db_pass="ironclaw"
    if [ -f "$ENV_FILE" ]; then
        cur_token=$(grep '^TELEGRAM_BOT_TOKEN=' "$ENV_FILE" | cut -d'"' -f2)
        local cur_db_url
        cur_db_url=$(grep '^DATABASE_URL=' "$ENV_FILE" | cut -d'"' -f2)
        if [ -n "$cur_db_url" ]; then
            cur_db_user=$(python3 -c "import re,sys; m=re.match(r'postgres://([^:]+):([^@]+)@',sys.argv[1]); print(m.group(1) if m else 'ironclaw_user')" "$cur_db_url" 2>/dev/null)
            cur_db_pass=$(python3 -c "import re,sys; m=re.match(r'postgres://([^:]+):([^@]+)@',sys.argv[1]); print(m.group(2) if m else 'ironclaw')" "$cur_db_url" 2>/dev/null)
            cur_user_id=$(psql "$cur_db_url" -tAc \
                "SELECT value FROM settings WHERE user_id='default' AND key='telegram_allow_from';" \
                2>/dev/null | python3 -c "import sys,json; d=json.loads(sys.stdin.read().strip()); print(d[0] if d else '')" 2>/dev/null || echo "")
        fi
    fi

    ask_default() {
        local prompt="$1" cur="$2"
        local display="${cur:0:40}"; [ "${#cur}" -gt 40 ] && display="${cur:0:37}..."
        [ -n "$cur" ] && printf "${CYAN}%s${RESET} [%s]: " "$prompt" "$display" \
                      || printf "${CYAN}%s${RESET}: " "$prompt"
    }

    ask_default "Telegram bot token" "$cur_token"
    read -r TELEGRAM_TOKEN
    TELEGRAM_TOKEN="${TELEGRAM_TOKEN:-$cur_token}"
    [ -z "$TELEGRAM_TOKEN" ] && echo "Required." && exit 1

    ask_default "Telegram user ID (numeric)" "$cur_user_id"
    read -r TELEGRAM_USER_ID
    TELEGRAM_USER_ID="${TELEGRAM_USER_ID:-$cur_user_id}"
    [ -z "$TELEGRAM_USER_ID" ] && echo "Required." && exit 1

    ask_default "DB user" "$cur_db_user"
    read -r DB_USER
    DB_USER="${DB_USER:-$cur_db_user}"

    ask_default "DB password" "$cur_db_pass"
    read -r DB_PASS
    DB_PASS="${DB_PASS:-$cur_db_pass}"

    DB_NAME="ironclaw"
    DB_URL="postgres://${DB_USER}:${DB_PASS}@localhost:5432/${DB_NAME}?sslmode=disable"

    mapfile -t MODELS < <(litellm_models)
    if [ ${#MODELS[@]} -gt 0 ]; then
        echo ""
        echo "Default model:"
        for i in "${!MODELS[@]}"; do
            printf "    %-2s  %s\n" "$((i+1))" "${MODELS[$i]}"
        done
        echo ""
        ask "Select default model (1-${#MODELS[@]}) [1]:"
        read -r model_sel
        model_sel="${model_sel:-1}"
        if [[ "$model_sel" =~ ^[0-9]+$ ]] && [ "$model_sel" -ge 1 ] && [ "$model_sel" -le "${#MODELS[@]}" ]; then
            DEFAULT_MODEL="${MODELS[$((model_sel-1))]}"
        else
            DEFAULT_MODEL="${MODELS[0]}"
        fi
    else
        DEFAULT_MODEL="nemotron-nano"
    fi

    HF_MODEL=$(python3 -c "
import re, os, sys
model_name = sys.argv[1]
recipes_dir = sys.argv[2]
litellm_cfg = sys.argv[3]
raw = open(litellm_cfg).read()
block_m = re.search(r'model_name:\s*' + re.escape(model_name) + r'.*?api_base:\s*(\S+)', raw, re.DOTALL)
if not block_m: print(''); sys.exit(0)
api_base = block_m.group(1)
port_m = re.search(r':(\d+)', api_base)
if not port_m: print(''); sys.exit(0)
port = port_m.group(1)
for fname in os.listdir(recipes_dir):
    if not fname.endswith('.yaml'): continue
    recipe_raw = open(os.path.join(recipes_dir, fname)).read()
    if re.search(r'port:\s*' + port, recipe_raw):
        m = re.search(r'^model:\s*(.+)', recipe_raw, re.MULTILINE)
        if m: print(m.group(1).strip()); sys.exit(0)
print('')
" "$DEFAULT_MODEL" "$RECIPES_DIR" "$LITELLM_CONFIG" 2>/dev/null || echo "")

    [ -z "$HF_MODEL" ] && HF_MODEL="nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-NVFP4"

    echo ""
    echo "  Summary:"
    info "DB:            ${DB_URL}"
    info "Default model: ${DEFAULT_MODEL} (${HF_MODEL})"
    info "Telegram:      user ${TELEGRAM_USER_ID}"
    echo ""
    ask "Proceed? [Y/n]:"
    read -r confirm
    [[ "$confirm" =~ ^[nN] ]] && echo "Aborted." && exit 0

    bash "$REPO_DIR/ironclaw/install.sh" "$TELEGRAM_TOKEN" "$TELEGRAM_USER_ID" \
        "$DB_USER" "$DB_PASS" "$DEFAULT_MODEL" "$HF_MODEL"
}

# ── Main menu ─────────────────────────────────────────────────────────────────
if [ "${1:-}" = "model" ]; then
    change_model
    exit
fi

# ── Manage inference models ───────────────────────────────────────────────────
manage_models() {
    local SPARK_VLLM_DIR="$REPO_DIR"  # spark-vllm-docker is the same repo structure

    printf "\n${BOLD}=== Manage Inference Models ===${RESET}\n\n"

    # Collect recipes
    mapfile -t RECIPE_FILES < <(find "$RECIPES_DIR" -maxdepth 1 -name "*.yaml" | sort)
    if [ ${#RECIPE_FILES[@]} -eq 0 ]; then
        echo "No recipes found in $RECIPES_DIR"
        return
    fi

    # Parse recipe metadata
    declare -a SLUGS MODELS PORTS
    for f in "${RECIPE_FILES[@]}"; do
        slug=$(basename "$f" .yaml)
        model=$(python3 -c "
import re
raw=open('$f').read()
m=re.search(r'^model:\s*(.+)', raw, re.MULTILINE)
print(m.group(1).strip() if m else '?')
" 2>/dev/null)
        port=$(python3 -c "
import re
raw=open('$f').read()
m=re.search(r'port:\s*(\d+)', raw)
print(m.group(1) if m else '?')
" 2>/dev/null)
        SLUGS+=("$slug")
        MODELS+=("$model")
        PORTS+=("$port")
    done

    # Show table with running status
    printf "  %-30s %-8s %-10s %-10s\n" "Recipe" "Port" "vLLM" "Atlas"
    printf "  %-30s %-8s %-10s %-10s\n" "------" "----" "----" "-----"
    for i in "${!SLUGS[@]}"; do
        local slug="${SLUGS[$i]}" port="${PORTS[$i]}"
        local vllm_status="stopped" atlas_status="stopped"
        docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^vllm-${slug}$"  && vllm_status="${GREEN}running${RESET}"
        docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^atlas-${slug}$" && atlas_status="${GREEN}running${RESET}"
        printf "  %-2s  %-28s %-8s " "$((i+1))" "$slug" "$port"
        printf "${vllm_status}%-10s${atlas_status}\n" "  "
    done

    echo ""
    echo "  [q] Back"
    echo ""
    ask "Select recipe (1-${#SLUGS[@]}):"
    read -r sel
    [[ "$sel" == "q" || "$sel" == "Q" ]] && return
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "${#SLUGS[@]}" ]; then
        echo "Invalid."; return
    fi

    local idx=$((sel-1))
    local slug="${SLUGS[$idx]}"
    local model="${MODELS[$idx]}"
    local port="${PORTS[$idx]}"
    local recipe_file="${RECIPE_FILES[$idx]}"

    printf "\n${BOLD}Recipe: ${slug}${RESET}\n"
    info "Model: $model"
    info "Port:  $port"
    echo ""

    local vllm_running=false atlas_running=false
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^vllm-${slug}$"  && vllm_running=true
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^atlas-${slug}$" && atlas_running=true

    if $vllm_running; then
        echo "  [1] Stop vLLM"
    else
        echo "  [1] Start with vLLM (spark-vllm-docker)"
    fi
    if $atlas_running; then
        echo "  [2] Stop Atlas"
    else
        echo "  [2] Start with Atlas"
    fi
    echo "  [q] Back"
    echo ""
    ask "Select:"
    read -r action

    case "$action" in
        1)
            if $vllm_running; then
                _stop_model "vllm-${slug}" "$port" "$slug" "vllm"
            else
                _start_vllm "$slug" "$model" "$port" "$recipe_file"
            fi
            ;;
        2)
            if $atlas_running; then
                _stop_model "atlas-${slug}" "$port" "$slug" "atlas"
            else
                _start_atlas "$slug" "$model" "$port" "$recipe_file"
            fi
            ;;
        q|Q) return ;;
        *) echo "Invalid." ;;
    esac
}

_start_vllm() {
    local slug="$1" model="$2" port="$3" recipe_file="$4"
    printf "\n${BOLD}--- Starting vLLM: ${slug} ---${RESET}\n"

    # Extract vllm command from recipe
    local vllm_cmd
    vllm_cmd=$(python3 -c "
import re, sys
raw = open('$recipe_file').read()
m = re.search(r'^command:\s*\|(.+?)(?=^\w|\Z)', raw, re.MULTILINE | re.DOTALL)
if m:
    cmd = m.group(1).strip()
    # Inject --host 0.0.0.0 if missing
    if '--host' not in cmd:
        cmd = cmd.replace('vllm serve', 'vllm serve', 1)
    print(cmd)
" 2>/dev/null)

    if [ -z "$vllm_cmd" ]; then
        warn "No 'command' block in recipe. Building basic vllm command."
        vllm_cmd="vllm serve ${model} --host 0.0.0.0 --port ${port} --trust-remote-code"
    fi

    # Get extra env vars from recipe
    local env_args=""
    while IFS= read -r env_line; do
        env_args="$env_args -e $env_line"
    done < <(python3 -c "
import re
raw=open('$recipe_file').read()
for m in re.finditer(r'^\s+([A-Z_]+=\S+)', raw, re.MULTILINE):
    print(m.group(1))
" 2>/dev/null)

    local image
    image=$(python3 -c "
import re
raw=open('$recipe_file').read()
m=re.search(r'container:\s*(\S+)', raw)
print(m.group(1) if m else 'vllm-node')
" 2>/dev/null)
    image="${image:-vllm-node}"

    info "Container: $image"
    info "Port: $port"
    echo ""

    docker run -d \
        --name "vllm-${slug}" \
        --network host --gpus all --ipc=host \
        $env_args \
        -v ~/.cache/huggingface:/root/.cache/huggingface \
        -v ~/.cache/vllm:/root/.cache/vllm \
        -v ~/.triton:/root/.triton \
        "$image" \
        bash -c "$vllm_cmd"

    _wait_for_port "$port" "vLLM"
    _register_litellm "$slug" "$model" "$port"
}

_start_atlas() {
    local slug="$1" model="$2" port="$3" recipe_file="$4"
    printf "\n${BOLD}--- Starting Atlas: ${slug} ---${RESET}\n"

    # Parse atlas block from recipe (if present), else use defaults
    local atlas_params
    atlas_params=$(python3 -c "
import re, sys
raw = open('$recipe_file').read()

# Try atlas: block first
atlas_m = re.search(r'^atlas:\s*\n((?:[ \t]+.+\n?)*)', raw, re.MULTILINE)
defaults_m = re.search(r'^defaults:\s*\n((?:[ \t]+.+\n?)*)', raw, re.MULTILINE)

params = {}

# Start with defaults (gpu_memory_utilization, max_model_len)
if defaults_m:
    for line in defaults_m.group(1).splitlines():
        m = re.match(r'\s+(\w+):\s*(.+)', line)
        if m: params[m.group(1)] = m.group(2).strip()

# Override/add with atlas block
if atlas_m:
    for line in atlas_m.group(1).splitlines():
        m = re.match(r'\s+(\w+):\s*(.+)', line)
        if m: params[m.group(1)] = m.group(2).strip()

# Map to Atlas flags
flags = []
if 'max_seq_len' in params:
    flags.append(f\"--max-seq-len {params['max_seq_len']}\")
elif 'max_model_len' in params:
    flags.append(f\"--max-seq-len {params['max_model_len']}\")
if 'kv_cache_dtype' in params:
    flags.append(f\"--kv-cache-dtype {params['kv_cache_dtype']}\")
if 'kv_high_precision_layers' in params:
    flags.append(f\"--kv-high-precision-layers {params['kv_high_precision_layers']}\")
if 'gpu_memory_utilization' in params:
    flags.append(f\"--gpu-memory-utilization {params['gpu_memory_utilization']}\")
if 'scheduling_policy' in params:
    flags.append(f\"--scheduling-policy {params['scheduling_policy']}\")
if 'tool_call_parser' in params:
    flags.append(f\"--tool-call-parser {params['tool_call_parser']}\")
if params.get('enable_prefix_caching', 'false').lower() == 'true':
    flags.append('--enable-prefix-caching')
if params.get('speculative', 'false').lower() == 'true':
    flags.append('--speculative')

print(' '.join(flags))
" 2>/dev/null)

    # Defaults if no atlas block and no defaults
    if [ -z "$atlas_params" ]; then
        atlas_params="--max-seq-len 32768 --kv-cache-dtype fp8 --gpu-memory-utilization 0.90 --scheduling-policy slai"
    fi

    info "Image: avarok/atlas-gb10:latest"
    info "Model: $model"
    info "Port:  $port"
    info "Flags: $atlas_params"
    echo ""

    docker run -d \
        --name "atlas-${slug}" \
        --network host --gpus all --ipc=host \
        -v ~/.cache/huggingface:/root/.cache/huggingface \
        avarok/atlas-gb10:latest \
        serve "$model" \
            --host 0.0.0.0 \
            --port "$port" \
            $atlas_params

    _wait_for_port "$port" "Atlas"
    _register_litellm "${slug}-atlas" "$model" "$port"
}

_stop_model() {
    local container="$1" port="$2" slug="$3" engine="$4"
    printf "\n${BOLD}--- Stopping ${container} ---${RESET}\n"
    docker stop "$container" 2>/dev/null && docker rm "$container" 2>/dev/null && ok "Stopped $container"
    _unregister_litellm "${slug}" "$engine"
}

_wait_for_port() {
    local port="$1" label="$2"
    info "Waiting for $label on port $port (max 60s)..."
    for i in $(seq 1 60); do
        sleep 1
        if curl -sf "http://127.0.0.1:${port}/v1/models" > /dev/null 2>&1; then
            ok "$label ready on port $port"
            return
        fi
        [ $((i % 10)) -eq 0 ] && info "  ...${i}s"
    done
    warn "$label did not respond in 60s — check: docker logs ${container}"
}

_register_litellm() {
    local alias="$1" model="$2" port="$3"
    local cfg="$HOME/.litellm/litellm_config.yaml"

    # Skip if already registered
    if grep -q "model_name: ${alias}" "$cfg" 2>/dev/null; then
        ok "LiteLLM: '$alias' already registered"
        return
    fi

    cat >> "$cfg" << EOF

  - model_name: ${alias}
    litellm_params:
      model: openai/${model}
      api_base: http://127.0.0.1:${port}/v1
      api_key: sk-no-key
EOF
    ok "LiteLLM: registered '${alias}' on port ${port}"
    systemctl --user restart litellm 2>/dev/null && sleep 2 && ok "LiteLLM restarted"
}

_unregister_litellm() {
    local slug="$1" engine="$2"
    local alias="$slug"
    [ "$engine" = "atlas" ] && alias="${slug}-atlas"
    local cfg="$HOME/.litellm/litellm_config.yaml"

    python3 -c "
import re
alias = '$alias'
raw = open('$cfg').read()
# Remove the model_name block for this alias
pattern = r'\n\s+- model_name:\s+' + re.escape(alias) + r'.*?(?=\n\s+- model_name:|\Z)'
new = re.sub(pattern, '', raw, flags=re.DOTALL)
open('$cfg', 'w').write(new)
print(f'  LiteLLM: removed {alias}')
" 2>/dev/null
    systemctl --user restart litellm 2>/dev/null && sleep 2 && ok "LiteLLM restarted"
}

# ── Uninstall ─────────────────────────────────────────────────────────────────
uninstall() {
    printf "\n${BOLD}🗑  Uninstall IronClaw${RESET}\n\n"
    echo "  Workspace .md files are NEVER touched."
    echo "  [1] IronClaw   — services, .ironclaw/, env vars; KEEP PostgreSQL, LiteLLM, binary"
    echo "  [2] All else   — also DROP PostgreSQL, remove LiteLLM, ironclaw binary, llama.cpp"
    echo "  [n] Cancel"
    read -r mode
    [[ "${mode,,}" == "n" ]] && echo "Aborted." && return

    local drop_db=false drop_llm=false remove_binary=false remove_llamacpp=false
    if [[ "${mode}" == "2" ]]; then
        drop_db=true; drop_llm=true; remove_binary=true; remove_llamacpp=true
        printf "\n${RED}⚠  Destructive — will also remove:${RESET}\n"
        info "  - PostgreSQL (all data)"
        info "  - LiteLLM (all configs)"
        info "  - ironclaw binary"
        info "  - llama.cpp source + build"
        echo ""
        echo "  [Y] Proceed"
        echo "  [n] Cancel"
        read -r confirm
        [[ "${confirm,,}" != "y" ]] && echo "Aborted." && return
    elif [[ "${mode}" != "1" ]]; then
        echo "Invalid."
        return
    fi

    printf "\n${GREEN}🗑 Cleaning...${RESET}\n\n"

    # ── Stop & disable services ──
    info "Stopping services..."
    for svc in ironclaw llama-embed; do
        systemctl --user stop "$svc" 2>/dev/null || true
        systemctl --user disable "$svc" 2>/dev/null || true
    done
    [[ "$drop_llm" == true ]] && { systemctl --user stop litellm 2>/dev/null || true; systemctl --user disable litellm 2>/dev/null || true; }
    systemctl --user daemon-reload 2>/dev/null || true
    ok "Services stopped & disabled"

    # ── Remove systemd unit files ──
    info "Removing unit files..."
    rm -f ~/.config/systemd/user/ironclaw.service
    rm -f ~/.config/systemd/user/llama-embed.service
    [[ "$drop_llm" == true ]] && rm -f ~/.config/systemd/user/litellm.service && rm -f ~/.config/systemd/user/postgresql.service
    rm -f ~/.config/systemd/user/spark-watchdog.timer
    systemctl --user daemon-reload 2>/dev/null || true
    ok "Unit files removed"

    # ── Remove .ironclaw (config + DB state) ──
    info "Removing ~/.ironclaw..."
    rm -rf ~/.ironclaw
    ok "Done"

    # ── Embeddings temp files ──
    rm -f /tmp/llama-server-embed.pid /tmp/llama-server-embed.log

    # ── Shell env lines ──
    info "Removing shell env lines..."
    for RC in ~/.bashrc ~/.profile ~/.zshrc; do
        [ -f "$RC" ] && sed -i '/ironclaw\/.env/d' "$RC" 2>/dev/null || true
    done
    ok "Done"

    # ── Kill leftover processes ──
    info "Killing leftover processes..."
    # Kill ironclaw binaries (any invocation, not just "ironclaw run")
    pkill -f "'ironclaw'" 2>/dev/null || true
    pkill -f "cargo.*run.*ironclaw" 2>/dev/null || true
    # Also kill by PID name if patterns miss
    killall -9 ironclaw 2>/dev/null || true
    pkill -f "llama-server.*embedding" 2>/dev/null || true
    pkill -f "nomic-embed-text" 2>/dev/null || true
    [[ "$drop_llm" == true ]] && pkill -f "litellm" 2>/dev/null || true
    [[ "$remove_llamacpp" == true ]] && killall -9 llama-server 2>/dev/null || true
    ok "Done"

    # ── DROP PostgreSQL ──
    if [[ "$drop_db" == true ]]; then
        echo ""
        printf "${YELLOW}Dropping PostgreSQL data...${RESET}\n"
        # Stop user-level service
        systemctl --user stop postgresql 2>/dev/null || true
        systemctl --user disable postgresql 2>/dev/null || true
        # Stop system-level service (most common on Ubuntu)
        sudo systemctl stop postgresql 2>/dev/null || true
        sudo systemctl disable postgresql 2>/dev/null || true
        # Stop via pg_lsclusters if available
        if command -v pg_lsclusters &>/dev/null; then
            for ver in $(pg_lsclusters -h | awk '{print $1}'); do
                pg_dropcluster --stop $ver main 2>/dev/null \
                    || sudo -u postgres pg_ctlcluster $ver main stop 2>/dev/null || true
            done
        fi
        rm -rf "$PG_DATA"
        echo "  ✅ PostgreSQL data removed ($(du -sh "${PG_DATA:-unknown}" 2>/dev/null | cut -f1))"
    fi

    # ── DROP LiteLLM config ──
    if [[ "$drop_llm" == true ]]; then
        echo ""
        printf "${YELLOW}Removing LiteLLM config...${RESET}\n"
        rm -rf ~/.litellm
        echo "  ✅ LiteLLM config removed"
    fi

    # ── Remove ironclaw binary ──
    if [[ "$remove_binary" == true ]]; then
        echo ""
        printf "${YELLOW}Removing ironclaw binary...${RESET}\n"
        if [ -f "$HOME/.cargo/bin/ironclaw" ]; then
            . "$HOME/.cargo/env" 2>/dev/null || true
            if "$HOME/.cargo/bin/cargo" uninstall ironclaw 2>/dev/null; then
                echo "  ✅ Binary removed"
            else
                rm -f "$HOME/.cargo/bin/ironclaw" && echo "  ✅ Binary removed (direct delete)"
            fi
        else
            echo "  ✅ Binary not found, skipping"
        fi
    fi

    # ── Remove llama.cpp ──
    if [[ "$remove_llamacpp" == true ]]; then
        echo ""
        printf "${YELLOW}Removing llama.cpp...${RESET}\n"
        rm -rf ~/repos/llama.cpp
        echo "  ✅ Done"
    fi

    echo ""
    if [[ "${mode}" == "1" ]]; then
        echo "  ✅ IronClaw removed"
        echo "  Kept: workspace .md files, PostgreSQL, LiteLLM, binary, llama.cpp"
    else
        echo "  ✅✅ Everything removed"
        echo "  Kept: workspace .md files in $REPO_DIR"
    fi
}

# ── Main menu ─────────────────────────────────────────────────────────────────
# ── Switch agent role ─────────────────────────────────────────────────────────
switch_role() {
    local ROLES_DIR="$REPO_DIR/ironclaw/roles"

    if [ ! -d "$ROLES_DIR" ]; then
        echo "  No roles directory found at $ROLES_DIR"
        return
    fi

    mapfile -t ROLES < <(find "$ROLES_DIR" -mindepth 1 -maxdepth 1 -type d | sort | xargs -I{} basename {})

    if [ ${#ROLES[@]} -eq 0 ]; then
        echo "  No roles found in $ROLES_DIR"
        return
    fi

    # Detect current role from IDENTITY.md
    local current_role=""
    current_role=$(grep -i "^- \*\*Role:\*\*" ~/.ironclaw/workspace/IDENTITY.md 2>/dev/null | sed 's/.*Role:\*\* //' || true)

    printf "\n${BOLD}=== Switch Agent Role ===${RESET}\n\n"
    [ -n "$current_role" ] && printf "  Current: ${GREEN}%s${RESET}\n\n" "$current_role"

    # Role descriptions
    declare -A ROLE_DESC
    ROLE_DESC["personal-assistant"]="Reminders, notes, news, system monitoring   [gemma-4]"
    ROLE_DESC["developer"]="Coding, architecture, GitHub, shell         [qwen36]"
    ROLE_DESC["ml-engineer"]="Models, experiments, inference infra        [nemotron-super]"
    ROLE_DESC["security"]="Threat modeling, CVEs, code audit           [foundation-sec]"
    ROLE_DESC["researcher"]="Papers, synthesis, long-context analysis    [nemotron-super]"

    # Role default models
    declare -A ROLE_MODEL
    ROLE_MODEL["personal-assistant"]="gemma-4"
    ROLE_MODEL["developer"]="qwen36"
    ROLE_MODEL["ml-engineer"]="nemotron-super"
    ROLE_MODEL["security"]="foundation-sec"
    ROLE_MODEL["researcher"]="nemotron-super"

    for i in "${!ROLES[@]}"; do
        local role="${ROLES[$i]}"
        local desc="${ROLE_DESC[$role]:-no description}"
        if [ "$role" = "$current_role" ]; then
            printf "  ${GREEN}●${RESET} [%s] %-22s %s  ${CYAN}← current${RESET}\n" "$((i+1))" "$role" "$desc"
        else
            printf "    [%s] %-22s %s\n" "$((i+1))" "$role" "$desc"
        fi
    done

    echo ""
    echo "  [q] Cancel"
    echo ""
    ask "Select role (1-${#ROLES[@]}):"
    read -r sel
    [[ "${sel,,}" == "q" ]] && return
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "${#ROLES[@]}" ]; then
        echo "  Invalid."; return
    fi

    local chosen="${ROLES[$((sel-1))]}"
    local chosen_model="${ROLE_MODEL[$chosen]:-}"
    local role_dir="$ROLES_DIR/$chosen"

    # Ask for agent name — keep current if already set
    local current_name
    current_name=$(grep -i "^\- \*\*Name:\*\*" ~/.ironclaw/workspace/IDENTITY.md 2>/dev/null | sed 's/.*Name:\*\* //' || echo "Sparky")
    printf "\n  Agent name [%s]: " "$current_name"
    read -r new_name
    local agent_name="${new_name:-$current_name}"

    echo ""
    printf "  Switching to: ${BOLD}%s${RESET} (model: %s)\n\n" "$chosen" "$chosen_model"

    # Apply role .md files
    for f in SOUL.md AGENTS.md HEARTBEAT.md; do
        src="$role_dir/$f"
        dst="$HOME/.ironclaw/workspace/$f"
        if [ -f "$src" ]; then
            sed "s/{{AGENT_NAME}}/$agent_name/g" "$src" > "$dst"
            ok "applied $f"
        fi
    done

    # Update IDENTITY.md role field
    if [ -f "$HOME/.ironclaw/workspace/IDENTITY.md" ]; then
        sed -i "s/^- \*\*Role:\*\*.*/- **Role:** ${chosen}/" \
            "$HOME/.ironclaw/workspace/IDENTITY.md" 2>/dev/null || true
        sed -i "s/^- \*\*Name:\*\*.*/- **Name:** ${agent_name}/" \
            "$HOME/.ironclaw/workspace/IDENTITY.md" 2>/dev/null || true
        ok "updated IDENTITY.md"
    fi

    # Reimport all workspace files into ironclaw memory
    for f in SOUL.md IDENTITY.md USER.md AGENTS.md HEARTBEAT.md; do
        src="$HOME/.ironclaw/workspace/$f"
        [ -f "$src" ] && ironclaw memory write "$f" "$(cat "$src")" 2>/dev/null && ok "imported $f" || true
    done

    # Reset MEMORY.md to avoid stale context from previous role
    ironclaw memory write MEMORY.md "# Memory

No entries yet." 2>/dev/null && ok "reset MEMORY.md" || true

    # ── Model conflict detection ──────────────────────────────────────────────────
    if [ -n "$chosen_model" ]; then
        local running_container running_slug
        running_container=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^(vllm|atlas)-' | head -1 || true)
        running_slug=$(echo "$running_container" | sed 's/^vllm-//;s/^atlas-//')

        local running_model=""
        if [ -f "$HOME/.ironclaw/last_model" ]; then
            running_model=$(cat "$HOME/.ironclaw/last_model" | tr -d '[:space:]')
        fi

        local running_alias=""
        if [ -n "$running_model" ]; then
            running_alias=$(python3 -c "
import re, sys, os
try:
    raw = open('$HOME/.litellm/litellm_config.yaml').read()
    recipes_dir = '$REPO_DIR/recipes'
    for root, dirs, files in os.walk(recipes_dir):
        for f in files:
            if not f.endswith('.yaml'): continue
            rpath = os.path.join(root, f)
            slug = f[:-5].replace('-','_').replace('.','_')
            if slug in '$running_model'.replace('-','_').replace('.','_'):
                rcontent = open(rpath).read()
                m = re.search(r'port:\s*(\d+)', rcontent)
                if m:
                    port = m.group(1)
                    nm = re.search(r'model_name:\s*(\S+)(?=.*api_base.*:' + port + ')', raw, re.DOTALL)
                    if nm: print(nm.group(1)); sys.exit(0)
except: pass
print('')
" 2>/dev/null)
        fi

        local running_display="${running_alias:-${running_model:-none}}"

        # Fallback: check current selected_model in DB if no container detected
        local current_db_model=""
        if [ -z "$running_container" ] && [ -f "$HOME/.ironclaw/.env" ]; then
            set -o allexport; source "$HOME/.ironclaw/.env"; set +o allexport
            current_db_model=$(psql "${DATABASE_URL}" -tAc \
                "SELECT value FROM settings WHERE user_id='default' AND key='selected_model';" \
                2>/dev/null | tr -d '"' || true)
        fi
        [ "$running_display" = "none" ] && [ -n "$current_db_model" ] && running_display="$current_db_model"

        local conflict_label="${running_container:-DB}"
        if [ "$running_display" != "$chosen_model" ] && [ "$running_display" != "none" ] && [ -n "$running_display" ]; then
            echo ""
            printf "  ${YELLOW}⚠  Model conflict detected${RESET}\n"
            echo ""
            printf "  Role recommends:   ${BOLD}%s${RESET}\n" "$chosen_model"
            printf "  Currently set:     ${BOLD}%s${RESET} (DB)\n" "$running_display"
            echo ""
            printf "  ${DIM}Note: this only changes which model IronClaw sends requests to.${RESET}\n"
            printf "  ${DIM}It does NOT load or unload models from GB10 unified memory.${RESET}\n"
            printf "  ${DIM}To load a different model use [2] Models or [5] Switch Mode from the main menu.${RESET}\n"
            echo ""
            echo "  [1] Switch IronClaw to $chosen_model"
            echo "  [2] Keep IronClaw using $running_display"
            echo "  [3] Cancel role switch"
            echo ""
            ask "Select:"
            read -r model_action

            case "$model_action" in
                1)
                    if [ -n "$running_container" ]; then
                        printf "  → Stopping %s (timeout 25s)..." "$running_container"
                        docker stop --time 25 "$running_container" 2>/dev/null \
                            && docker rm "$running_container" 2>/dev/null \
                            && printf " ${GREEN}done${RESET}\n" || printf " ${YELLOW}forced${RESET}\n"
                    fi
                    if [ -f "$HOME/.ironclaw/.env" ]; then
                        set -o allexport; source "$HOME/.ironclaw/.env"; set +o allexport
                        psql "${DATABASE_URL}" -c "
                            INSERT INTO settings (user_id, key, value)
                            VALUES ('default', 'selected_model', '\"${chosen_model}\"')
                            ON CONFLICT (user_id, key) DO UPDATE SET value = '\"${chosen_model}\"';
                        " >/dev/null 2>&1 && ok "model set to $chosen_model" || true
                    fi
                    ;;
                2)
                    if [ -n "$running_alias" ] && [ -f "$HOME/.ironclaw/.env" ]; then
                        set -o allexport; source "$HOME/.ironclaw/.env"; set +o allexport
                        psql "${DATABASE_URL}" -c "
                            INSERT INTO settings (user_id, key, value)
                            VALUES ('default', 'selected_model', '\"${running_alias}\"')
                            ON CONFLICT (user_id, key) DO UPDATE SET value = '\"${running_alias}\"';
                        " >/dev/null 2>&1 && ok "model kept as $running_display" || true
                    else
                        ok "keeping current model $running_display"
                    fi
                    ;;
                3|*)
                    echo "  Role switch cancelled."
                    return
                    ;;
            esac
        else
            if [ -f "$HOME/.ironclaw/.env" ]; then
                set -o allexport; source "$HOME/.ironclaw/.env"; set +o allexport
                psql "${DATABASE_URL}" -c "
                    INSERT INTO settings (user_id, key, value)
                    VALUES ('default', 'selected_model', '\"${chosen_model}\"')
                    ON CONFLICT (user_id, key) DO UPDATE SET value = '\"${chosen_model}\"';
                " >/dev/null 2>&1 && ok "model set to $chosen_model" || true
            fi
        fi
    fi

    # Restart IronClaw to apply changes
    info "Restarting IronClaw..."
    systemctl --user restart ironclaw 2>/dev/null
    sleep 3
    systemctl --user is-active --quiet ironclaw && ok "IronClaw running" || warn "IronClaw failed — check: journalctl --user -u ironclaw -n 20"

    echo ""
    printf "  ${GREEN}✓${RESET} Role switched to ${BOLD}%s${RESET}\n" "$chosen"
}

if [ "${1:-}" = "model" ];      then change_model;       exit; fi
if [ "${1:-}" = "embeddings" ]; then configure_embeddings; exit; fi
if [ "${1:-}" = "models" ];     then manage_models;        exit; fi
if [ "${1:-}" = "role" ];       then switch_role;          exit; fi

printf "\n\033[1m=== IronClaw Setup ===\033[0m\n\n"

if [ -f "$ENV_FILE" ]; then
    printf "  \033[32m✓\033[0m .env found at $ENV_FILE\n"
    echo ""
    echo "  [1] Fresh install (overwrites existing setup)"
    echo "  [2] Change default LLM model"
    echo "  [3] Configure embeddings"
    echo "  [4] Manage inference models"
    echo "  [5] Switch agent role"
    echo "  [6] Uninstall IronClaw (clean removal)"
    echo "  [q] Quit"
else
    echo "  [1] Install IronClaw"
    echo "  [6] Uninstall IronClaw (clean removal)"
    echo "  [q] Quit"
fi

echo ""
printf "\033[36mSelect:\033[0m "
read -r sel

case "$sel" in
    1) run_install ;;
    2) change_model ;;
    3) configure_embeddings ;;
    4) manage_models ;;
    5) switch_role ;;
    6) uninstall ;;
    q|Q) echo "Bye." ;;
    *) echo "Invalid." ;;
esac
