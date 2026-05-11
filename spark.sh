#!/bin/bash
# spark.sh — DGX Spark Inference Stack — main control panel

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

GREEN='\033[32m'
CYAN='\033[36m'
YELLOW='\033[33m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

svc_status() {
    if systemctl --user is-active --quiet "$1" 2>/dev/null; then
        printf "${GREEN}running${RESET}"
    elif systemctl is-active --quiet "$1" 2>/dev/null; then
        printf "${GREEN}running${RESET}"
    else
        printf "${DIM}stopped${RESET}"
    fi
}

# ── Banner ────────────────────────────────────────────────────────────────────
print_banner() {
    printf "${BOLD}"
    echo "  ╔══════════════════════════════════════════════════════════════╗"
    echo "  ║           DGX Spark — Personal Inference Stack              ║"
    echo "  ║     NVIDIA GB10 · 128 GB unified · SM12.1 Blackwell         ║"
    echo "  ╚══════════════════════════════════════════════════════════════╝"
    printf "${RESET}"
    echo ""
    printf "${DIM}"
    echo "  LOGICAL FLOW"
    echo "  ────────────────────────────────────────────────────────────────"
    echo "  1. vLLM models     Serve local LLMs (ports 8000-8004)."
    echo "                     Each recipe is a YAML in recipes/ — launch"
    echo "                     with run.sh, stop to free RAM."
    echo ""
    echo "  2. LiteLLM proxy   Single OpenAI-compatible endpoint (port 4000)."
    echo "                     Routes by model name to the right vLLM port."
    echo "                     IronClaw and Open WebUI both point here."
    echo ""
    echo "  3. IronClaw        AI agent with Telegram + CLI. Uses LiteLLM"
    echo "                     to pick a model. Change active model with"
    echo "                     setup.sh — updates DB + .env + last_model."
    echo ""
    echo "  4. Open WebUI      Browser chat UI at localhost:3000."
    echo "                     Connects to LiteLLM proxy."
    echo ""
    echo "  AFTER REBOOT  →  run Recovery [1] or let the watchdog handle it."
    echo "  ────────────────────────────────────────────────────────────────"
    printf "${RESET}"
}

# ── Live status ───────────────────────────────────────────────────────────────
print_status() {
    local total avail used
    total=$(awk '/MemTotal/{printf "%.0f",    $2/1048576}' /proc/meminfo)
    avail=$(awk '/MemAvailable/{printf "%.0f", $2/1048576}' /proc/meminfo)
    used=$(( total - avail ))

    local hf_cache disk_total disk_used disk_free
    hf_cache="${HF_HOME:-$HOME/.cache/huggingface}/hub"
    read -r disk_total disk_used disk_free < <(
        df "$hf_cache" 2>/dev/null | awk 'NR==2{printf "%.0f %.0f %.0f\n", $2/1048576, $3/1048576, $4/1048576}'
    )

    echo ""
    printf "  ${BOLD}System${RESET}    %sGB / %sGB RAM used  (%sGB free)\n" "$used" "$total" "$avail"
    printf "  ${BOLD}Storage${RESET}   %sGB / %sGB used  (%sGB free)\n" "$disk_used" "$disk_total" "$disk_free"

    # Running vLLM containers
    local vllm_running
    vllm_running=$(docker ps --format "{{.Names}}" 2>/dev/null | grep "^vllm" | tr '\n' '  ' || true)
    if [ -n "$vllm_running" ]; then
        printf "  ${BOLD}Models${RESET}    ${GREEN}%s${RESET}\n" "$vllm_running"
    else
        printf "  ${BOLD}Models${RESET}    ${DIM}none running${RESET}\n"
    fi

    # Active embedding model from systemd service + port check
    local embed_status embed_detail
    if curl -sf http://127.0.0.1:8010/embeddings >/dev/null 2>&1; then
        embed_status="${GREEN}running${RESET}"
        embed_detail="  port 8010"
        # Try to extract model name from llama-embed service
        embed_model=$(systemctl --user show llama-embed --property=EnvironmentFile 2>/dev/null | grep -oP 'MODELS=\K\S+' || true)
    elif curl -sf http://127.0.0.1:8010/ >/dev/null 2>&1; then
        embed_status="${GREEN}running${RESET}"
        embed_detail="  port 8010 (warmup)"
    else
        embed_status="${DIM}stopped${RESET}"
        embed_detail=""
    fi
    if [ "$embed_status" != "${DIM}stopped${RESET}" ]; then
        printf "  ${BOLD}Embedding${RESET} ${embed_status}${RESET}${DIM}  ${embed_detail}${RESET}\n"
    else
        printf "  ${BOLD}Embedding${RESET} ${DIM}stopped${RESET}\n"
    fi

    printf "  ${BOLD}LiteLLM${RESET}   %s\n"   "$(svc_status litellm)"
    printf "  ${BOLD}IronClaw${RESET}  %s\n"   "$(svc_status ironclaw)"
    printf "  ${BOLD}PostgreSQL${RESET}  %s  (ironclaw@5432)\n" "$(svc_status postgresql)"

    # Open WebUI
    if docker inspect open-webui --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
        local port
        port=$(docker inspect open-webui --format '{{(index (index .HostConfig.PortBindings "8080/tcp") 0).HostPort}}' 2>/dev/null)
        port=${port:-3000}
        printf "  ${BOLD}WebUI${RESET}     ${GREEN}running${RESET}  → http://localhost:%s\n" "$port"
    else
        printf "  ${BOLD}WebUI${RESET}     ${DIM}stopped${RESET}\n"
    fi

    # Last model + watchdog
    local last_model=""
    [ -f "$HOME/.ironclaw/last_model" ] && last_model=$(cat "$HOME/.ironclaw/last_model" | tr -d '[:space:]')
    [ -n "$last_model" ] && printf "  ${BOLD}Last model${RESET} %s\n" "$last_model"

    if systemctl --user is-enabled --quiet spark-watchdog.timer 2>/dev/null; then
        printf "  ${BOLD}Watchdog${RESET}  ${GREEN}enabled${RESET}  (fires 5 min after boot)\n"
    fi

    echo ""
}

# ── Mode switcher ─────────────────────────────────────────────────────────────
switch_mode() {
    local RECIPES_DIR="$REPO_DIR/recipes"

    mapfile -t MODES < <(
        find "$RECIPES_DIR" -mindepth 1 -maxdepth 1 -type d | while read -r d; do
            count=$(find "$d" -name "*.yaml" | wc -l)
            [ "$count" -gt 0 ] && basename "$d"
        done | sort
    )

    if [ ${#MODES[@]} -eq 0 ]; then
        echo "  No mode directories found in $RECIPES_DIR"
        return
    fi

    printf "\n${BOLD}=== Switch Mode ===${RESET}\n\n"

    local current_container
    current_container=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^(vllm|atlas)[-_]' | head -1 || true)
    if [ -n "$current_container" ]; then
        printf "  Current: ${GREEN}%s${RESET}\n\n" "$current_container"
    else
        printf "  Current: ${DIM}none running${RESET}\n\n"
    fi

    local idx=0
    declare -a RECIPE_FILES RECIPE_LABELS

    for mode in "${MODES[@]}"; do
        printf "  ${BOLD}[%s]${RESET}\n" "$mode"
        while IFS= read -r yaml; do
            local slug name port
            slug=$(basename "$yaml" .yaml)
            name=$(python3 -c "
import re
raw=open('$yaml').read()
m=re.search(r'^name:\s*(.+)', raw, re.MULTILINE)
print(m.group(1).strip() if m else '$slug')
" 2>/dev/null)
            port=$(python3 -c "
import re
raw=open('$yaml').read()
m=re.search(r'port:\s*(\d+)', raw)
print(m.group(1) if m else '?')
" 2>/dev/null)
            printf "    ${CYAN}[%s]${RESET}  %-40s port %s\n" "$((idx+1))" "$name" "$port"
            RECIPE_FILES+=("$yaml")
            RECIPE_LABELS+=("$mode/$slug")
            ((idx++))
        done < <(find "$RECIPES_DIR/$mode" -name "*.yaml" | sort)
        echo ""
    done

    echo "  [q] Cancel"
    echo ""
    read -rp "  Select recipe (1-${#RECIPE_FILES[@]}): " sel
    [[ "${sel,,}" == "q" ]] && return
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "${#RECIPE_FILES[@]}" ]; then
        echo "  Invalid."; return
    fi

    local chosen_file="${RECIPE_FILES[$((sel-1))]}"
    local chosen_label="${RECIPE_LABELS[$((sel-1))]}"

    local model port image env_flag cmd slug
    slug=$(basename "$chosen_file" .yaml)
    model=$(python3 -c "import re; raw=open('$chosen_file').read(); m=re.search(r'^model:\s*(.+)',raw,re.MULTILINE); print(m.group(1).strip())" 2>/dev/null)
    port=$(python3 -c "import re; raw=open('$chosen_file').read(); m=re.search(r'port:\s*(\d+)',raw); print(m.group(1))" 2>/dev/null)
    image=$(python3 -c "import re; raw=open('$chosen_file').read(); m=re.search(r'container:\s*(\S+)',raw); print(m.group(1) if m else 'vllm-node')" 2>/dev/null)
    image="${image:-vllm-node}"

    env_flag=$(python3 -c "
import re
raw=open('$chosen_file').read()
m=re.search(r'^env:\s*\n((?:[ \t]+.+\n?)*)', raw, re.MULTILINE)
if m:
    flags=[]
    for line in m.group(1).splitlines():
        kv=re.match(r'\s+(\w+):\s*(.+)', line)
        if kv: flags.append(f'-e {kv.group(1)}={kv.group(2).strip()}')
    print(' '.join(flags))
" 2>/dev/null)

    cmd=$(python3 -c "
import re, sys
raw = open('$chosen_file').read()
cmd_m = re.search(r'^command:\s*\|\s*\n((?:[ \t]+.+\n?)*)', raw, re.MULTILINE)
if not cmd_m: sys.exit(1)
cmd = cmd_m.group(1)
defaults = {}
dm = re.search(r'^defaults:\s*\n((?:[ \t]+.+\n?)*)', raw, re.MULTILINE)
if dm:
    for line in dm.group(1).splitlines():
        kv = re.match(r'\s+(\w+):\s*(.+)', line)
        if kv: defaults[kv.group(1)] = kv.group(2).strip()
for k,v in defaults.items():
    cmd = cmd.replace('{'+k+'}', v)
print(cmd.strip())
" 2>/dev/null)

    # Check if this exact model is already serving on the target port
    local already_running
    already_running=$(curl -sf --max-time 2 "http://127.0.0.1:${port}/v1/models" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null)
    if [ -n "$already_running" ] && [ -n "$model" ] && [ "$already_running" = "$model" ]; then
        printf "\n  ${GREEN}✓${RESET} %s is already running on port %s — nothing to do.\n" "$model" "$port"
        return
    fi

    printf "\n  ${BOLD}Switching to: %s${RESET}\n" "$chosen_label"
    printf "  Model:  %s\n" "$model"
    printf "  Port:   %s\n" "$port"
    echo ""
    read -rp "  Confirm switch? [y/N]: " confirm
    [[ "${confirm,,}" == "y" ]] || { echo "  Cancelled."; return; }
    echo ""

    # Stop all running vllm/atlas containers
    local running
    mapfile -t running < <(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^(vllm|atlas)[-_]' || true)
    if [ ${#running[@]} -gt 0 ]; then
        for c in "${running[@]}"; do
            printf "  → Stopping %s (timeout 25s)..." "$c"
            docker stop --timeout 25 "$c" 2>/dev/null && docker rm "$c" 2>/dev/null \
                && printf " ${GREEN}done${RESET}\n" || printf " ${YELLOW}forced${RESET}\n"
        done
    fi

    local has_mods
    has_mods=$(python3 -c "
import re
raw = open('$chosen_file').read()
m = re.search(r'^mods:\s*\n((?:[ \t]+.+\n?)+)', raw, re.MULTILINE)
print('yes' if m else 'no')
" 2>/dev/null)

    if [ "$has_mods" = "yes" ]; then
        # Delegate entirely to run.sh — it handles mods, logging, and health wait
        local rel_slug
        rel_slug=$(realpath --relative-to="$RECIPES_DIR" "$chosen_file" | sed 's/\.yaml$//')
        printf "  → Using run.sh (recipe has mods)\n"
        echo "$rel_slug" > "$HOME/.ironclaw/last_model"
        bash "$REPO_DIR/scripts/run.sh" "$rel_slug" -d
    else
        printf "  → Starting vllm-%s...\n" "$slug"
        docker run -d \
            --name "vllm-${slug}" \
            --network host --gpus all --ipc=host \
            $env_flag \
            -v ~/.cache/huggingface:/root/.cache/huggingface \
            -v ~/.cache/vllm:/root/.cache/vllm \
            -v ~/.triton:/root/.triton \
            "$image" \
            bash -c "$cmd"

        echo "$slug" > "$HOME/.ironclaw/last_model"

        # Stream logs while waiting for model to be ready (max 20 min)
        echo ""
        echo "--- Logs (port ${port} — CUDA graph capture ~5-10 min) ---"
        docker logs -f "vllm-${slug}" 2>&1 &
        local logs_pid=$!

        local ready=0
        for i in $(seq 1 240); do
            sleep 5
            if curl -sf "http://127.0.0.1:${port}/health" >/dev/null 2>&1; then
                ready=1
                break
            fi
        done

        kill "$logs_pid" 2>/dev/null
        wait "$logs_pid" 2>/dev/null
        echo ""

        if [ "$ready" -eq 1 ]; then
            printf "  ${GREEN}✓${RESET} vllm-%s ready on port %s (%ss)\n" "$slug" "$port" "$((i * 5))"
        else
            printf "  ${YELLOW}⚠${RESET} Timeout after 20 min — check: docker logs vllm-%s\n" "$slug"
        fi
    fi

    local mode_dir litellm_alias
    mode_dir=$(dirname "$chosen_file" | xargs basename)
    # Look up the LiteLLM model_name that points to this port and model
    litellm_alias=$(python3 -c "
import re, sys
try:
    raw = open(sys.argv[1]).read()
    port = sys.argv[2]
    hf_model = sys.argv[3] if len(sys.argv) > 3 else ''
    blocks = re.findall(r'(model_name:\s*\S+(?:(?!model_name:).)*)', raw, re.DOTALL)
    best = ''
    for block in blocks:
        if not re.search(r'api_base:\s*http://[^:]+:' + port + r'\b', block):
            continue
        name = re.search(r'model_name:\s*(\S+)', block).group(1)
        if hf_model and re.search(re.escape(hf_model), block):
            print(name); sys.exit(0)
        if not best:
            best = name
    print(best)
except: pass
" "$HOME/.litellm/litellm_config.yaml" "$port" "$model" 2>/dev/null)
    if [ -z "$litellm_alias" ]; then
        printf "  ${YELLOW}⚠${RESET} No LiteLLM alias found for port %s — IronClaw model not updated\n" "$port"
    fi

    # Write opencode.json when switching to opencode or ironclaw mode (shared vLLM backend)
    if [ "$mode_dir" = "opencode" ] || [ "$mode_dir" = "ironclaw" ]; then
        local ctx_limit output_limit
        ctx_limit=$(python3 -c "
import re
raw=open('$chosen_file').read()
m=re.search(r'max_model_len:\s*(\d+)', raw)
print(m.group(1) if m else '131072')
" 2>/dev/null)
        output_limit=$(python3 -c "
import re
raw=open('$chosen_file').read()
m=re.search(r'max_num_batched_tokens:\s*(\d+)', raw)
print(m.group(1) if m else '65536')
" 2>/dev/null)
        mkdir -p "$HOME/.config/opencode"
        python3 - "$model" "$port" "$ctx_limit" "$output_limit" "$chosen_file" << 'PYEOF' > "$HOME/.config/opencode/opencode.json"
import json, sys, re
model, port, ctx, out, recipe = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
raw = open(recipe).read()
m = re.search(r'served.model.name:\s*(\S+)', raw)
served_name = m.group(1) if m else model
print(json.dumps({
    "$schema": "https://opencode.ai/config.json",
    "model": f"vllm/{served_name}",
    "provider": {
        "vllm": {
            "npm": "@ai-sdk/openai-compatible",
            "name": "vLLM (local)",
            "options": {"baseURL": f"http://127.0.0.1:{port}/v1"},
            "models": {
                served_name: {
                    "name": served_name,
                    "limit": {"context": ctx, "output": out}
                }
            }
        }
    }
}, indent=2))
PYEOF
        printf "  ${GREEN}✓${RESET} opencode.json written (~/.config/opencode/opencode.json)\n"
    fi

    # Always update IronClaw selected_model to the running model's LiteLLM alias
    if [ -n "$litellm_alias" ] && [ -f "$HOME/.ironclaw/.env" ]; then
        set -o allexport; source "$HOME/.ironclaw/.env"; set +o allexport
        psql "${DATABASE_URL}" -c "
            INSERT INTO settings (user_id, key, value)
            VALUES ('default', 'selected_model', '\"${litellm_alias}\"')
            ON CONFLICT (user_id, key) DO UPDATE SET value = '\"${litellm_alias}\"';
        " >/dev/null 2>&1 \
            && printf "  ${GREEN}✓${RESET} IronClaw model set to ${BOLD}%s${RESET}\n" "$litellm_alias" \
            || printf "  ${YELLOW}⚠${RESET} DB update failed — set model manually in setup.sh\n"
    fi

    systemctl --user restart litellm 2>/dev/null && sleep 2
    systemctl --user restart ironclaw 2>/dev/null

    printf "\n  ${GREEN}✓${RESET} Mode switched to ${BOLD}%s${RESET}\n" "$chosen_label"
}

# ── Menu ──────────────────────────────────────────────────────────────────────
print_menu() {
    echo "  ────────────────────────────────────────────────────────────────"
    printf "  ${BOLD}[1]${RESET} Recovery & Watchdog   ${DIM}start-all.sh${RESET}\n"
    printf "  ${BOLD}[2]${RESET} Models                ${DIM}run.sh  (launch · unload · download)${RESET}\n"
    printf "  ${BOLD}[3]${RESET} Benchmark             ${DIM}benchmark.sh${RESET}\n"
    printf "  ${BOLD}[4]${RESET} Open WebUI            ${DIM}webui.sh${RESET}\n"
    printf "  ${BOLD}[5]${RESET} Switch Mode           ${DIM}ironclaw · opencode${RESET}\n"
    printf "  ${BOLD}[6]${RESET} IronClaw Setup        ${DIM}setup.sh  (install · change model)${RESET}\n"
    printf "  ${BOLD}[7]${RESET} Reset IronClaw        ${DIM}reset-ironclaw.sh${RESET}\n"
    echo "  ────────────────────────────────────────────────────────────────"
    printf "  ${BOLD}[q]${RESET} Quit\n"
    echo ""
}

# ── Main loop ─────────────────────────────────────────────────────────────────
while true; do
    clear
    print_banner
    print_status
    print_menu
    read -rp "  Select: " sel
    echo ""

    case "$sel" in
        1) bash "$REPO_DIR/scripts/start-all.sh" ;;
        2) bash "$REPO_DIR/scripts/run.sh" ;;
        3) bash "$REPO_DIR/scripts/benchmark.sh" ;;
        4) bash "$REPO_DIR/scripts/webui.sh" ;;
        5) switch_mode ;;
        6) bash "$REPO_DIR/ironclaw/setup.sh" ;;
        7) bash "$REPO_DIR/ironclaw/reset-ironclaw.sh" ;;
        q|Q) echo "  Bye."; break ;;
        *) echo "  Invalid." ;;
    esac

    echo ""
    read -rp "  Press Enter to return to menu..." _
done
