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
    systemctl --user is-active --quiet "$1" 2>/dev/null \
        && printf "${GREEN}running${RESET}" || printf "${DIM}stopped${RESET}"
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

    printf "  ${BOLD}LiteLLM${RESET}   %s\n"   "$(svc_status litellm)"
    printf "  ${BOLD}IronClaw${RESET}  %s\n"   "$(svc_status ironclaw)"

    # Open WebUI
    if docker inspect open-webui --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
        local port
        port=$(cat "$HOME/.ironclaw/webui.conf" 2>/dev/null | grep '^PORT=' | cut -d= -f2 || echo 3000)
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

# ── Menu ──────────────────────────────────────────────────────────────────────
print_menu() {
    echo "  ────────────────────────────────────────────────────────────────"
    printf "  ${BOLD}[1]${RESET} Recovery & Watchdog   ${DIM}start-all.sh${RESET}\n"
    printf "  ${BOLD}[2]${RESET} Models                ${DIM}run.sh  (launch · unload · download)${RESET}\n"
    printf "  ${BOLD}[3]${RESET} Benchmark             ${DIM}benchmark.sh${RESET}\n"
    printf "  ${BOLD}[4]${RESET} Open WebUI            ${DIM}webui.sh${RESET}\n"
    printf "  ${BOLD}[5]${RESET} IronClaw Setup        ${DIM}setup.sh  (install · change model)${RESET}\n"
    printf "  ${BOLD}[6]${RESET} Reset IronClaw        ${DIM}reset-ironclaw.sh${RESET}\n"
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
        5) bash "$REPO_DIR/ironclaw/setup.sh" ;;
        6) bash "$REPO_DIR/scripts/reset-ironclaw.sh" ;;
        q|Q) echo "  Bye."; break ;;
        *) echo "  Invalid." ;;
    esac

    echo ""
    read -rp "  Press Enter to return to menu..." _
done
