#!/bin/bash
# Start all configured vLLM models in detached mode.
# Run this after a reboot or to restore the full multi-agent stack.
#
# Usage: bash scripts/start-all.sh [--single-nemotron | --single-qwen3]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

mode="${1:-}"

if [ "$mode" = "--single-nemotron" ]; then
    echo "Starting single-powerful mode: Nemotron-Super-120B"
    "$SCRIPT_DIR/run.sh" single-nemotron-super-120b -d
elif [ "$mode" = "--single-qwen3" ]; then
    echo "Starting single-powerful mode: Qwen3-235B"
    "$SCRIPT_DIR/run.sh" single-qwen3-235b-int4 -d
else
    echo "Starting multi-agent stack..."
    "$SCRIPT_DIR/run.sh" nemotron-3-nano-nvfp4 -d
    "$SCRIPT_DIR/run.sh" qwen3.6-35b-fp8 -d
    "$SCRIPT_DIR/run.sh" deepseek-r1-32b-fp8 -d
    echo ""
    echo "Models starting in background. Check with:"
    echo "  docker logs -f vllm_nemotron_nano"
    echo "  curl http://localhost:8000/health"
fi
