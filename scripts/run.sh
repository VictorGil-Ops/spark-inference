#!/bin/bash
# run.sh — Launch a vLLM model recipe on DGX Spark
# Usage: ./scripts/run.sh [recipe-name] [-d] [flags]
#        ./scripts/run.sh              — interactive model picker
#        ./scripts/run.sh nemotron-3-nano-nvfp4 -d

SPARK_VLLM_DIR="${SPARK_VLLM_DIR:-$HOME/repos/spark-vllm-docker}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RECIPES_DIR="$REPO_DIR/recipes"
HF_CACHE="${HF_HOME:-$HOME/.cache/huggingface}/hub"

# ── Map recipe name → Docker container name ───────────────────────────────────
# Deterministic: vllm_ + slug with - and . replaced by _
container_name() {
    echo "vllm_$(echo "$1" | tr -- '-./' '__')"
}

# ── Launch a recipe ───────────────────────────────────────────────────────────
launch() {
    local recipe="$1"; shift
    local cname port
    cname=$(container_name "$recipe")
    port=$(python3 -c "import re,sys; raw=open('${RECIPES_DIR}/${recipe}.yaml').read(); m=re.search(r'port:\s*(\d+)',raw); print(m.group(1) if m else '8000')")

    echo "--- Flushing memory cache ---"
    sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true
    awk '/MemAvailable/{printf "  Available: %.1f GB\n", $2/1048576}' /proc/meminfo
    echo ""

    # Stop the container if already running before relaunching
    if docker inspect "$cname" --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
        echo "Stopping running container: ${cname} (timeout 60s)..."
        docker stop --timeout 60 "$cname" >/dev/null
        echo "  ✓ Stopped"
        echo ""
    fi

    # Remove any stopped container with the same name before launching
    if docker inspect "$cname" >/dev/null 2>&1; then
        echo "Removing existing stopped container: ${cname}..."
        docker rm "$cname" >/dev/null
        echo "  ✓ Removed"
        echo ""
    fi

    # Check required container image is available locally
    local req_image
    req_image=$(python3 -c "
import re, sys
raw = open('${RECIPES_DIR}/${recipe}.yaml').read()
m = re.search(r'^container:\s*(\S+)', raw, re.MULTILINE)
print(m.group(1).strip() if m else 'vllm-node')
" 2>/dev/null)
    if [ -n "$req_image" ] && ! docker image inspect "$req_image" >/dev/null 2>&1; then
        echo ""
        echo "  ✗  Container image '${req_image}' not found locally."
        echo ""
        echo "     Build it first:"
        echo "       cd ${SPARK_VLLM_DIR}"
        local df_flag=""
        [[ "$req_image" == *mxfp4* ]] && df_flag=" -f Dockerfile.mxfp4"
        echo "       ./build-and-copy.sh -t ${req_image}${df_flag}"
        echo ""
        return 1
    fi

    echo "Starting: ${recipe} → container: ${cname}"
    # Strip any -d from caller args to avoid duplication; we always run detached
    local extra=()
    for arg in "$@"; do [[ "$arg" != "-d" ]] && extra+=("$arg"); done

    # Rewrite relative mod paths (mods/foo) to absolute paths in our repo so
    # launch-cluster.sh finds them instead of looking inside spark-vllm-docker/
    local tmp_recipe
    tmp_recipe=$(mktemp --suffix=.yaml)
    sed "s|^\( *- \)\(mods/\)|\1${REPO_DIR}/\2|g" \
        "${RECIPES_DIR}/${recipe}.yaml" > "$tmp_recipe"

    cd "$SPARK_VLLM_DIR" && \
        ./run-recipe.sh "$tmp_recipe" \
        --name "$cname" \
        --solo \
        -d \
        "${extra[@]}"
    rm -f "$tmp_recipe"

    # Stream logs in background, stop when health endpoint is ready
    echo ""
    echo "--- Logs (port ${port} — CUDA graph capture ~5-10 min) ---"
    docker logs -f "$cname" 2>&1 &
    local logs_pid=$!

    local ready=0
    for i in $(seq 1 240); do
        sleep 5
        if curl -sf "http://localhost:${port}/health" >/dev/null 2>&1; then
            ready=1
            break
        fi
    done

    kill "$logs_pid" 2>/dev/null
    wait "$logs_pid" 2>/dev/null

    echo ""
    if [ "$ready" -eq 1 ]; then
        echo "✓ ${cname} ready on port ${port} ($((i * 5))s)"
    else
        echo "⚠ Timeout after 20 min — check: docker logs ${cname}"
    fi
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

# ── Delete a model from the local HuggingFace cache ──────────────────────────
delete_cache() {
    local model_id="$1"
    local cache_name
    cache_name="models--$(echo "$model_id" | sed 's|/|--|g')"
    local cache_path="$HF_CACHE/$cache_name"

    if [ ! -d "$cache_path" ]; then
        echo "  Not cached: ${model_id}"
        return
    fi

    # Block deletion if the model's container is running
    local slug
    slug=$(python3 -c "
import os, re, sys
model_id = sys.argv[1]
for fname in os.listdir('$RECIPES_DIR'):
    if not fname.endswith('.yaml'): continue
    raw = open(os.path.join('$RECIPES_DIR', fname)).read()
    m = re.search(r'^model:\s*(.+)', raw, re.MULTILINE)
    if m and m.group(1).strip() == model_id:
        print(fname[:-5]); sys.exit(0)
" "$model_id" 2>/dev/null)
    if [ -n "$slug" ]; then
        local cname
        cname=$(container_name "$slug")
        if docker inspect "$cname" --format '{{.State.Running}}' 2>/dev/null | grep -q true; then
            echo "  ✗ Cannot delete: ${cname} is running. Unload it first (x<num>)."
            return
        fi
    fi

    local size
    size=$(du -sh "$cache_path" 2>/dev/null | cut -f1)
    echo ""
    echo "  Model : ${model_id}"
    echo "  Path  : ${cache_path}"
    echo "  Size  : ${size}"
    echo ""
    read -rp "  Delete from cache? [y/N]: " c
    if [[ "$c" =~ ^[yY] ]]; then
        sudo chmod -R u+w "$cache_path" && sudo rm -rf "$cache_path"
        echo "  ✓ Deleted (${size} freed)"
    else
        echo "  Cancelled."
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

read -r DISK_TOTAL_GB DISK_USED_GB DISK_FREE_GB < <(
    df "$HF_CACHE" 2>/dev/null | awk 'NR==2{printf "%.0f %.0f %.0f\n", $2/1048576, $3/1048576, $4/1048576}'
)

echo "=== DGX Spark — Model Launcher ==="
echo ""
echo "Memory:  ${USED_GB}GB used / ${TOTAL_GB}GB total  (${AVAIL_GB}GB free)"
echo "Storage: ${DISK_USED_GB}GB used / ${DISK_TOTAL_GB}GB total  (${DISK_FREE_GB}GB free)  [$(df --output=target "$HF_CACHE" 2>/dev/null | tail -1 | tr -d ' ')]"
echo ""
echo "  Note: to switch between CUDA graphs / Eager variants of the same model,"
echo "        stop the container and delete its cached compilation artifacts first (d <num>)."
echo ""

RUNNING_CONTAINERS=$(docker ps --format "{{.Names}}" 2>/dev/null | grep "^vllm" | tr '\n' ',' || true)

# ── Show running model(s) ─────────────────────────────────────────────────────
python3 - "$RECIPES_DIR" "$RUNNING_CONTAINERS" <<'RUNNING_EOF'
import sys, os, re, subprocess, urllib.request, json

recipes_root = sys.argv[1]
ctrs = [c for c in sys.argv[2].split(',') if c]

if not ctrs:
    sys.exit(0)

recipe_map = {}
for mode in ('ironclaw', 'opencode', ''):
    d = os.path.join(recipes_root, mode) if mode else recipes_root
    if not os.path.isdir(d): continue
    for fname in os.listdir(d):
        if not fname.endswith('.yaml'): continue
        slug = fname[:-5]
        label = f"{mode}/{slug}" if mode else slug
        recipe_map[f"vllm-{slug}"] = (mode or "standalone", label)
        key = "vllm_" + slug.replace("-","_").replace(".","_").replace("/","_")
        recipe_map[key] = (mode or "standalone", label)
        if mode:
            key2 = "vllm_" + f"{mode}/{slug}".replace("-","_").replace(".","_").replace("/","_")
            recipe_map[key2] = (mode, label)

GREEN="\033[32m"; CYAN="\033[36m"; MAG="\033[35m"; RESET="\033[0m"; BOLD="\033[1m"
MODE_COLOR = {"ironclaw": MAG, "opencode": CYAN, "standalone": GREEN}

for ctr in ctrs:
    info = recipe_map.get(ctr)
    if info:
        mode, label = info
        col = MODE_COLOR.get(mode, GREEN)
        print(f"  {BOLD}Running{RESET}   {GREEN}●{RESET} {col}{mode}{RESET}  {label}")
    else:
        model_id = None
        try:
            r = subprocess.run(["docker","exec",ctr,"ps","ax"], capture_output=True, text=True, timeout=3)
            pm = re.search(r"--port\s+(\d+)", r.stdout)
            if pm:
                with urllib.request.urlopen(f"http://127.0.0.1:{pm.group(1)}/v1/models", timeout=2) as resp:
                    model_id = json.loads(resp.read())["data"][0]["id"]
        except Exception:
            pass
        suffix = f"  {CYAN}{model_id}{RESET}" if model_id else ""
        print(f"  {BOLD}Running{RESET}   {GREEN}●{RESET} {ctr}{suffix}")
print()
RUNNING_EOF

RECIPE_LIST=$(python3 - "$RECIPES_DIR" "$AVAIL_GB" "$RUNNING_CONTAINERS" "$HF_CACHE" <<'PYEOF'
import sys, os, re, subprocess, tempfile

recipes_dir  = sys.argv[1]
avail_gb     = int(sys.argv[2])
running_ctrs = set(sys.argv[3].split(',')) if sys.argv[3] else set()
hf_cache     = sys.argv[4]

def container_name(slug):
    return 'vllm_' + slug.replace('-', '_').replace('.', '_').replace('/', '_')

def is_cached(model_id, hf_cache):
    cache_name = 'models--' + model_id.replace('/', '--')
    snap_dir = os.path.join(hf_cache, cache_name, 'snapshots')
    if not os.path.isdir(snap_dir):
        return False
    return any(os.scandir(snap_dir))

def image_exists(tag):
    try:
        r = subprocess.run(['docker', 'image', 'inspect', tag], capture_output=True)
        return r.returncode == 0
    except Exception:
        return True

GREEN  = '\033[32m'
CYAN   = '\033[36m'
MAG    = '\033[35m'
RED    = '\033[31m'
DIM    = '\033[2m'
BOLD   = '\033[1m'
RESET  = '\033[0m'

GROUP_COLOR = {'ironclaw': MAG, 'opencode': CYAN}

def parse_yaml(path, slug):
    with open(path) as fh:
        raw = fh.read()
    name_m   = re.search(r'^name:\s*(.+)', raw, re.MULTILINE)
    model_m  = re.search(r'^model:\s*(.+)', raw, re.MULTILINE)
    port_m   = re.search(r'port:\s*(\d+)', raw)
    mem_m    = re.search(r'#\s*(?:Memory|RAM):\s*~?(\d+)GB', raw, re.IGNORECASE)
    util_m   = re.search(r'gpu_memory_utilization:\s*([\d.]+)', raw)
    toks_m   = re.search(r'tok/s:\s*~?([\d\-]+)', raw)
    ctx_m    = re.search(r'max_model_len:\s*(\d+)', raw)
    img_m    = re.search(r'^container:\s*(\S+)', raw, re.MULTILINE)
    name     = name_m.group(1).strip() if name_m else slug.split('/')[-1]
    model_id = model_m.group(1).strip() if model_m else ''
    port     = port_m.group(1) if port_m else '????'
    ram_gb   = int(mem_m.group(1)) if mem_m else (round(float(util_m.group(1)) * 128) if util_m else 0)
    toks     = toks_m.group(1) if toks_m else '??'
    ctx_k    = str(int(ctx_m.group(1)) // 1024) + 'k' if ctx_m else '??'
    img_tag  = img_m.group(1).strip() if img_m else 'vllm-node'
    img_ok   = img_tag == 'vllm-node' or image_exists(img_tag)
    return name, model_id, port, ram_gb, toks, ctx_k, img_ok

# Collect groups: standalone (root), then subdirs sorted
groups = []
root_yamls = sorted(f for f in os.listdir(recipes_dir) if f.endswith('.yaml'))
if root_yamls:
    groups.append(('', root_yamls, recipes_dir))
for subdir in sorted(d for d in os.listdir(recipes_dir)
                     if os.path.isdir(os.path.join(recipes_dir, d))):
    subpath = os.path.join(recipes_dir, subdir)
    yamls = sorted(f for f in os.listdir(subpath) if f.endswith('.yaml'))
    if yamls:
        groups.append((subdir, yamls, subpath))

# First pass: collect all entries to determine max label width
all_entries = []
for group_name, yamls, basepath in groups:
    for fname in yamls:
        slug = (f"{group_name}/{fname[:-5]}" if group_name else fname[:-5])
        path = os.path.join(basepath, fname)
        try:
            name, model_id, port, ram_gb, toks, ctx_k, img_ok = parse_yaml(path, slug)
        except Exception:
            continue
        leaf = slug.split('/')[-1]
        warn    = ' ⚠' if ram_gb > avail_gb else ''
        cname   = container_name(slug)
        running = cname in running_ctrs or f"vllm-{leaf}" in running_ctrs
        cached  = is_cached(model_id, hf_cache)
        all_entries.append((group_name, slug, leaf, model_id, port, ram_gb, toks, ctx_k, img_ok, warn, running, cached))

col_w = max((len(e[2]) for e in all_entries), default=34)
col_w = max(col_w, len('Recipe'))

print(f"  {'#':<3}  {'':2}  {'':2}  {'':2}  {'Recipe':<{col_w}}  {'Port':<5}  {'RAM':>5}  {'tok/s':>6}  {'ctx':>5}")
print(f"  {'-'*3}  {'--'}  {'--'}  {'--'}  {'-'*col_w}  {'-'*5}  {'-'*5}  {'-'*6}  {'-'*5}")

i = 0
prev_group = None
for group_name, slug, leaf, model_id, port, ram_gb, toks, ctx_k, img_ok, warn, running, cached in all_entries:
    if group_name != prev_group and group_name:
        col = GROUP_COLOR.get(group_name, DIM)
        print(f"  {col}{DIM}── {group_name} ──{RESET}")
        prev_group = group_name
    i += 1
    dot   = f'{GREEN}●{RESET}' if running else ' '
    check = f'{CYAN}✓{RESET}'  if cached  else ' '
    img   = ' '               if img_ok  else f'{RED}✗{RESET}'
    print(f"  {i:<3}  {dot}  {check}  {img}  {leaf:<{col_w}}  {port:<5}  {ram_gb:>4}GB  {toks:>6}  {ctx_k:>5}{warn}")

tmp = tempfile.NamedTemporaryFile(mode='w', suffix='.recipes', delete=False)
for (_, slug, leaf, model_id, *_rest) in all_entries:
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
printf "  \033[32m●\033[0m running   \033[36m✓\033[0m cached locally   \033[31m✗\033[0m image not built   ⚠ exceeds free RAM\n"
echo ""
echo "  [x <num>]  Unload from memory (stop container)   (e.g. x2)"
echo "  [l <num>]  Logs (tail -f container logs)         (e.g. l2)"
echo "  [h <num>]  Download from HuggingFace             (e.g. h5)"
echo "  [d <num>]  Delete from local cache               (e.g. d3)"
echo "  [q]        Quit"
echo ""

while true; do
    read -rp "Select model (1-${COUNT}): " sel

    if [[ "$sel" == "q" || "$sel" == "Q" ]]; then
        echo "Bye."
        exit 0
    fi

    # Unload: x<num>
    if [[ "$sel" =~ ^[xX][[:space:]]*([0-9]+)$ ]]; then
        idx="${BASH_REMATCH[1]}"
        if [ "$idx" -lt 1 ] || [ "$idx" -gt "$COUNT" ]; then
            echo "  Invalid selection."; continue
        fi
        unload_model "${SLUGS[$((idx-1))]}"
        exit $?
    fi

    # Logs: l<num>
    if [[ "$sel" =~ ^[lL][[:space:]]*([0-9]+)$ ]]; then
        idx="${BASH_REMATCH[1]}"
        if [ "$idx" -lt 1 ] || [ "$idx" -gt "$COUNT" ]; then
            echo "  Invalid selection."; continue
        fi
        cname=$(container_name "${SLUGS[$((idx-1))]}")
        if ! docker inspect "$cname" >/dev/null 2>&1; then
            echo "  ✗ ${cname} is not running"; continue
        fi
        echo "  Logs for ${cname} — Ctrl+C to stop"
        echo ""
        docker logs -f --tail 50 "$cname" 2>&1
        continue
    fi

    # Download from HF: h<num>
    if [[ "$sel" =~ ^[hH][[:space:]]*([0-9]+)$ ]]; then
        idx="${BASH_REMATCH[1]}"
        if [ "$idx" -lt 1 ] || [ "$idx" -gt "$COUNT" ]; then
            echo "  Invalid selection."; continue
        fi
        download_hf "${MODEL_IDS[$((idx-1))]}"
        exit $?
    fi

    # Delete from local cache: d<num>
    if [[ "$sel" =~ ^[dD][[:space:]]*([0-9]+)$ ]]; then
        idx="${BASH_REMATCH[1]}"
        if [ "$idx" -lt 1 ] || [ "$idx" -gt "$COUNT" ]; then
            echo "  Invalid selection."; continue
        fi
        delete_cache "${MODEL_IDS[$((idx-1))]}"
        exit $?
    fi

    # Launch model: <num>
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "$COUNT" ]; then
        echo "  Invalid selection."; continue
    fi

    RECIPE="${SLUGS[$((sel - 1))]}"
    read -rp "  Launch ${RECIPE}? [y/N]: " confirm
    [[ "$confirm" =~ ^[yY]$ ]] || continue

    echo ""
    launch "$RECIPE" "$@"
    break
done
