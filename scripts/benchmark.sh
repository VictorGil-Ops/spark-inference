#!/bin/bash
# Benchmark tok/s for a running vLLM instance
# Usage: ./scripts/benchmark.sh [port] [model]

PORT=${1:-8000}
MODEL=$(curl -s http://localhost:${PORT}/v1/models | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null)

if [ -z "$MODEL" ]; then
    echo "ERROR: No model running on port ${PORT}"
    exit 1
fi

echo "Benchmarking: ${MODEL} on port ${PORT}"
echo "----------------------------------------"

START=$(date +%s%N)
RESPONSE=$(curl -s http://localhost:${PORT}/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"${MODEL}\",
    \"messages\": [{\"role\": \"user\", \"content\": \"Write a detailed explanation of how transformers work, including attention mechanisms, positional encoding, and the encoder-decoder architecture.\"}],
    \"max_tokens\": 500
  }")
END=$(date +%s%N)

TOKENS=$(echo $RESPONSE | python3 -c "import sys,json; print(json.load(sys.stdin)['usage']['completion_tokens'])" 2>/dev/null)
ELAPSED=$(echo "scale=2; ($END - $START) / 1000000000" | bc)
TOKS_PER_SEC=$(echo "scale=1; $TOKENS / $ELAPSED" | bc)

echo "Tokens generated: ${TOKENS}"
echo "Time: ${ELAPSED}s"
echo "Throughput: ${TOKS_PER_SEC} tok/s"
