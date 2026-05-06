#!/bin/bash
# run.sh — Launch a vLLM model recipe on DGX Spark
# Usage: ./scripts/run.sh [recipe-name] [-d] [flags]
#        ./scripts/run.sh              — interactive model picker
#        ./scripts/run.sh nemotron-3-nano-nvfp4 -d

SPARK_VLLM_DIR="${SPARK_VLLM_DIR:-$HOME/repos/spark-vllm-docker}"
RECIPES_DIR="$(cd "$(dirname "$0")/.." && pwd)/recipes"
HF_CACHE="${HF_HOME:-$HOME/.cache/huggingface}/hub"

# ── Map recipe name → Docker container name ───────────────────────────────────
container_name() {
    local recipe="$1"
    case "$recipe" in
        single-nemotron*)  echo "vllm_nemotron_super" ;;
        single-qwen3*)     echo "vllm_qwen3_235b" ;;
        qwen3*)            echo "vllm_qwen36" ;;
        nemotron*nano*w4*) echo "vllm_nemotron_w4a16" ;;
        nemotron*)         echo "vllm_nemotron_nano" ;;
        deepseek*)         echo "vllm_deepseek_r1" ;;
        *)                 echo "vllm_$(echo "$recipe" | tr -- '-.' '__')" ;;
    esac
}

# ── Launch a recipe ───────────────────────────────────────────────────────────
launch() {
    local recipe="$1"; shift
    local cname
    cname=$(container_name "$recipe")

    echo "--- Flushing memory cache ---"
    sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true
    awk '/MemAvailable/{printf "  Available: %.1f GB\n", $2/1048576}' /proc/meminfo
    echo ""

    echo "Starting: ${recipe} → container: ${cname}"
    cd "$SPARK_VLLM_DIR" && \
        ./run-recipe.sh "${RECIPES_DIR}/${recipe}.yaml" \
        --name "$cname" \
        --solo \
        "$@"
}

# ── Unload a model from memory (stop its container) ──────────────────────────
unload_model() {
    local slug="$1"
    local cname
    cname=$(container_name "$slug")
    echo ""
    echo "Stopping container: ${cname}"
    if docker stop "$cname" 2>/dev/null; then
        echo "  ✓ ${cname} stopped — RAM freed"
    else
        echo "  ✗ ${cname} is not running"
    fi
}

# ── Download a model from HuggingFace Hub ─────────────────────────────────────
download_hf() {
    local model_id="$1"
    echo ""
    echo "=== Downloading from HuggingFace: ${model_id} ==="
    [ -n "$HF_TOKEN" ] && echo "  HF_TOKEN set (gated model access enabled)"
    echo ""
    if command -v huggingface-cli &>/dev/null; then
        huggingface-cli download "$model_id" \
            ${HF_TOKEN:+--token "$HF_TOKEN"} \
            --local-dir-use-symlinks False
    else
        python3 - "$model_id" "${HF_TOKEN:-}" <<'PYEOF'
import sys
from huggingface_hub import snapshot_download
model_id = sys.argv[1]
token    = sys.argv[2] or None
print(f"Downloading {model_id} ...")
path = snapshot_download(model_id, token=token)
print(f"Done → {path}")
PYEOF
    fi
}

# ── Non-interactive: recipe name provided ────────────────────────────────────
if [ -n "$1" ]; then
    RECIPE=$1; shift
    launch "$RECIPE" "$@"
    exit $?
fi

# ── Interactive mode ──────────────────────────────────────────────────────────

TOTAL_GB=$(awk '/MemTotal/{printf "%.0f", $2/1048576}' /proc/meminfo)
AVAIL_GB=$(awk '/MemAvailable/{printf "%.0f", $2/1048576}' /proc/meminfo)
USED_GB=$((TOTAL_GB - AVAIL_GB))

echo "=== DGX Spark — Model Launcher ==="
echo ""
echo "Memory: ${USED_GB}GB used / ${TOTAL_GB}GB total  (${AVAIL_GB}GB free)"
echo ""

RUNNING_CONTAINERS=$(docker ps --format "{{.Names}}" 2>/dev/null | grep "^vllm" | tr '\n' ',' || true)

RECIPE_LIST=$(python3 - "$RECIPES_DIR" "$AVAIL_GB" "$RUNNING_CONTAINERS" "$HF_CACHE" <<'PYEOF'
import sys, os, re

recipes_dir  = sys.argv[1]
avail_gb     = int(sys.argv[2])
running_ctrs = set(sys.argv[3].split(',')) if sys.argv[3] else set()
hf_cache     = sys.argv[4]

def container_name(slug):
    if slug.startswith('single-nemotron'): return 'vllm_nemotron_super'
    if slug.startswith('single-qwen3'):    return 'vllm_qwen3_235b'
    if slug.startswith('qwen3'):           return 'vllm_qwen36'
    if 'nano' in slug and 'w4' in slug:    return 'vllm_nemotron_w4a16'
    if 'nemotron' in slug:                 return 'vllm_nemotron_nano'
    if 'deepseek' in slug:                 return 'vllm_deepseek_r1'
    return 'vllm_' + slug.replace('-', '_').replace('.', '_')

def is_cached(model_id, hf_cache):
    # HF cache dir: models--<org>--<name>/snapshots/
    cache_name = 'models--' + model_id.replace('/', '--')
    snap_dir = os.path.join(hf_cache, cache_name, 'snapshots')
    if not os.path.isdir(snap_dir):
        return False
    return any(os.scandir(snap_dir))  # has at least one snapshot

GREEN  = '\033[32m'
CYAN   = '\033[36m'
RESET  = '\033[0m'

yamls = sorted(f for f in os.listdir(recipes_dir) if f.endswith('.yaml'))

entries = []
for fname in yamls:
    slug = fname[:-5]
    path = os.path.join(recipes_dir, fname)
    with open(path) as fh:
        raw = fh.read()

    name_m = re.search(r'^name:\s*(.+)', raw, re.MULTILINE)
    name   = name_m.group(1).strip() if name_m else slug

    model_m  = re.search(r'^model:\s*(.+)', raw, re.MULTILINE)
    model_id = model_m.group(1).strip() if model_m else ''

    port_m = re.search(r'port:\s*(\d+)', raw)
    port   = port_m.group(1) if port_m else '????'

    mem_m = re.search(r'#\s*(?:Memory|RAM):\s*~?(\d+)GB', raw, re.IGNORECASE)
    if mem_m:
        ram_gb = int(mem_m.group(1))
    else:
        util_m = re.search(r'gpu_memory_utilization:\s*([\d.]+)', raw)
        ram_gb = round(float(util_m.group(1)) * 128) if util_m else 0

    toks_m = re.search(r'tok/s:\s*~?([\d\-]+)', raw)
    toks   = toks_m.group(1) if toks_m else '??'

    ctx_m  = re.search(r'max_model_len:\s*(\d+)', raw)
    ctx_k  = str(int(ctx_m.group(1)) // 1024) + 'k' if ctx_m else '??'

    warn    = ' ⚠' if ram_gb > avail_gb else ''
    running = container_name(slug) in running_ctrs
    cached  = is_cached(model_id, hf_cache)

    entries.append((slug, model_id, port, ram_gb, toks, ctx_k, warn, running, cached))

print(f"  {'#':<3}  {'':2}  {'':2}  {'Recipe':<34}  {'Port':<5}  {'RAM':>5}  {'tok/s':>6}  {'ctx':>5}")
print(f"  {'-'*3}  {'--'}  {'--'}  {'-'*34}  {'-'*5}  {'-'*5}  {'-'*6}  {'-'*5}")
for i, (slug, mid, port, ram, toks, ctx, warn, running, cached) in enumerate(entries, 1):
    dot   = f'{GREEN}●{RESET}' if running else ' '
    check = f'{CYAN}✓{RESET}' if cached  else ' '
    print(f"  {i:<3}  {dot}  {check}  {slug:<34}  {port:<5}  {ram:>4}GB  {toks:>6}  {ctx:>5}{warn}")

import tempfile
tmp = tempfile.NamedTemporaryFile(mode='w', suffix='.recipes', delete=False)
for slug, model_id, *_ in entries:
    tmp.write(f"{slug}\t{model_id}\n")
tmp.close()
print(f"__TMPFILE__={tmp.name}")
PYEOF
)

TMPFILE=$(echo "$RECIPE_LIST" | grep '^__TMPFILE__=' | cut -d= -f2)
echo "$RECIPE_LIST" | grep -v '^__TMPFILE__='
echo ""

if [ -z "$TMPFILE" ] || [ ! -f "$TMPFILE" ]; then
    echo "Error: could not parse recipes"
    exit 1
fi

declare -a SLUGS MODEL_IDS
while IFS=$'\t' read -r slug mid; do
    SLUGS+=("$slug")
    MODEL_IDS+=("$mid")
done < "$TMPFILE"
rm -f "$TMPFILE"

COUNT=${#SLUGS[@]}
printf "  \033[32m●\033[0m running   \033[36m✓\033[0m cached locally   ⚠ exceeds free RAM\n"
echo ""
echo "  [x <num>]  Unload from memory (stop container)   (e.g. x2)"
echo "  [h <num>]  Download from HuggingFace             (e.g. h5)"
echo "  [q]        Quit"
echo ""
read -rp "Select model (1-${COUNT}): " sel

if [[ "$sel" == "q" || "$sel" == "Q" ]]; then
    echo "Bye."
    exit 0
fi

# Unload: x<num>
if [[ "$sel" =~ ^[xX][[:space:]]*([0-9]+)$ ]]; then
    idx="${BASH_REMATCH[1]}"
    if [ "$idx" -lt 1 ] || [ "$idx" -gt "$COUNT" ]; then
        echo "Invalid selection."
        exit 1
    fi
    unload_model "${SLUGS[$((idx-1))]}"
    exit $?
fi

# Download from HF: h<num>
if [[ "$sel" =~ ^[hH][[:space:]]*([0-9]+)$ ]]; then
    idx="${BASH_REMATCH[1]}"
    if [ "$idx" -lt 1 ] || [ "$idx" -gt "$COUNT" ]; then
        echo "Invalid selection."
        exit 1
    fi
    download_hf "${MODEL_IDS[$((idx-1))]}"
    exit $?
fi

if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "$COUNT" ]; then
    echo "Invalid selection."
    exit 1
fi

RECIPE="${SLUGS[$((sel - 1))]}"
echo ""
launch "$RECIPE" "$@"
