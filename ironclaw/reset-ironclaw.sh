#!/bin/bash
# reset-ironclaw.sh
# Restores IronClaw to a clean running state.
#
# Fixes:
#   - Stale PID file
#   - Hung connection pool (TLS handshake errors)
#   - Service crash loop
#   - Port conflict on 3000
#
# Usage:
#   bash ~/repos/spark-inference/scripts/reset-ironclaw.sh

set -e

# Load ironclaw env — .env takes precedence over inherited shell vars
if [ -f "$HOME/.ironclaw/.env" ]; then
    set -o allexport
    source "$HOME/.ironclaw/.env"
    set +o allexport
fi
DB_URL="${DATABASE_URL:-}"
if [ -z "$DB_URL" ]; then
    echo "  ✗ DATABASE_URL not set — add it to ~/.ironclaw/.env"
    exit 1
fi

ok()   { echo "  ✓ $*"; }
fail() { echo "  ✗ $*"; }
info() { echo "  → $*"; }

echo "=== IronClaw Reset ==="
echo ""

# ── Step 1: Stop service ──────────────────────────────────────────────────────
echo "--- Stopping IronClaw ---"
systemctl --user stop ironclaw 2>/dev/null && ok "service stopped" || info "service was not running"
sleep 1

# Kill any leftover ironclaw processes
LEFTOVER=$(pgrep -f "ironclaw run" 2>/dev/null || true)
if [ -n "$LEFTOVER" ]; then
    info "killing leftover process(es): $LEFTOVER"
    kill $LEFTOVER 2>/dev/null || true
    sleep 1
fi

# ── Step 2: Clean up PID file ─────────────────────────────────────────────────
echo "--- Cleaning up PID file ---"
PID_FILE="$HOME/.ironclaw/ironclaw.pid"
if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
        info "process $OLD_PID still alive — killing"
        kill "$OLD_PID" 2>/dev/null || true
        sleep 1
    fi
    rm -f "$PID_FILE"
    ok "PID file removed ($OLD_PID)"
else
    ok "no stale PID file"
fi

# ── Step 3: Verify PostgreSQL ─────────────────────────────────────────────────
echo "--- Checking PostgreSQL ---"
if psql "$DB_URL" -c "SELECT 1;" > /dev/null 2>&1; then
    ok "PostgreSQL reachable"
else
    fail "PostgreSQL not responding"
    echo ""
    echo "  Fix with:"
    echo "    sudo systemctl start postgresql"
    exit 1
fi

# ── Step 3b: Postgres SSL check ──────────────────────────────────────────────
echo "--- Checking PostgreSQL SSL ---"
PG_SSL=$(psql "$DB_URL" -tAc "SHOW ssl;" 2>/dev/null | tr -d ' ')
if [ "$PG_SSL" = "on" ]; then
    info "SSL is on — ironclaw's driver can't handle self-signed certs, disabling"
    # ALTER SYSTEM requires superuser — use the postgres unix user via sudo
    if sudo -n -u postgres psql -c "ALTER SYSTEM SET ssl = off; SELECT pg_reload_conf();" > /dev/null 2>&1; then
        ok "SSL disabled via sudo postgres"
    else
        fail "could not disable SSL (need sudo access to postgres unix user)"
        echo "  Run manually:  sudo -u postgres psql -c \"ALTER SYSTEM SET ssl = off;\""
        echo "  Then:          sudo -u postgres psql -c \"SELECT pg_reload_conf();\""
        exit 1
    fi
else
    ok "SSL off — OK"
fi

# ── Step 4: Verify LiteLLM proxy ─────────────────────────────────────────────
echo "--- Checking LiteLLM proxy ---"
if curl -sf http://127.0.0.1:4000/v1/models \
    -H "Authorization: Bearer sk-no-key" > /dev/null 2>&1; then
    ok "LiteLLM proxy reachable on port 4000"
else
    fail "LiteLLM not responding — attempting restart"
    systemctl --user restart litellm
    for i in $(seq 1 15); do
        sleep 1
        if curl -sf http://127.0.0.1:4000/v1/models \
            -H "Authorization: Bearer sk-no-key" > /dev/null 2>&1; then
            ok "LiteLLM recovered"
            break
        fi
        if [ $i -eq 15 ]; then
            fail "LiteLLM still not responding"
            echo "  Check: journalctl --user -u litellm -n 30"
        fi
    done
fi

# ── Step 5: Check port 3000 (gateway) ────────────────────────────────────────
echo "--- Checking port 3000 ---"
PORT_OWNER=$(ss -tlnp 2>/dev/null | awk '/127.0.0.1:3000/{print $NF}' | grep -o '"[^"]*"' | head -1 || true)
if [ -n "$PORT_OWNER" ] && [[ "$PORT_OWNER" != *"ironclaw"* ]]; then
    info "port 3000 held by $PORT_OWNER (gateway will bind a different port or fail)"
else
    ok "port 3000 available"
fi

# ── Step 6: DB cleanup ───────────────────────────────────────────────────────
# Run before restart so ironclaw starts with a clean state
echo "--- DB cleanup ---"

# Jobs stuck in running/pending (ironclaw crashed mid-job)
STUCK=$(psql "$DB_URL" -tAc \
    "SELECT count(*) FROM agent_jobs WHERE status IN ('running','pending');" 2>/dev/null || echo 0)
if [ "$STUCK" -gt 0 ]; then
    psql "$DB_URL" -c \
        "UPDATE agent_jobs SET status='failed', updated_at=now()
         WHERE status IN ('running','pending');" > /dev/null
    ok "reset $STUCK stuck job(s) to failed"
else
    ok "no stuck jobs"
fi

# Expired pairing requests
EXPIRED=$(psql "$DB_URL" -tAc \
    "SELECT count(*) FROM pairing_requests WHERE expires_at < now() AND approved_at IS NULL;" 2>/dev/null || echo 0)
if [ "$EXPIRED" -gt 0 ]; then
    psql "$DB_URL" -c \
        "DELETE FROM pairing_requests WHERE expires_at < now() AND approved_at IS NULL;" > /dev/null
    ok "removed $EXPIRED expired pairing request(s)"
else
    ok "no expired pairing requests"
fi

# Terminate idle connections hanging in the pool (exclude our own)
IDLE=$(psql "$DB_URL" -tAc \
    "SELECT count(*) FROM pg_stat_activity
     WHERE datname='ironclaw' AND state='idle' AND pid <> pg_backend_pid();" 2>/dev/null || echo 0)
if [ "$IDLE" -gt 5 ]; then
    psql "$DB_URL" -c \
        "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
         WHERE datname='ironclaw' AND state='idle' AND pid <> pg_backend_pid();" > /dev/null
    ok "terminated $IDLE idle connection(s)"
else
    ok "idle connections OK ($IDLE)"
fi

# Only Telegram active — remove Slack from wasm_channels
psql "$DB_URL" -c \
    "UPDATE settings SET value = '[\"telegram\"]'
     WHERE key = 'channels.wasm_channels';" > /dev/null 2>&1 || true
ok "channels.wasm_channels = [telegram]"

# Gateway port 3002 — avoid conflicts with Open WebUI and other services on 3000/3001
psql "$DB_URL" -c \
    "INSERT INTO settings (user_id, key, value)
     VALUES ('default', 'channels.gateway_port', '3002')
     ON CONFLICT (user_id, key) DO UPDATE SET value = '3002';" > /dev/null 2>&1 || true
ok "channels.gateway_port = 3002"

# Remove channels.cli_mode from DB — prevents CLI_MODE warning at startup
psql "$DB_URL" -c \
    "DELETE FROM settings WHERE key = 'channels.cli_mode';" > /dev/null 2>&1 || true
ok "channels.cli_mode removed"

# ── Step 7: Start service ─────────────────────────────────────────────────────
echo "--- Starting IronClaw ---"
systemctl --user start ironclaw
sleep 3

# ── Step 8: Verify running ────────────────────────────────────────────────────
echo "--- Verifying ---"
if systemctl --user is-active --quiet ironclaw; then
    PID=$(systemctl --user show ironclaw --property=MainPID --value)
    ok "IronClaw running (PID $PID)"
else
    fail "IronClaw failed to start"
    echo ""
    echo "  Last logs:"
    journalctl --user -u ironclaw -n 20 --no-pager 2>&1 | sed 's/^/    /'
    exit 1
fi

# ── Step 8: DB settings sanity check ─────────────────────────────────────────
echo "--- Sanity check: channels ---"
ACTIVE_CHANNELS=$(psql "$DB_URL" -tAc \
    "SELECT value FROM settings WHERE user_id='default' AND key='activated_channels';" 2>/dev/null || echo "null")
if [[ "$ACTIVE_CHANNELS" == *"telegram"* ]]; then
    ok "activated_channels includes telegram"
else
    fail "activated_channels missing telegram — fixing"
    psql "$DB_URL" -c \
        "INSERT INTO settings (user_id, key, value)
         VALUES ('default', 'activated_channels', '[\"telegram\"]')
         ON CONFLICT (user_id, key) DO UPDATE SET value = '[\"telegram\"]';" > /dev/null
    ok "activated_channels fixed"
    NEEDS_RESTART=1
fi

# ── Step 8b: wasm_channels table — Telegram must be registered ───────────────
echo "--- Sanity check: wasm_channels table ---"
WASM_COUNT=$(psql "$DB_URL" -tAc \
    "SELECT count(*) FROM wasm_channels WHERE name='telegram' AND status='active';" 2>/dev/null || echo 0)
if [ "$WASM_COUNT" -eq 0 ]; then
    fail "telegram not in wasm_channels table — registering"
    WASM_FILE="$HOME/.ironclaw/channels/telegram.wasm"
    CAPS_FILE="$HOME/.ironclaw/channels/telegram.capabilities.json"
    if [ -f "$WASM_FILE" ] && [ -f "$CAPS_FILE" ]; then
        python3 - "$DB_URL" "$WASM_FILE" "$CAPS_FILE" << 'PYEOF'
import sys, json, hashlib, uuid, subprocess

db_url, wasm_path, caps_path = sys.argv[1:]
binary = open(wasm_path, 'rb').read()
caps   = open(caps_path).read()
d      = json.loads(caps)
h      = hashlib.sha256(binary).hexdigest()

sql = f"""
INSERT INTO wasm_channels (id,user_id,name,version,wit_version,description,wasm_binary,binary_hash,capabilities_json,status)
VALUES ('{uuid.uuid4()}','default','telegram','{d["version"]}','{d["wit_version"]}',
        '{d["description"].replace("'","''")}',
        decode('{binary.hex()}','hex'), decode('{h}','hex'),
        $c${caps}$c$,'active')
ON CONFLICT (user_id, name) DO UPDATE SET
    version=EXCLUDED.version, wasm_binary=EXCLUDED.wasm_binary,
    binary_hash=EXCLUDED.binary_hash, capabilities_json=EXCLUDED.capabilities_json,
    status='active', updated_at=now();
"""
subprocess.run(['psql', db_url, '-c', sql], check=True, capture_output=True)
print("  registered telegram in wasm_channels")
PYEOF
        ok "telegram registered in wasm_channels"
        NEEDS_RESTART=1
    else
        fail "telegram.wasm not found — run: ironclaw registry install telegram"
    fi
else
    ok "telegram in wasm_channels — OK"
fi

# ── Step 9: LLM model name vs LiteLLM sanity check ───────────────────────────
# When selected_model is null, ironclaw falls back to LLM_MODEL from env.
# If that name isn't in LiteLLM's model_list, LiteLLM returns 400 "No connected db".
echo "--- Sanity check: LLM model ---"
LITELLM_MODELS=$(curl -s http://127.0.0.1:4000/v1/models \
    -H "Authorization: Bearer sk-no-key" 2>/dev/null | \
    python3 -c "import sys,json; [print(m['id']) for m in json.load(sys.stdin)['data']]" 2>/dev/null || true)
FIRST_LITELLM_MODEL=$(echo "$LITELLM_MODELS" | head -1)

SELECTED_MODEL=$(psql "$DB_URL" -tAc \
    "SELECT value FROM settings WHERE user_id='default' AND key='selected_model';" 2>/dev/null | tr -d '"' || true)
SELECTED_MODEL="${SELECTED_MODEL:-null}"

if [ "$SELECTED_MODEL" = "null" ] || [ -z "$SELECTED_MODEL" ]; then
    # null → using LLM_MODEL env var
    ENV_MODEL="${LLM_MODEL:-}"
    if [ -n "$ENV_MODEL" ] && echo "$LITELLM_MODELS" | grep -qx "$ENV_MODEL"; then
        ok "LLM_MODEL='$ENV_MODEL' found in LiteLLM"
    else
        fail "LLM_MODEL='$ENV_MODEL' not in LiteLLM (known: $(echo $LITELLM_MODELS | tr '\n' ' '))"
        info "setting selected_model to '$FIRST_LITELLM_MODEL'"
        psql "$DB_URL" -c \
            "INSERT INTO settings (user_id, key, value)
             VALUES ('default', 'selected_model', '\"${FIRST_LITELLM_MODEL}\"')
             ON CONFLICT (user_id, key) DO UPDATE SET value = '\"${FIRST_LITELLM_MODEL}\"';" > /dev/null
        ok "selected_model set to '$FIRST_LITELLM_MODEL'"
        NEEDS_RESTART=1
    fi
else
    if echo "$LITELLM_MODELS" | grep -qx "$SELECTED_MODEL"; then
        ok "selected_model='$SELECTED_MODEL' found in LiteLLM"
    else
        fail "selected_model='$SELECTED_MODEL' not in LiteLLM — fixing to '$FIRST_LITELLM_MODEL'"
        psql "$DB_URL" -c \
            "UPDATE settings SET value = '\"${FIRST_LITELLM_MODEL}\"'
             WHERE user_id='default' AND key='selected_model';" > /dev/null
        ok "selected_model fixed to '$FIRST_LITELLM_MODEL'"
        NEEDS_RESTART=1
    fi
fi

# Restart once if any DB fix was applied
if [ "${NEEDS_RESTART:-0}" = "1" ]; then
    info "restarting to apply DB fixes"
    systemctl --user restart ironclaw
    sleep 3
fi

echo ""
echo "=== Done ==="
echo ""
echo "Status:  systemctl --user status ironclaw"
echo "Logs:    journalctl --user -u ironclaw -f"
