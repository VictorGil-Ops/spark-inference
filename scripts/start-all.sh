#!/bin/bash
# start-all.sh — Interactive model launcher for DGX Spark
# Lets you choose which models to start based on available memory

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# ── Memory check ──────────────────────────────────────────────────────────────
TOTAL_GB=$(awk '/MemTotal/{printf "%.0f", $2/1048576}' /proc/meminfo)
AVAIL_GB=$(awk '/MemAvailable/{printf "%.0f", $2/1048576}' /proc/meminfo)
USED_GB=$((TOTAL_GB - AVAIL_GB))

echo "=== DGX Spark Model Launcher ==="
echo ""
echo "Memory: ${USED_GB}GB used / ${TOTAL_GB}GB total (${AVAIL_GB}GB free)"
echo ""
echo "Available models:"
echo "  [1] nemotron-nano    ~32GB  port 8000  Orchestrator (fast, NVFP4)"
echo "  [2] qwen3.6-35b      ~45GB  port 8001  Coding + Vision (FP8)"
echo "  [3] deepseek-r1-32b  ~25GB  port 8002  Reasoning + Pentest (FP8)"
echo "  [4] nemotron-w4a16   ~18GB  port 8000  Alt orchestrator (low RAM)"
echo ""
echo "Single Powerful mode (stop all others first):"
echo "  [5] nemotron-super-120b  ~87GB  port 8000  Max quality agentic"
echo "  [6] qwen3-235b           ~115GB port 8000  Max quality coding"
echo ""
echo "Presets:"
echo "  [a] Multi-agent stack    (1+2+3 = ~102GB)"
echo "  [b] Lite stack           (4+2   = ~63GB)"
echo "  [c] Orchestrator only    (1     = ~32GB)"
echo "  [q] Quit"
echo ""
read -p "Select models to start (e.g. 1 2 3 or a): " selection

# ── Parse selection ───────────────────────────────────────────────────────────
case "$selection" in
    a) models="nemotron-3-nano-nvfp4 qwen3.6-35b-fp8 deepseek-r1-32b-fp8" ;;
    b) models="nemotron3-nano-nvfp4-w4a16 qwen3.6-35b-fp8" ;;
    c) models="nemotron-3-nano-nvfp4" ;;
    q) echo "Bye."; exit 0 ;;
    *)
        models=""
        for n in $selection; do
            case "$n" in
                1) models="$models nemotron-3-nano-nvfp4" ;;
                2) models="$models qwen3.6-35b-fp8" ;;
                3) models="$models deepseek-r1-32b-fp8" ;;
                4) models="$models nemotron3-nano-nvfp4-w4a16" ;;
                5) models="$models single-nemotron-super-120b" ;;
                6) models="$models single-qwen3-235b-int4" ;;
                *) echo "Unknown option: $n — skipping" ;;
            esac
        done
        ;;
esac

if [ -z "$models" ]; then
    echo "No models selected. Exiting."
    exit 0
fi

# ── Flush memory ──────────────────────────────────────────────────────────────
echo ""
echo "--- Flushing memory cache ---"
sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true

# ── Start selected models ─────────────────────────────────────────────────────
for model in $models; do
    echo ""
    echo "--- Starting: $model ---"
    bash "${REPO_DIR}/scripts/run.sh" "$model" -d

    # Wait for orchestrator (port 8000) before starting others
    if [[ "$model" == *"nemotron"* ]] || [[ "$model" == *"qwen3-235b"* ]]; then
        echo "Waiting for $model to be ready..."
        for i in $(seq 1 120); do
            curl -sf http://localhost:8000/health > /dev/null 2>&1 && break
            sleep 5
        done
        echo "✓ $model ready"
    fi
done

# ── Status ────────────────────────────────────────────────────────────────────
echo ""
echo "=== Stack started ==="
echo "Models starting (CUDA graph capture takes 5-10 min):"
echo ""
docker ps --format "  {{.Names}}\t{{.Status}}" | grep vllm
echo ""
echo "Check health:"
echo "  curl -sf http://localhost:8000/health && echo OK"
echo "  curl -sf http://localhost:8001/health && echo OK"
echo "  curl -sf http://localhost:8002/health && echo OK"
