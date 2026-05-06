#!/bin/bash
# Benchmark tok/s for a running vLLM instance
# Usage: ./scripts/benchmark.sh [port]   — non-interactive
#        ./scripts/benchmark.sh          — pick from running models

GREEN='\033[32m'
RESET='\033[0m'

run_benchmark() {
    local port="$1"
    local model
    model=$(curl -s "http://localhost:${port}/v1/models" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null)

    if [ -z "$model" ]; then
        echo "ERROR: No model responding on port ${port}"
        exit 1
    fi

    echo ""
    echo "Benchmarking: ${model}"
    echo "Port: ${port}"
    echo "Prompt: 500 tokens, transformer explanation"
    echo "----------------------------------------"

    local start end response tokens elapsed toks_per_sec
    start=$(date +%s%N)
    response=$(curl -s "http://localhost:${port}/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "{
          \"model\": \"${model}\",
          \"messages\": [{\"role\": \"user\", \"content\": \"Write a detailed explanation of how transformers work, including attention mechanisms, positional encoding, and the encoder-decoder architecture.\"}],
          \"max_tokens\": 500
        }")
    end=$(date +%s%N)

    tokens=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)['usage']['completion_tokens'])" 2>/dev/null)
    elapsed=$(echo "scale=2; ($end - $start) / 1000000000" | bc)
    toks_per_sec=$(echo "scale=1; $tokens / $elapsed" | bc)

    echo "Tokens generated : ${tokens}"
    echo "Time             : ${elapsed}s"
    printf "Throughput       : ${GREEN}${toks_per_sec} tok/s${RESET}\n"
}

# ── Non-interactive: port provided ───────────────────────────────────────────
if [ -n "$1" ]; then
    run_benchmark "$1"
    exit $?
fi

# ── Interactive: detect running vLLM containers and their ports ───────────────
echo "=== DGX Spark — Benchmark ==="
echo ""

# Query health on known ports, collect responding ones
PORTS=(8000 8001 8002)
declare -a RUNNING  # "port:model_id" entries

for p in "${PORTS[@]}"; do
    model=$(curl -sf --max-time 2 "http://localhost:${p}/v1/models" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null)
    if [ -n "$model" ]; then
        RUNNING+=("${p}:${model}")
    fi
done

if [ ${#RUNNING[@]} -eq 0 ]; then
    echo "No vLLM models running on ports 8000-8002."
    exit 1
fi

echo "Running models:"
echo ""
printf "  %-4s  %-5s  %s\n" "#" "Port" "Model"
printf "  %-4s  %-5s  %s\n" "---" "-----" "----------------------------------------"
for i in "${!RUNNING[@]}"; do
    port="${RUNNING[$i]%%:*}"
    model="${RUNNING[$i]#*:}"
    printf "  ${GREEN}●${RESET} %-2s  %-5s  %s\n" "$((i+1))" "$port" "$model"
done

echo ""
echo "  [a] Benchmark all"
echo "  [q] Quit"
echo ""
read -rp "Select model (1-${#RUNNING[@]}): " sel

if [[ "$sel" == "q" || "$sel" == "Q" ]]; then
    echo "Bye."
    exit 0
fi

if [[ "$sel" == "a" || "$sel" == "A" ]]; then
    for entry in "${RUNNING[@]}"; do
        port="${entry%%:*}"
        run_benchmark "$port"
        echo ""
    done
    exit 0
fi

if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "${#RUNNING[@]}" ]; then
    echo "Invalid selection."
    exit 1
fi

port="${RUNNING[$((sel-1))]%%:*}"
run_benchmark "$port"
