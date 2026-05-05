#!/bin/bash
# Wrapper to run dev-private-spark-inference recipes with correct container names
# Usage: ./scripts/run.sh <recipe-name> [extra flags]
# ~/dev-private-spark-inference/scripts/run.sh nemotron-3-nano-nvfp4 -d
# ~/dev-private-spark-inference/scripts/run.sh nemotron3-nano-nvfp4-w4a16 -d
# ~/dev-private-spark-inference/scripts/run.sh qwen3.6-35b-fp8 -d
# ~/dev-private-spark-inference/scripts/run.sh deepseek-r1-32b-fp8 -d

SPARK_VLLM_DIR="${SPARK_VLLM_DIR:-$HOME/repos/spark-vllm-docker}"
RECIPES_DIR="$(cd "$(dirname "$0")/.." && pwd)/recipes"

if [ -z "$1" ]; then
    echo "Usage: $0 <recipe> [--solo] [-d] [flags]"
    echo ""
    echo "Available recipes:"
    ls ${RECIPES_DIR}/*.yaml | xargs -I{} basename {} .yaml
    exit 1
fi

RECIPE=$1
shift

# Map recipe name to container name
case "$RECIPE" in
    qwen3*)
        CONTAINER_NAME="vllm_qwen36"
        ;;
    nemotron*nano*w4*)
        CONTAINER_NAME="vllm_nemotron_w4a16"
        ;;
    nemotron*)
        CONTAINER_NAME="vllm_nemotron_nano"
        ;;
    deepseek*)
        CONTAINER_NAME="vllm_deepseek_r1"
        ;;
    single-nemotron*)
        CONTAINER_NAME="vllm_nemotron_super"
        ;;
    single-qwen3*)
        CONTAINER_NAME="vllm_qwen3_235b"
        ;;
    *)
        CONTAINER_NAME="vllm_$(echo $RECIPE | tr '-' '_')"
        ;;
esac

echo "Starting: ${RECIPE} → container: ${CONTAINER_NAME}"

cd "$SPARK_VLLM_DIR" && \
    ./run-recipe.sh "${RECIPES_DIR}/${RECIPE}.yaml" \
    --name "$CONTAINER_NAME" \
    --solo \
    "$@"
