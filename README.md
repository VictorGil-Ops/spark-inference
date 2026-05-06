# dev-private-spark-inference

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
git clone https://github.com/VictorGil-Ops/dev-private-spark-inference.git ~/repos/dev-private-spark-inference
```

### Step 3 — Install IronClaw (agent + Telegram)

```bash
bash ~/repos/dev-private-spark-inference/ironclaw/install.sh <telegram_bot_token> <telegram_user_id>
```

After first start, approve the Telegram pairing code:
```bash
ironclaw pairing approve telegram <CODE>
```

### Step 4 — Install LiteLLM proxy (multi-model routing)

```bash
bash ~/repos/dev-private-spark-inference/ironclaw/litellm/install.sh
```

Then point IronClaw to the proxy:
```bash
ironclaw onboard --step provider
# Select: OpenAI-compatible
# URL: http://127.0.0.1:4000/v1
# API key: sk-spark-local
# Model: nemotron-nano
```

### Step 5 — Start the models

> ⚠️ All recipes are designed for **multi-model mode** (3 models running simultaneously, ~102GB total).
> If you need maximum quality for a single task, use **Single Powerful Mode** instead (see below).

```bash
cd ~/repos/dev-private-spark-inference

# Start all three models
./scripts/run.sh nemotron-3-nano-nvfp4 -d    # orchestrator  — port 8000, ~32GB
./scripts/run.sh qwen3.6-35b-fp8 -d          # coding+vision — port 8001, ~45GB
./scripts/run.sh deepseek-r1-32b-fp8 -d      # reasoning     — port 8002, ~25GB

# Verify
./scripts/benchmark.sh 8000
```

`run.sh` also works interactively — run it without arguments to pick from a menu that shows all available recipes with estimated RAM, tok/s, context length, and a `●` next to models already running:

```
./scripts/run.sh

=== DGX Spark — Model Launcher ===
Memory: 57GB used / 122GB total  (65GB free)

  #       Recipe                              Port     RAM   tok/s    ctx
  ---  --  ----------------------------------  -----  -----  ------  -----
  1    ●   deepseek-r1-32b-fp8                 8002     25GB   20-25    32k
  2    ●   nemotron-3-nano-nvfp4               8000     32GB   50-58    32k
  3        nemotron3-nano-nvfp4-w4a16          8000     18GB      42    32k
  4    ●   qwen3.6-35b-fp8                     8001     45GB   28-30    32k
  5        single-nemotron-super-120b          8000     87GB   17-20   128k ⚠
  6        single-qwen3-235b-int4              8000    115GB   15-18    32k ⚠

Select model (1-6):
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
Nemotron-Nano Qwen3.6   DeepSeek-R1
(orchestrator) (coding)  (reasoning)
~32GB       ~45GB      ~25GB
```

### Model routing

| Model name | Port | RAM | Best for |
|------------|------|-----|----------|
| `nemotron-nano` | 8000 | ~32GB | Fast responses, routing decisions |
| `qwen36` | 8001 | ~45GB | Code generation, vision, complex agents |
| `deepseek-r1` | 8002 | ~25GB | Deep reasoning, pentest, OSINT |

Switch model manually:
```bash
ironclaw models set qwen36
ironclaw models set nemotron-nano
```

---

## Single Powerful Mode

Stop all agents and run one high-capacity model with the full 128GB.
Use for deep analysis, complex CTF, long-context coding, or max-quality tasks.

```bash
# Stop multi-model stack first
docker stop vllm_nemotron_nano vllm_qwen36 vllm_deepseek_r1 2>/dev/null || true

# Option A — Nemotron-3-Super-120B (best for reasoning + agentic)
# RAM: ~87GB | tok/s: ~17-20 | Context: 131k
./scripts/run.sh single-nemotron-super-120b -d

# Option B — Qwen3-235B-A22B FP8 (best for coding + complex agents)
# RAM: ~115GB | tok/s: ~15-18 | Context: 32k
./scripts/run.sh single-qwen3-235b-int4 -d
```

Return to multi-model mode:
```bash
docker stop vllm_nemotron_super vllm_qwen3_235b 2>/dev/null || true
./scripts/run.sh nemotron-3-nano-nvfp4 -d
./scripts/run.sh qwen3.6-35b-fp8 -d
./scripts/run.sh deepseek-r1-32b-fp8 -d
```

---

## Persistence on Reboot

### vLLM models

Models do NOT auto-start on reboot. Use the start script:
```bash
bash ~/repos/dev-private-spark-inference/scripts/start-all.sh
```

Auto-start on login:
```bash
echo 'bash ~/repos/dev-private-spark-inference/scripts/start-all.sh' >> ~/.bashrc
```

### IronClaw (systemd — auto-starts on reboot)
```bash
systemctl --user is-enabled ironclaw   # should show "enabled"
systemctl --user status ironclaw       # check after reboot
```

Enable lingering (start without login session):
```bash
sudo loginctl enable-linger $USER
```

### PostgreSQL (auto-starts on reboot)
```bash
sudo systemctl is-enabled postgresql   # should show "enabled"
```

### Quick recovery after reboot
```bash
bash ~/repos/dev-private-spark-inference/scripts/start-all.sh
systemctl --user status ironclaw
curl http://localhost:8000/health
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

## Benchmarks

| Model | Mode | tok/s | RAM |
|-------|------|-------|-----|
| Nemotron-3-Nano NVFP4 | CUDA graphs | **58.6** | ~32GB |
| Nemotron-3-Nano NVFP4 | Eager | 10.9 | ~32GB |
| Qwen3.6-35B-A3B FP8 | CUDA graphs | **33.9** | ~45GB |

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
docker stop vllm_deepseek_r1

# Stop all models
docker stop vllm_nemotron_nano vllm_qwen36 vllm_deepseek_r1 2>/dev/null || true

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

# Benchmark tok/s
bash ~/repos/dev-private-spark-inference/scripts/benchmark.sh 8000
bash ~/repos/dev-private-spark-inference/scripts/benchmark.sh 8001
bash ~/repos/dev-private-spark-inference/scripts/benchmark.sh 8002

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

# Check current model
ironclaw models status

# Switch model
ironclaw models set nemotron-nano
ironclaw models set qwen36
ironclaw models set deepseek-r1

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
psql "postgres://victorgil:ironclaw@localhost:5432/ironclaw?sslmode=disable"

# Check IronClaw settings
psql "postgres://victorgil:ironclaw@localhost:5432/ironclaw?sslmode=disable" \
  -c "SELECT key, value FROM settings ORDER BY key;"
```

### Flush memory cache (before launching models)

```bash
sudo sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches'
```
