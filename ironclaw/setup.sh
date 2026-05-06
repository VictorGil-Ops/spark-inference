#!/bin/bash
# setup.sh — IronClaw setup wizard and model switcher
# Usage: ./ironclaw/setup.sh           — main menu
#        ./ironclaw/setup.sh model     — change default model directly

set -e

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LITELLM_CONFIG="$REPO_DIR/ironclaw/litellm/litellm_config.yaml"
RECIPES_DIR="$REPO_DIR/recipes"
ENV_FILE="$HOME/.ironclaw/.env"

GREEN='\033[32m'
CYAN='\033[36m'
BOLD='\033[1m'
RESET='\033[0m'

ok()   { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
info() { printf "  → %s\n" "$*"; }
ask()  { printf "${CYAN}%s${RESET} " "$*"; }

# ── Read LiteLLM model names from config ──────────────────────────────────────
litellm_models() {
    python3 -c "
import re
try:
    raw = open('$LITELLM_CONFIG').read()
    for m in re.findall(r'model_name:\s*(.+)', raw):
        print(m.strip())
except FileNotFoundError:
    pass
"
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

    printf "\n${BOLD}=== Change Default Model ===${RESET}\n\n"
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

    # Resolve recipe slug + HF model ID from litellm api_base port
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

    # Update DB
    psql "$db_url" -c \
        "INSERT INTO settings (user_id, key, value)
         VALUES ('default', 'selected_model', '\"${chosen}\"')
         ON CONFLICT (user_id, key) DO UPDATE SET value = '\"${chosen}\"';" > /dev/null
    ok "selected_model set to '${chosen}'"

    # Update .env LLM_MODEL
    if [ -n "$hf_model" ]; then
        sed -i "s|^LLM_MODEL=.*|LLM_MODEL=\"${hf_model}\"|" "$ENV_FILE"
        ok "LLM_MODEL updated to '${hf_model}'"
    fi

    # Persist recipe slug as last_model for watchdog / start-all.sh
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

# ── Install wizard ────────────────────────────────────────────────────────────
run_install() {
    printf "\n${BOLD}=== IronClaw Install Wizard ===${RESET}\n\n"

    # Load current values from .env as defaults
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

    # Helper: prompt with current value as default
    ask_default() {
        local prompt="$1" cur="$2"
        local display="${cur:0:40}"; [ "${#cur}" -gt 40 ] && display="${cur:0:37}..."
        [ -n "$cur" ] && printf "${CYAN}%s${RESET} [%s]: " "$prompt" "$display" \
                      || printf "${CYAN}%s${RESET}: " "$prompt"
    }

    # Telegram token
    ask_default "Telegram bot token" "$cur_token"
    read -r TELEGRAM_TOKEN
    TELEGRAM_TOKEN="${TELEGRAM_TOKEN:-$cur_token}"
    [ -z "$TELEGRAM_TOKEN" ] && echo "Required." && exit 1

    # Telegram user ID
    ask_default "Telegram user ID (numeric)" "$cur_user_id"
    read -r TELEGRAM_USER_ID
    TELEGRAM_USER_ID="${TELEGRAM_USER_ID:-$cur_user_id}"
    [ -z "$TELEGRAM_USER_ID" ] && echo "Required." && exit 1

    # DB credentials
    ask_default "DB user" "$cur_db_user"
    read -r DB_USER
    DB_USER="${DB_USER:-$cur_db_user}"

    ask_default "DB password" "$cur_db_pass"
    read -r DB_PASS
    DB_PASS="${DB_PASS:-$cur_db_pass}"

    DB_NAME="ironclaw"
    DB_URL="postgres://${DB_USER}:${DB_PASS}@localhost:5432/${DB_NAME}?sslmode=disable"

    # Default model
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

    # Default LLM_MODEL (HF ID from recipe for the selected model name)
    HF_MODEL=$(python3 -c "
import re, os, sys
model_name = sys.argv[1]
recipes_dir = sys.argv[2]
litellm_cfg = sys.argv[3]

# Find api_base for this model_name in litellm config
raw = open(litellm_cfg).read()
# Find the block for this model_name
block_m = re.search(r'model_name:\s*' + re.escape(model_name) + r'.*?api_base:\s*(\S+)', raw, re.DOTALL)
if not block_m:
    print('')
    sys.exit(0)
api_base = block_m.group(1)
# Extract port from api_base
port_m = re.search(r':(\d+)', api_base)
if not port_m:
    print('')
    sys.exit(0)
port = port_m.group(1)

# Find recipe with this port and get model ID
for fname in os.listdir(recipes_dir):
    if not fname.endswith('.yaml'):
        continue
    recipe_raw = open(os.path.join(recipes_dir, fname)).read()
    if re.search(r'port:\s*' + port, recipe_raw):
        m = re.search(r'^model:\s*(.+)', recipe_raw, re.MULTILINE)
        if m:
            print(m.group(1).strip())
            sys.exit(0)
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

    # Run install.sh
    bash "$REPO_DIR/ironclaw/install.sh" "$TELEGRAM_TOKEN" "$TELEGRAM_USER_ID" \
        "$DB_USER" "$DB_PASS" "$DEFAULT_MODEL" "$HF_MODEL"
}

# ── Main menu ─────────────────────────────────────────────────────────────────
if [ "${1}" = "model" ]; then
    change_model
    exit
fi

printf "\n${BOLD}=== IronClaw Setup ===${RESET}\n\n"

if [ -f "$ENV_FILE" ]; then
    ok ".env found at $ENV_FILE"
    echo ""
    echo "  [1] Fresh install (overwrites existing setup)"
    echo "  [2] Change default model"
    echo "  [q] Quit"
else
    echo "  [1] Install IronClaw"
    echo "  [q] Quit"
fi

echo ""
ask "Select:"
read -r sel

case "$sel" in
    1) run_install ;;
    2) change_model ;;
    q|Q) echo "Bye." ;;
    *) echo "Invalid." ;;
esac
