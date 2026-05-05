#!/bin/bash
set -e

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
echo "=== LiteLLM Proxy Install/Update for DGX Spark ==="

# Install or update LiteLLM
echo "--- Installing/updating LiteLLM ---"
pip install "litellm[proxy]" --break-system-packages --upgrade

# Stop service if running
echo "--- Stopping existing service (if running) ---"
systemctl --user stop litellm 2>/dev/null || true

# Systemd service (always overwrite)
echo "--- Installing systemd service ---"
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/litellm.service << SVCEOF
[Unit]
Description=LiteLLM Proxy for DGX Spark
After=network.target

[Service]
Type=simple
ExecStart=${HOME}/.local/bin/litellm --config ${REPO_DIR}/ironclaw/litellm/litellm_config.yaml
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
SVCEOF

systemctl --user daemon-reload
systemctl --user enable litellm
systemctl --user restart litellm

# Wait until proxy is ready (max 30s)
echo "--- Waiting for LiteLLM to start (max 30s) ---"
for i in $(seq 1 30); do
    if curl -sf http://127.0.0.1:4000/v1/models \
        -H "Authorization: Bearer sk-spark-local" > /dev/null 2>&1; then
        echo "✓ LiteLLM proxy ready on port 4000"
        echo ""
        echo "Registered models:"
        curl -s http://127.0.0.1:4000/v1/models \
            -H "Authorization: Bearer sk-spark-local" | \
            python3 -c "import sys,json; [print(' -', m['id']) for m in json.load(sys.stdin)['data']]"
        break
    fi
    sleep 1
    if [ $i -eq 30 ]; then
        echo "✗ Timeout — check with: journalctl --user -u litellm -n 20"
        exit 1
    fi
done

echo ""
echo "=== LiteLLM installed/updated on port 4000 ==="
echo ""
echo "To reconfigure IronClaw:"
echo "  ironclaw onboard --step provider"
echo "  URL: http://127.0.0.1:4000/v1"
echo "  API key: sk-spark-local"
echo "  Model: nemotron-nano"
echo ""
echo "Management commands:"
echo "  systemctl --user status litellm"
echo "  systemctl --user restart litellm"
echo "  journalctl --user -u litellm -f"
