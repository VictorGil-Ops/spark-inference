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

    local ram mode container_name
    # RAM from recipe (matched by port)
    local ram
    ram=$(python3 - "$RECIPES_DIR" "$port" <<'PYEOF'
import sys, os, re
recipes_dir, port = sys.argv[1], sys.argv[2]
for fname in os.listdir(recipes_dir):
    if not fname.endswith('.yaml'): continue
    raw = open(os.path.join(recipes_dir, fname)).read()
    if re.search(r'port:\s*' + port + r'\b', raw):
        m = re.search(r'#\s*(?:Memory|RAM):\s*~?(\d+)GB', raw, re.IGNORECASE)
        if m:
            print(m.group(1) + 'GB'); sys.exit(0)
        u = re.search(r'gpu_memory_utilization:\s*([\d.]+)', raw)
        print(str(round(float(u.group(1)) * 128)) + 'GB' if u else '?'); sys.exit(0)
print('?')
PYEOF
    )

    # Find the container actually listening on this port (host network — filter by port arg)
    local container_name mode
    container_name=$(docker ps --format '{{.Names}}' --filter 'name=vllm_' 2>/dev/null \
        | while read -r cname; do
            docker exec "$cname" ps aux 2>/dev/null \
                | grep -q "vllm serve.*--port[[:space:]]${port}\b" && echo "$cname" && break
          done)

    if [ -n "$container_name" ]; then
        local proc_flag
        proc_flag=$(docker exec "$container_name" ps aux 2>/dev/null \
            | grep vllm \
            | grep -o "compilation-config\|enforce-eager" \
            | head -1)
        case "$proc_flag" in
            enforce-eager)      mode="Eager" ;;
            compilation-config) mode="CUDA graphs" ;;
            *)                  mode="CUDA graphs" ;;  # vLLM default when no explicit flag
        esac
    else
        mode="?"
    fi

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

    if [ -z "$tokens" ] || [ "$tokens" -eq 0 ] 2>/dev/null; then
        echo "ERROR: Could not parse response. Raw output:"
        echo "$response" | head -5
        exit 1
    fi

    toks_per_sec=$(echo "scale=1; $tokens / $elapsed" | bc)

    echo "Tokens generated : ${tokens}"
    echo "Time             : ${elapsed}s"
    printf "Throughput       : ${GREEN}${toks_per_sec} tok/s${RESET}\n"

    record_result "$port" "$model" "$toks_per_sec"
}

# ── Run reasoning test ────────────────────────────────────────────────────────
run_reasoning_test() {
    local port="$1"
    local model
    model=$(curl -s "http://localhost:${port}/v1/models" \
        | python3 -c "import sys,json; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null)

    if [ -z "$model" ]; then
        echo "ERROR: No model responding on port ${port}"
        return 1
    fi

    echo ""
    echo "Reasoning test: ${model}"
    echo "Port: ${port}"
    echo "----------------------------------------"

    python3 - "$port" "$model" <<'PYEOF'
import asyncio, time, sys
from openai import AsyncOpenAI

port, model = sys.argv[1], sys.argv[2]
client = AsyncOpenAI(base_url=f"http://localhost:{port}/v1", api_key="sk-no-key")

TEST_CASES = [
    {
        "name": "Spatial Logic (Cinema Row)",
        "prompt": "Five people (A, B, C, D, E) are sitting in a row. A cannot be next to B. C must be directly to the right of D. E is at one of the ends of the row. If B is in position 2, what are the possible positions for everyone else? Reason step-by-step before providing the final arrangements."
    },
    {
        "name": "Theory of Mind (The Diamond)",
        "prompt": "Marta puts a diamond in a red box and leaves the room. While she is away, Juan moves the diamond to a blue box and then paints the original red box green. Marta returns. Where will she look for the diamond, and what color does she believe the box she left it in is? Explain why."
    },
    {
        "name": "Security & Causal Reasoning (Attack Chain)",
        "prompt": "Server A only accepts traffic from Server B. Server B has a Remote Code Execution (RCE) vulnerability, but it is only exploitable via a serial console connection. An attacker compromises the laptop of the IT administrator, who has active serial console access to Server B. Map out the logical attack chain to reach Server A and identify the 'weakest link' in this architecture based strictly on the provided conditions."
    },
    {
        "name": "Linguistic Mathematics (The Scalability Trap)",
        "prompt": "If it takes three programmers three hours to patch three servers, how many minutes would it take one hundred programmers to patch one hundred servers if they all work in parallel on separate servers? Explain your math."
    }
]

async def run_test(case):
    print(f"\n  → {case['name']}")
    start = time.perf_counter()
    response = await client.chat.completions.create(
        model=model,
        messages=[{"role": "user", "content": case['prompt']}],
        temperature=0,
        max_tokens=1024,
        stream=False
    )
    elapsed = time.perf_counter() - start
    tokens = response.usage.completion_tokens
    tps = tokens / elapsed
    text = response.choices[0].message.content
    print(f"  Latency : {elapsed:.2f}s   Throughput: {tps:.1f} tok/s")
    print(f"  {'-'*60}")
    for line in text.strip().split('\n'):
        print(f"  {line}")
    print(f"  {'-'*60}")

async def main():
    for case in TEST_CASES:
        await run_test(case)

asyncio.run(main())
PYEOF
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
    echo ""
    read -rp "  Enter port to probe manually (or q to quit): " manual_port
    [[ "$manual_port" == "q" || "$manual_port" == "Q" || -z "$manual_port" ]] && echo "Bye." && exit 0
    run_benchmark "$manual_port"
    exit $?
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

chosen_port="${RUNNING[$((sel-1))]%%:*}"

echo ""
echo "  Benchmark type:"
printf "  ${GREEN}[1]${RESET} Simple     tok/s (transformer explanation, 500 tokens)\n"
printf "  ${GREEN}[2]${RESET} Reasoning  4 logic/reasoning test cases\n"
printf "  ${GREEN}[b]${RESET} Both\n"
echo ""
read -rp "  Select: " btype

case "$btype" in
    1)   run_benchmark "$chosen_port" ;;
    2)   run_reasoning_test "$chosen_port" ;;
    b|B) run_benchmark "$chosen_port"; echo ""; run_reasoning_test "$chosen_port" ;;
    *)   echo "Invalid."; exit 1 ;;
esac
