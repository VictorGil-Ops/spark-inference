#!/bin/bash
# start-all.sh — Recovery and startup manager for DGX Spark
# Usage: ./scripts/start-all.sh                   — interactive menu
#        ./scripts/start-all.sh --auto             — watchdog auto-recovery
#        ./scripts/start-all.sh --install-watchdog
#        ./scripts/start-all.sh --uninstall-watchdog

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RECIPES_DIR="$REPO_DIR/recipes"
LAST_MODEL_FILE="$HOME/.ironclaw/last_model"
WATCHDOG_SERVICE="$HOME/.config/systemd/user/spark-watchdog.service"
WATCHDOG_TIMER="$HOME/.config/systemd/user/spark-watchdog.timer"

GREEN='\033[32m'
CYAN='\033[36m'
BOLD='\033[1m'
RESET='\033[0m'

ok()   { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
info() { printf "  → %s\n" "$*"; }

# ── Helpers ───────────────────────────────────────────────────────────────────
total_gb() { awk '/MemTotal/{printf "%.0f",    $2/1048576}' /proc/meminfo; }
avail_gb() { awk '/MemAvailable/{printf "%.0f", $2/1048576}' /proc/meminfo; }

recipe_ram() {
    local yaml="$RECIPES_DIR/${1}.yaml"
    [ -f "$yaml" ] || { echo 0; return; }
    python3 -c "
import re
raw = open('$yaml').read()
m = re.search(r'#\s*(?:Memory|RAM):\s*~?(\d+)GB', raw, re.IGNORECASE)
if m: print(m.group(1))
else:
    u = re.search(r'gpu_memory_utilization:\s*([\d.]+)', raw)
    print(round(float(u.group(1)) * 128) if u else 0)
" 2>/dev/null || echo 0
}

# ── Network ───────────────────────────────────────────────────────────────────
ensure_network() {
    if ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        ok "Network OK"
        return
    fi
    info "Network unavailable — reconnecting..."
    if command -v nmcli &>/dev/null; then
        nmcli networking off 2>/dev/null || true
        sleep 2
        nmcli networking on 2>/dev/null || true
        sleep 5
    fi
    ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1 \
        && ok "Network reconnected" \
        || echo "  ⚠ Network still unavailable — continuing anyway"
}

# ── Services ──────────────────────────────────────────────────────────────────
ensure_litellm() {
    if systemctl --user is-active --quiet litellm; then
        ok "LiteLLM already running"
        return
    fi
    info "Starting LiteLLM..."
    systemctl --user start litellm
    for i in $(seq 1 15); do
        sleep 1
        curl -sf http://127.0.0.1:4000/v1/models \
            -H "Authorization: Bearer sk-no-key" >/dev/null 2>&1 && break
    done
    ok "LiteLLM ready"
}

ensure_ironclaw() {
    if systemctl --user is-active --quiet ironclaw; then
        ok "IronClaw already running"
        return
    fi
    info "Starting IronClaw..."
    systemctl --user start ironclaw
    sleep 3
    systemctl --user is-active --quiet ironclaw \
        && ok "IronClaw running" \
        || echo "  ✗ IronClaw failed — check: journalctl --user -u ironclaw -n 20"
}

# ── Model launch with RAM guard ───────────────────────────────────────────────
launch_last_model() {
    local slug="$1"
    local ram total threshold
    ram=$(recipe_ram "$slug")
    total=$(total_gb)
    threshold=$(( total * 97 / 100 ))

    if [ "$ram" -gt "$threshold" ] 2>/dev/null; then
        echo "  ⚠ Skipping ${slug} — requires ${ram}GB > ${threshold}GB (97% of ${total}GB)"
        return 1
    fi

    info "Launching: ${slug} (~${ram}GB)"
    bash "$REPO_DIR/scripts/run.sh" "$slug"
}

# ── Watchdog install / remove ─────────────────────────────────────────────────
install_watchdog() {
    local script_path
    script_path="$(realpath "$0")"
    mkdir -p "$(dirname "$WATCHDOG_SERVICE")"

    cat > "$WATCHDOG_SERVICE" << EOF
[Unit]
Description=DGX Spark Watchdog — auto-recover inference stack
After=network-online.target

[Service]
Type=oneshot
ExecStart=${script_path} --auto
StandardOutput=journal
StandardError=journal
EOF

    cat > "$WATCHDOG_TIMER" << EOF
[Unit]
Description=DGX Spark Watchdog Timer

[Timer]
OnBootSec=5min
Unit=spark-watchdog.service

[Install]
WantedBy=timers.target
EOF

    systemctl --user daemon-reload
    systemctl --user enable --now spark-watchdog.timer
    sudo loginctl enable-linger "$USER" 2>/dev/null \
        && ok "Lingering enabled (starts without login session)" \
        || info "Run 'sudo loginctl enable-linger $USER' to start without login"
    echo ""
    ok "Watchdog installed — fires 5 min after every boot"
    info "Status: systemctl --user status spark-watchdog.timer"
}

uninstall_watchdog() {
    systemctl --user disable --now spark-watchdog.timer 2>/dev/null || true
    rm -f "$WATCHDOG_SERVICE" "$WATCHDOG_TIMER"
    systemctl --user daemon-reload
    ok "Watchdog removed"
}

watchdog_enabled() {
    systemctl --user is-enabled --quiet spark-watchdog.timer 2>/dev/null
}

# ── Auto-recovery (called by watchdog) ───────────────────────────────────────
auto_recover() {
    echo "=== DGX Spark Watchdog — $(date) ==="
    echo ""

    ensure_network

    local slug=""
    [ -f "$LAST_MODEL_FILE" ] && slug=$(cat "$LAST_MODEL_FILE" | tr -d '[:space:]')

    echo ""
    if [ -n "$slug" ]; then
        info "Last model: ${slug}"
        launch_last_model "$slug" || true
    else
        echo "  ⚠ No last model saved — skipping model launch"
    fi

    echo ""
    ensure_litellm
    ensure_ironclaw

    echo ""
    echo "=== Recovery complete — $(date) ==="
}

# ── Interactive menu ──────────────────────────────────────────────────────────
show_menu() {
    local total avail used slug ram

    total=$(total_gb)
    avail=$(avail_gb)
    used=$(( total - avail ))
    slug=""
    [ -f "$LAST_MODEL_FILE" ] && slug=$(cat "$LAST_MODEL_FILE" | tr -d '[:space:]')
    ram=$(recipe_ram "$slug")

    printf "\n${BOLD}=== DGX Spark — Startup ===${RESET}\n\n"
    printf "Memory   : %sGB used / %sGB total  (%sGB free)\n" "$used" "$total" "$avail"
    if [ -n "$slug" ]; then
        printf "Last model: %s (~%sGB)\n" "$slug" "$ram"
    else
        printf "Last model: ${CYAN}none${RESET}\n"
    fi
    if watchdog_enabled; then
        printf "Watchdog  : ${GREEN}enabled${RESET} (fires 5 min after boot)\n"
    else
        printf "Watchdog  : disabled\n"
    fi
    echo ""

    if [ -n "$slug" ]; then
        printf "  [1] Recover   %s + LiteLLM + IronClaw\n" "$slug"
    else
        printf "  [1] Recover   LiteLLM + IronClaw\n"
    fi
    echo "  [2] Launch model  →  run.sh picker"
    echo "  [3] LiteLLM only"
    echo "  [4] IronClaw only"
    if watchdog_enabled; then
        echo "  [5] Remove watchdog"
    else
        echo "  [5] Install watchdog  (auto-start 5 min after boot)"
    fi
    echo "  [q] Quit"
    echo ""
    read -rp "Select: " sel

    echo ""
    case "$sel" in
        1)
            ensure_network
            [ -n "$slug" ] && launch_last_model "$slug" || true
            ensure_litellm
            ensure_ironclaw
            ;;
        2) bash "$REPO_DIR/scripts/run.sh" ;;
        3) ensure_litellm ;;
        4) ensure_ironclaw ;;
        5) watchdog_enabled && uninstall_watchdog || install_watchdog ;;
        q|Q) echo "Bye." ;;
        *) echo "Invalid selection." ;;
    esac
}

# ── Entry point ───────────────────────────────────────────────────────────────
case "${1:-}" in
    --auto)               auto_recover ;;
    --install-watchdog)   install_watchdog ;;
    --uninstall-watchdog) uninstall_watchdog ;;
    *)                    show_menu ;;
esac
