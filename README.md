# spark-inference

Personal inference stack for NVIDIA DGX Spark (GB10 / SM12.1 Blackwell).
Built on top of [eugr/spark-vllm-docker](https://github.com/eugr/spark-vllm-docker).

## Hardware
- GPU: NVIDIA GB10 (SM12.1, Blackwell)
- Memory: 128 GB unified
- CPU: 20-core ARM Grace (aarch64)
- CUDA: 13.2

---

## Installation Order

Follow these steps in order:

### Step 1 — Build the base container (once, ~8 min)

```bash
git clone https://github.com/eugr/spark-vllm-docker.git ~/repos/spark-vllm-docker
cd ~/repos/spark-vllm-docker && ./build-and-copy.sh
```

### Step 2 — Clone this repo

```bash
git clone https://github.com/VictorGil-Ops/spark-inference.git ~/repos/spark-inference
```

### Step 3 — Launch the control panel

From here you can install and manage everything:

```bash
cd ~/repos/spark-inference
./spark.sh
```

It prints a banner explaining the logical flow (vLLM → LiteLLM → IronClaw → WebUI), shows live system status, and offers a menu delegating to each sub-script:

```
  ╔══════════════════════════════════════════════════════════════╗
  ║           DGX Spark — Personal Inference Stack              ║
  ║     NVIDIA GB10 · 128 GB unified · SM12.1 Blackwell         ║
  ╚══════════════════════════════════════════════════════════════╝

  System    57GB / 122GB RAM used  (65GB free)
  Models    vllm_nemotron3_nano_nvfp4_w4a16
  LiteLLM   running
  IronClaw  running
  WebUI     running  → http://localhost:3000
  Watchdog  enabled  (fires 5 min after boot)

  [1] Recovery & Watchdog   start-all.sh
  [2] Models                run.sh  (launch · unload · download)
  [3] Benchmark             benchmark.sh
  [4] Open WebUI            webui.sh
  [5] IronClaw Setup        setup.sh  (install · change model)
  [6] Reset IronClaw        reset-ironclaw.sh
```

### Step 4 — Install IronClaw (agent + Telegram)

From the control panel select **[5] IronClaw Setup**, then **[1] Install IronClaw**. The wizard asks for:

- Telegram bot token and your numeric user ID
- DB user / password (defaults: `ironclaw_user` / `ironclaw`)
- Default model (picks from the LiteLLM config)

After first start, approve the Telegram pairing code:
```bash
ironclaw pairing approve telegram <CODE>
```

### Step 5 — Install LiteLLM proxy (multi-model routing)

```bash
bash ~/repos/spark-inference/ironclaw/litellm/install.sh
```

This registers the proxy as a systemd user service on port 4000. Once running, switch models anytime from the control panel: **[5] IronClaw Setup → [2] Change default model**.

### Step 6 — Start the models

> ⚠️ All recipes are designed for **multi-model mode** (2-3 models running simultaneously, ~120GB total).
> If you need maximum quality for a single task, use **Single Powerful Mode** instead (see below).

```bash
cd ~/repos/spark-inference
./scripts/run.sh
```

`run.sh` shows all available recipes with estimated RAM, tok/s, context length, and a `●` next to models already running:

```
=== DGX Spark — Model Launcher ===
Memory: 57GB used / 122GB total  (65GB free)

  #       Recipe                              Port     RAM   tok/s    ctx
  ---  --  ----------------------------------  -----  -----  ------  -----
  1    ●   nemotron-3-nano-nvfp4               8000     35GB   50-58    32k
  2        nemotron3-nano-nvfp4-w4a16          8004     35GB   45-52    32k
  3    ●   qwen3.6-35b-fp8                     8001     45GB   28-30    32k
  4        single-nemotron-super-120b          8100     87GB   17-20   128k ⚠

  ● running   ✓ cached locally   ⚠ exceeds free RAM

  [x <num>]  Unload from memory (stop container)
  [h <num>]  Download from HuggingFace
  [d <num>]  Delete from local cache

Select model (1-4):
```

---

## Architecture (Multi-Model Mode)

```
Telegram / CLI
│
▼
IronClaw → LiteLLM Proxy (port 4000)
│
┌──────────┼──────────┐
▼          ▼          ▼
port 8000  port 8001  port 8002
Nemotron-Nano Qwen3.6   Llama-primus
(orchestrator) (coding) (reasoning)
~32GB       ~45GB      ~35GB
```

### Model routing

| Model | Format | Port | tok/s | RAM | Mode | Role |
|-------|--------|------|-------|-----|------|------|
| Nemotron-3-Nano-30B NVFP4 | NVFP4 | 8000 | 41.5 / 58.6* | ~32GB | Eager | Orchestrator |
| Qwen3.6-35B-A3B | FP8 | 8001 | 28.6 | ~45GB | Eager | Coding + Vision |
| Llama-Primus-Reasoning 8B | BF16 | 8002 | 14.4 | ~35GB | Eager | Pentest + Reasoning |
| Foundation-Sec-8B-Instruct | BF16 | 8002 | 14.5 | ~35GB | Eager | CVE / MITRE / SOC |
| Nemotron-3-Nano-30B W4A16 | INT4 | 8004 | ~42 | ~18GB | Eager | Low-RAM orchestrator |
| Nemotron-3-Super-120B | NVFP4 | 8100 | ~17-20 | ~87GB | CUDA graphs | Single powerful mode |

\* 58.6 tok/s with CUDA graphs (single model). Eager required when running 3+ models simultaneously (~116GB total).

Full benchmark data: [docs/benchmarks.md](docs/benchmarks.md)

Switch model via the control panel: `./spark.sh → [5] IronClaw Setup → [2] Change default model`

---

## Single Powerful Mode

Stop all agents and run one high-capacity model with the full 128GB.
Use for deep analysis, complex CTF, long-context coding, or max-quality tasks.

```bash
# Stop multi-model stack first
docker stop vllm_nemotron_nano vllm_qwen36 2>/dev/null || true

# Option A — Nemotron-3-Super-120B (best for reasoning + agentic)
# RAM: ~87GB | tok/s: ~17-20 | Context: 131k
./scripts/run.sh single-nemotron-super-120b -d

```

Return to multi-model mode:
```bash
docker stop vllm_nemotron_super vllm_qwen3_235b 2>/dev/null || true
./scripts/run.sh nemotron-3-nano-nvfp4 -d
./scripts/run.sh qwen3.6-35b-fp8 -d
```

---

## Recovery & Watchdog

### Interactive recovery (after reboot)

```bash
bash ~/repos/spark-inference/scripts/start-all.sh
# or via the control panel: ./spark.sh → [1]
```

The menu shows current memory, last model, and watchdog status, then offers:
- **[1] Recover** — starts the last model + LiteLLM + IronClaw
- **[2] Launch model** — opens the `run.sh` interactive picker
- **[3] LiteLLM only**
- **[4] IronClaw only**
- **[5] Install / remove watchdog**

### Watchdog (auto-recovery on boot)

A systemd user timer (`spark-watchdog.timer`) that fires 5 minutes after boot and runs `start-all.sh --auto`.

```bash
# Install (from menu [5], or directly)
bash ~/repos/spark-inference/scripts/start-all.sh --install-watchdog

# Remove
bash ~/repos/spark-inference/scripts/start-all.sh --uninstall-watchdog
```

What `--auto` does in order:
1. Checks network — reconnects via `nmcli` if needed
2. Launches `~/.ironclaw/last_model` — **skips** if the model requires > 97% of total RAM
3. Starts LiteLLM (polls health endpoint until ready)
4. Starts IronClaw

Enable lingering so the timer fires even without an active login session:
```bash
sudo loginctl enable-linger $USER
```

The last launched model is written automatically by `run.sh` and `setup.sh model` to `~/.ironclaw/last_model`.

```bash
# Check watchdog status
systemctl --user status spark-watchdog.timer
journalctl --user -u spark-watchdog.service -n 50 --no-pager
```

### Services that auto-start on reboot (no watchdog needed)

```bash
# IronClaw and LiteLLM — managed by systemd user services
systemctl --user is-enabled ironclaw litellm   # should show "enabled"

# PostgreSQL
sudo systemctl is-enabled postgresql           # should show "enabled"
```

---

## Key SM12.1 Findings

- CUDA graphs: **5.4x speedup** vs eager (58.6 vs 10.9 tok/s)
- `gpu_memory_utilization 0.25` saves ~60GB vs default (see [sggin1's post](https://forums.developer.nvidia.com/t/364886))
- FlashInfer attention backend required (FlashAttn doesn't support SM12.1)
- `VLLM_FLASHINFER_MOE_BACKEND=latency` required (throughput backend crashes)
- CUTLASS FP4 kernels fall back to Marlin on SM12.1
- `--enforce-eager` saves 13GB with only 3% tok/s loss for single-user
- TurboQuant KV compression: PR #38479 not merged yet

---

## Management & Troubleshooting

### Docker — model containers

```bash
# List running containers
docker ps

# List all containers (including stopped)
docker ps -a

# Stop a model
docker stop vllm_nemotron_nano
docker stop vllm_qwen36

# Stop all models
docker stop vllm_nemotron_nano vllm_qwen36 2>/dev/null || true

# Remove a stopped container
docker rm vllm_nemotron_nano

# Start a stopped container
docker start vllm_nemotron_nano

# See all stopped containers
docker ps -a --filter "status=exited"

# Start all stopped model containers at once
docker ps -a --filter "status=exited" --format "{{.Names}}" | xargs docker start

# Live logs from a model
docker logs -f vllm_nemotron_nano

# Last 50 lines of logs
docker logs --tail 50 vllm_nemotron_nano

# Memory usage per container
docker stats --no-stream

# System memory (unified — nvidia-smi doesn't work on GB10)
watch -n1 "awk '/MemTotal/{t=\$2}/MemAvailable/{a=\$2}END{printf \"Used: %.1f GB / %.1f GB\n\",(t-a)/1048576,t/1048576}' /proc/meminfo"
```

### Open WebUI

Browser chat UI connected to the LiteLLM proxy (port 4000). Port persisted in `~/.ironclaw/webui.conf`.

```bash
# Interactive menu (install · start · stop · port · update · remove)
bash ~/repos/spark-inference/scripts/webui.sh
# or via the control panel: ./spark.sh → [4]

# Direct commands
bash ~/repos/spark-inference/scripts/webui.sh install
bash ~/repos/spark-inference/scripts/webui.sh start
bash ~/repos/spark-inference/scripts/webui.sh stop
bash ~/repos/spark-inference/scripts/webui.sh restart
bash ~/repos/spark-inference/scripts/webui.sh port 3001   # change host port (recreates container)
bash ~/repos/spark-inference/scripts/webui.sh update      # pull latest image
bash ~/repos/spark-inference/scripts/webui.sh status
bash ~/repos/spark-inference/scripts/webui.sh remove      # stop + remove container (data volume kept)
```

Default port: 3000. The data volume (`open-webui`) is preserved across removes and updates.

### vLLM — model health & performance

```bash
# Check if a model is ready
curl -sf http://localhost:8000/health && echo "OK" || echo "NOT READY"
curl -sf http://localhost:8001/health && echo "OK" || echo "NOT READY"
curl -sf http://localhost:8002/health && echo "OK" || echo "NOT READY"

# List loaded models
curl -s http://localhost:8000/v1/models | python3 -m json.tool
curl -s http://localhost:8001/v1/models | python3 -m json.tool
curl -s http://localhost:8002/v1/models | python3 -m json.tool

# Benchmark tok/s — interactive (picks from running models)
bash ~/repos/spark-inference/scripts/benchmark.sh

# Benchmark a specific port directly
bash ~/repos/spark-inference/scripts/benchmark.sh 8000

# Quick test
curl -s http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-NVFP4","messages":[{"role":"user","content":"hello"}],"max_tokens":20}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'])"
```

### IronClaw

```bash
# Status
systemctl --user status ironclaw

# Start / Stop / Restart
systemctl --user start ironclaw
systemctl --user stop ironclaw
systemctl --user restart ironclaw

# Live logs
journalctl --user -u ironclaw -f

# Last 50 lines
journalctl --user -u ironclaw -n 50 --no-pager

# Switch model interactively (shows all LiteLLM models, marks current)
bash ~/repos/spark-inference/ironclaw/setup.sh model

# Or switch directly
ironclaw models set nemotron-nano
ironclaw models set qwen36

# Check Telegram pairing
ironclaw pairing list

# Run interactively (CLI mode)
export $(cat ~/.ironclaw/.env | grep -v "^#" | xargs)
ironclaw run --no-onboard
```

#### ⚠️ Troubleshooting IronClaw

If IronClaw is not responding, crashing, or returning LLM errors, run the reset script:

```bash
bash ~/repos/spark-inference/scripts/reset-ironclaw.sh
```

The script fixes automatically:

| Problem | Fix |
|---|---|
| Stale PID file (another instance running) | Removes PID file, kills leftover processes |
| Jobs stuck in `running`/`pending` | Marks them as `failed` |
| Expired pairing requests | Deletes them |
| Idle DB connections accumulated in pool | Terminates connections above threshold |
| `activated_channels` missing from DB | Inserts `["telegram"]` |
| Model name not recognized by LiteLLM | Sets `selected_model` to first available model |
| LiteLLM proxy down | Restarts it before starting IronClaw |

Common errors and what the script fixes:

```
Connection pool error: error performing TLS handshake  → stale pool, fixed by restart
LLM error: No connected db                             → wrong model name or API key mismatch
No channels started successfully                       → activated_channels missing in DB
Another IronClaw instance is already running           → stale PID file
```

### LiteLLM proxy

```bash
# Status
systemctl --user status litellm

# Restart (after config changes)
systemctl --user restart litellm

# Live logs
journalctl --user -u litellm -f

# List registered models
curl -s http://127.0.0.1:4000/v1/models \
  -H "Authorization: Bearer sk-spark-local" | \
  python3 -c "import sys,json; [print(m['id']) for m in json.load(sys.stdin)['data']]"

# Test a model through the proxy
curl -s http://127.0.0.1:4000/v1/chat/completions \
  -H "Authorization: Bearer sk-spark-local" \
  -H "Content-Type: application/json" \
  -d '{"model":"nemotron-nano","messages":[{"role":"user","content":"hello"}],"max_tokens":20}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['choices'][0]['message']['content'])"
```

### PostgreSQL (IronClaw database)

```bash
# Status
sudo systemctl status postgresql

# Connect to IronClaw DB
psql "postgres://user:passwd@localhost:5432/ironclaw?sslmode=disable"

# Check IronClaw settings
psql "postgres://user:passwd@localhost:5432/ironclaw?sslmode=disable" \
  -c "SELECT key, value FROM settings ORDER BY key;"
```

### Flush memory cache (before launching models)

```bash
sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
```
