#!/bin/bash
# Benchmark tok/s for a running vLLM instance
# Usage: ./scripts/benchmark.sh [port]   — non-interactive
#        ./scripts/benchmark.sh          — pick from running models

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RECIPES_DIR="$REPO_DIR/recipes"
BENCHMARKS_FILE="$REPO_DIR/BENCHMARKS.md"
GREEN='\033[32m'
RESET='\033[0m'

# ── Record result in BENCHMARKS.md ───────────────────────────────────────────
record_result() {
    local port="$1" model="$2" toks_per_sec="$3"

    local ram mode
    read -r ram mode < <(python3 - "$RECIPES_DIR" "$port" <<'PYEOF'
import sys, os, re
recipes_dir, port = sys.argv[1], sys.argv[2]
for fname in os.listdir(recipes_dir):
    if not fname.endswith('.yaml'): continue
    raw = open(os.path.join(recipes_dir, fname)).read()
    if re.search(r'port:\s*' + port + r'\b', raw):
        m = re.search(r'#\s*(?:Memory|RAM):\s*~?(\d+)GB', raw, re.IGNORECASE)
        if m:
            ram = m.group(1) + 'GB'
        else:
            u = re.search(r'gpu_memory_utilization:\s*([\d.]+)', raw)
            ram = str(round(float(u.group(1)) * 128)) + 'GB' if u else '?'
        mode = 'Eager' if '--enforce-eager' in raw else 'CUDA graphs'
        print(ram, mode)
        sys.exit(0)
print('? ?')
PYEOF
    )

    local ts
    ts=$(date '+%Y-%m-%d %H:%M')

    python3 - "$BENCHMARKS_FILE" "$ts" "$model" "$toks_per_sec" "$ram" "$mode" <<'PYEOF'
import sys, os
path, ts, model, toks, ram, mode = sys.argv[1:]
row = f"| {ts} | {model} | {toks} | ~{ram} | {mode} |"

if not os.path.exists(path):
    content = (
        "# Benchmarks\n\n"
        "Prompt: 500 tokens, transformer explanation\n\n"
        "| Date | Model | tok/s | RAM | Mode |\n"
        "|------|-------|-------|-----|------|\n"
        f"{row}\n"
    )
    with open(path, 'w') as f:
        f.write(content)
else:
    with open(path) as f:
        lines = f.readlines()
    last = max((i for i, l in enumerate(lines) if l.startswith('|')), default=-1)
    if last >= 0:
        lines.insert(last + 1, row + '\n')
    else:
        lines.append(row + '\n')
    with open(path, 'w') as f:
        f.writelines(lines)
PYEOF

    printf "  → Recorded in BENCHMARKS.md\n"
}

# ── Run benchmark ─────────────────────────────────────────────────────────────
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

    record_result "$port" "$model" "$toks_per_sec"
}

# ── Non-interactive: port provided ───────────────────────────────────────────
if [ -n "$1" ]; then
    run_benchmark "$1"
    exit $?
fi

# ── Interactive: discover ports from recipes, probe running ones ──────────────
echo "=== DGX Spark — Benchmark ==="
echo ""

# Collect unique ports from all recipe YAMLs
RECIPE_PORTS=$(python3 - "$RECIPES_DIR" <<'PYEOF'
import sys, os, re

recipes_dir = sys.argv[1]
seen = set()
ports = []
for fname in sorted(f for f in os.listdir(recipes_dir) if f.endswith('.yaml')):
    raw = open(os.path.join(recipes_dir, fname)).read()
    m = re.search(r'port:\s*(\d+)', raw)
    if m and m.group(1) not in seen:
        seen.add(m.group(1))
        ports.append(m.group(1))
print(' '.join(ports))
PYEOF
)

declare -a RUNNING  # "port:model_id" entries

for p in $RECIPE_PORTS; do
    model=$(curl -sf --max-time 2 "http://localhost:${p}/v1/models" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null)
    if [ -n "$model" ]; then
        RUNNING+=("${p}:${model}")
    fi
done

if [ ${#RUNNING[@]} -eq 0 ]; then
    echo "No vLLM models running on ports: ${RECIPE_PORTS}"
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
        run_benchmark "${entry%%:*}"
        echo ""
    done
    exit 0
fi

if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "${#RUNNING[@]}" ]; then
    echo "Invalid selection."
    exit 1
fi

run_benchmark "${RUNNING[$((sel-1))]%%:*}"
