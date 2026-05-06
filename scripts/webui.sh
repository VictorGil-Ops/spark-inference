#!/bin/bash
# webui.sh — Open WebUI management for DGX Spark
# Usage: ./scripts/webui.sh            — interactive menu
#        ./scripts/webui.sh install    — first install
#        ./scripts/webui.sh start      — start container
#        ./scripts/webui.sh stop       — stop container
#        ./scripts/webui.sh restart    — restart container
#        ./scripts/webui.sh status     — show status
#        ./scripts/webui.sh port <N>   — change host port
#        ./scripts/webui.sh update     — pull latest image + recreate
#        ./scripts/webui.sh remove     — stop and remove container

CONTAINER="open-webui"
IMAGE="ghcr.io/open-webui/open-webui:main"
CONF_FILE="$HOME/.ironclaw/webui.conf"
DEFAULT_PORT=3000
LITELLM_URL="http://host.docker.internal:4000/v1"
LITELLM_KEY="sk-no-key"

GREEN='\033[32m'
CYAN='\033[36m'
RED='\033[31m'
BOLD='\033[1m'
RESET='\033[0m'

ok()   { printf "  ${GREEN}✓${RESET} %s\n" "$*"; }
info() { printf "  → %s\n" "$*"; }
err()  { printf "  ${RED}✗${RESET} %s\n" "$*"; }

# ── Port persistence ──────────────────────────────────────────────────────────
get_port() {
    if [ -f "$CONF_FILE" ]; then
        grep '^PORT=' "$CONF_FILE" | cut -d= -f2
    else
        echo "$DEFAULT_PORT"
    fi
}

save_port() {
    mkdir -p "$(dirname "$CONF_FILE")"
    grep -v '^PORT=' "$CONF_FILE" 2>/dev/null > "${CONF_FILE}.tmp" || true
    echo "PORT=$1" >> "${CONF_FILE}.tmp"
    mv "${CONF_FILE}.tmp" "$CONF_FILE"
}

# ── Container state ───────────────────────────────────────────────────────────
is_installed() { docker inspect "$CONTAINER" >/dev/null 2>&1; }
is_running()   { docker inspect "$CONTAINER" --format '{{.State.Running}}' 2>/dev/null | grep -q true; }

# ── Docker run ────────────────────────────────────────────────────────────────
do_run() {
    local port="$1"
    docker run -d \
        --name "$CONTAINER" \
        --restart unless-stopped \
        --add-host=host.docker.internal:host-gateway \
        -p "${port}:8080" \
        -e OPENAI_API_BASE_URL="$LITELLM_URL" \
        -e OPENAI_API_KEY="$LITELLM_KEY" \
        -v open-webui:/app/backend/data \
        "$IMAGE"
}

# ── Commands ──────────────────────────────────────────────────────────────────
cmd_install() {
    if is_installed; then
        err "Container '${CONTAINER}' already exists. Use 'start' or 'update'."
        exit 1
    fi
    local port
    port=$(get_port)
    info "Pulling image..."
    docker pull "$IMAGE"
    info "Starting Open WebUI on port ${port}..."
    do_run "$port"
    save_port "$port"
    echo ""
    ok "Open WebUI running at http://localhost:${port}"
    info "LiteLLM endpoint: ${LITELLM_URL}"
}

cmd_start() {
    if ! is_installed; then
        err "Not installed. Run: $0 install"
        exit 1
    fi
    if is_running; then
        ok "Already running"
        return
    fi
    docker start "$CONTAINER"
    ok "Started — http://localhost:$(get_port)"
}

cmd_stop() {
    is_running || { ok "Already stopped"; return; }
    docker stop "$CONTAINER"
    ok "Stopped"
}

cmd_restart() {
    docker restart "$CONTAINER" 2>/dev/null || { err "Container not found"; exit 1; }
    ok "Restarted — http://localhost:$(get_port)"
}

cmd_status() {
    local port
    port=$(get_port)
    echo ""
    if ! is_installed; then
        printf "  Status  : not installed\n"
    elif is_running; then
        printf "  Status  : ${GREEN}running${RESET}\n"
        printf "  URL     : ${CYAN}http://localhost:%s${RESET}\n" "$port"
        printf "  LiteLLM : %s\n" "$LITELLM_URL"
        # Check LiteLLM reachable
        curl -sf http://127.0.0.1:4000/v1/models \
            -H "Authorization: Bearer ${LITELLM_KEY}" >/dev/null 2>&1 \
            && printf "  Proxy   : ${GREEN}✓ reachable${RESET}\n" \
            || printf "  Proxy   : ${RED}✗ LiteLLM not responding${RESET}\n"
    else
        printf "  Status  : stopped\n"
        printf "  Port    : %s (last used)\n" "$port"
    fi
    echo ""
}

cmd_port() {
    local new_port="$1"
    if ! [[ "$new_port" =~ ^[0-9]+$ ]] || [ "$new_port" -lt 1024 ] || [ "$new_port" -gt 65535 ]; then
        err "Invalid port: ${new_port}"
        exit 1
    fi

    local old_port
    old_port=$(get_port)

    if is_running; then
        info "Stopping container..."
        docker stop "$CONTAINER" >/dev/null
    fi
    if is_installed; then
        info "Removing container (volume preserved)..."
        docker rm "$CONTAINER" >/dev/null
    fi

    save_port "$new_port"
    info "Starting on new port ${new_port}..."
    do_run "$new_port"
    ok "Port changed: ${old_port} → ${new_port}"
    ok "URL: http://localhost:${new_port}"
}

cmd_update() {
    local port
    port=$(get_port)
    info "Pulling latest image..."
    docker pull "$IMAGE"
    if is_running; then
        docker stop "$CONTAINER" >/dev/null
    fi
    if is_installed; then
        docker rm "$CONTAINER" >/dev/null
    fi
    info "Recreating container on port ${port}..."
    do_run "$port"
    ok "Updated and running at http://localhost:${port}"
}

cmd_remove() {
    read -rp "  Remove Open WebUI container (data volume preserved)? [y/N]: " c
    [[ "$c" =~ ^[yY] ]] || { echo "Cancelled."; return; }
    is_running && docker stop "$CONTAINER" >/dev/null
    docker rm "$CONTAINER" >/dev/null 2>&1 || true
    ok "Container removed (volume 'open-webui' kept)"
}

# ── Interactive menu ──────────────────────────────────────────────────────────
show_menu() {
    local port
    port=$(get_port)

    printf "\n${BOLD}=== Open WebUI ===${RESET}\n"
    cmd_status

    if ! is_installed; then
        echo "  [1] Install"
    elif is_running; then
        echo "  [1] Stop"
        echo "  [2] Restart"
        echo "  [3] Change port  (current: ${port})"
        echo "  [4] Update  (pull latest)"
        echo "  [5] Remove"
    else
        echo "  [1] Start"
        echo "  [2] Change port  (current: ${port})"
        echo "  [3] Update  (pull latest)"
        echo "  [4] Remove"
    fi
    echo "  [q] Quit"
    echo ""
    read -rp "Select: " sel

    echo ""
    if ! is_installed; then
        case "$sel" in
            1) cmd_install ;;
            q|Q) echo "Bye." ;;
            *) echo "Invalid." ;;
        esac
    elif is_running; then
        case "$sel" in
            1) cmd_stop ;;
            2) cmd_restart ;;
            3)
                read -rp "  New port [${port}]: " np
                cmd_port "${np:-$port}"
                ;;
            4) cmd_update ;;
            5) cmd_remove ;;
            q|Q) echo "Bye." ;;
            *) echo "Invalid." ;;
        esac
    else
        case "$sel" in
            1) cmd_start ;;
            2)
                read -rp "  New port [${port}]: " np
                cmd_port "${np:-$port}"
                ;;
            3) cmd_update ;;
            4) cmd_remove ;;
            q|Q) echo "Bye." ;;
            *) echo "Invalid." ;;
        esac
    fi
}

# ── Entry point ───────────────────────────────────────────────────────────────
case "${1:-}" in
    install) cmd_install ;;
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    restart) cmd_restart ;;
    status)  cmd_status ;;
    port)    cmd_port "${2:-}" ;;
    update)  cmd_update ;;
    remove)  cmd_remove ;;
    *)       show_menu ;;
esac
