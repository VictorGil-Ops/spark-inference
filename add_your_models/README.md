# Adding Models to the DGX Spark Stack

## Before you start — protect the upstream repo

After cloning, run this once:

```bash
bash setup-local.sh
```

It disables `git push` to the upstream repo and installs a pre-push hook.
Your local changes are yours — pull updates freely, but pushes require an
explicit fork remote. See `setup-local.sh` for details.

---

Two files need to be edited to add a new model:

1. `recipes/<your-model>.yaml` — tells vLLM how to serve it
2. `ironclaw/litellm/litellm_config.yaml` — exposes it through the proxy

---

## Step 1 — Write the recipe YAML

Create `recipes/<slug>.yaml`. The slug becomes the container name and the key used by `run.sh`, `start-all.sh`, and `setup.sh`.

### Minimal template

```yaml
# Recipe: <Model name> — <one-line description>
# Memory: ~XGB | tok/s: ~YY
recipe_version: "1"
name: <Display name>
description: <Description>

model: <HuggingFace model ID>
container: vllm-node
solo_only: true

defaults:
  port: <unique port, see Port allocation below>
  host: 0.0.0.0
  tensor_parallel: 1
  gpu_memory_utilization: 0.25
  max_model_len: 32768
  max_num_seqs: 8

command: |
  vllm serve <HuggingFace model ID> \
    --host {host} \
    --port {port} \
    --max-model-len {max_model_len} \
    --gpu-memory-utilization {gpu_memory_utilization} \
    --max-num-seqs {max_num_seqs} \
    --enforce-eager \
    --kv-cache-dtype fp8 \
    --load-format fastsafetensors \
    --attention-backend flashinfer \
    --enable-prefix-caching \
    --trust-remote-code
```

### Required comment fields

`run.sh` reads these to populate the model table:

```yaml
# Memory: ~35GB | tok/s: ~50-58
```

Both fields are required. If `tok/s` is unknown, put `~??`. RAM falls back to
`gpu_memory_utilization × 128` if the comment is absent, but it is better to
be explicit.

---

## Port allocation

Ports in use by existing recipes:

| Port | Recipe |
|------|--------|
| 8000 | nemotron-3-nano-nvfp4 |
| 8001 | qwen3.6-35b-fp8 |
| 8002 | llama-primus-reasoning |
| 8003 | foundation-sec-8b |
| 8004 | nemotron3-nano-nvfp4-w4a16 |
| 8100 | single-nemotron-super-120b |

Pick the next free port. Multi-model stacks typically use 8000–8099; single
powerful mode uses 8100+. Do not reuse a port — two models on the same port
will conflict even if only one runs at a time (LiteLLM caches the routing).

---

## GPU memory sizing on the DGX Spark

The Spark has **128 GB of unified memory** shared between CPU and GPU.
The usable ceiling for vLLM is ~122 GB after OS overhead.

`gpu_memory_utilization` is a fraction of that total:

| Value | Reserved for vLLM | Leaves for OS + other models |
|-------|-------------------|------------------------------|
| 0.25  | ~32 GB            | ~90 GB                       |
| 0.35  | ~45 GB            | ~77 GB                       |
| 0.40  | ~51 GB            | ~71 GB                       |
| 0.70  | ~90 GB            | ~32 GB                       |
| 0.90  | ~115 GB           | ~7 GB (single model only)    |

> **Multi-model mode**: keep the sum of all `gpu_memory_utilization` values
> below ~0.95 to avoid OOM during CUDA graph capture.
>
> **Single powerful mode** (`solo_only: true`): values up to 0.90 are safe
> if all other model containers are stopped first.

### KV cache memory

`gpu_memory_utilization` covers both weights **and** KV cache.
For large context lengths (`max_model_len > 32768`) or high concurrency
(`max_num_seqs > 8`), increase `gpu_memory_utilization` or reduce
`max_model_len` to avoid KV cache OOM at runtime.

---

## SM12.1 Blackwell compatibility

The GB10 uses SM12.1 (Blackwell). Not all vLLM backends are compatible:

| Feature | Status | Notes |
|---------|--------|-------|
| `--attention-backend flashinfer` | ✓ Required | FlashAttention does not support SM12.1 |
| `--kv-cache-dtype fp8` | ✓ Recommended | Saves ~30% KV memory with negligible quality loss |
| `--enforce-eager` | ✓ Saves 13 GB | CUDA graphs add 5× speedup but cost ~13 GB extra RAM |
| `--moe-backend cutlass` | ✓ For MoE models | Use with Nemotron-type architectures |
| CUTLASS FP4 kernels | ✗ Falls back to Marlin | Marlin path is still fast |
| `VLLM_FLASHINFER_MOE_BACKEND=throughput` | ✗ Crashes | Always use `latency` backend |

### Quantization formats supported

| Format | Flag | Notes |
|--------|------|-------|
| FP8 (weights) | default for `*-fp8` models | No extra flag needed |
| NVFP4 | `--quantization modelopt_fp4` | Requires `--kv-cache-dtype fp8` |
| W4A16 (GPTQ/AWQ) | `--quantization gptq` or `awq` | Marlin kernel used automatically |
| BF16 / FP16 | no flag | Full precision, highest RAM |

---

## Model architecture compatibility

vLLM on SM12.1 supports most standard transformer architectures:

- **Dense transformers** (Llama, Mistral, Qwen, Phi, Gemma …) — full support
- **MoE (Mixture of Experts)** (Qwen-MoE, Nemotron-MoE, DeepSeek-MoE …) — supported, add `--moe-backend cutlass`
- **Hybrid SSM/Transformer** (Mamba-2, Jamba, Nemotron-Super) — supported with `--mamba_ssm_cache_dtype float32`
- **Vision-language models** (LLaVA, Qwen-VL, InternVL …) — supported, no extra flags
- **Embedding models** — not suited for this stack (no chat endpoint)

### Models that need extra flags

```yaml
# MoE (e.g. Nemotron-Super, DeepSeek-MoE)
command: |
  vllm serve ... \
    --moe-backend cutlass

# Hybrid Mamba-2 SSM (e.g. Nemotron-Super)
command: |
  vllm serve ... \
    --mamba_ssm_cache_dtype float32

# Reasoning models (chain-of-thought parser)
command: |
  vllm serve ... \
    --reasoning-parser <parser-name>   # qwen3, granite, deepseek_r1, ...

# Tool-calling / function calling
command: |
  vllm serve ... \
    --enable-auto-tool-choice \
    --tool-call-parser <parser-name>   # qwen3_coder, llama3_json, ...
```

---

## Step 2 — Add the model to LiteLLM

Edit `ironclaw/litellm/litellm_config.yaml` and append an entry to `model_list`:

```yaml
  - model_name: <short-alias>          # used by IronClaw and Open WebUI
    litellm_params:
      model: openai/<HuggingFace model ID>
      api_base: http://127.0.0.1:<port>/v1   # must match recipe port
      api_key: sk-no-key
```

`model_name` is the alias you use everywhere else:
- `setup.sh model` — select it as the active IronClaw model
- Open WebUI model picker
- Direct API calls: `"model": "<short-alias>"`

### Two models on the same port

It is valid to have two `model_name` entries pointing to the same port if the
recipes are mutually exclusive (i.e. you never run both at the same time):

```yaml
  - model_name: primus
    litellm_params:
      model: openai/trendmicro-ailab/Llama-Primus-Reasoning
      api_base: http://127.0.0.1:8002/v1
      api_key: sk-no-key

  - model_name: foundation-sec
    litellm_params:
      model: openai/fdtn-ai/Foundation-Sec-8B-Instruct
      api_base: http://127.0.0.1:8002/v1
      api_key: sk-no-key
```

Only the model currently loaded on port 8002 will respond; the other will
return an error, so keep this in mind when switching.

---

## Step 3 — Restart LiteLLM

```bash
systemctl --user restart litellm
```

Or use the control panel: `./spark.sh → [5] IronClaw Setup → [2] Change default model`
(the model switcher restarts LiteLLM automatically).

Verify the new model is registered:

```bash
curl -s http://127.0.0.1:4000/v1/models \
  -H "Authorization: Bearer sk-no-key" | \
  python3 -c "import sys,json; [print(m['id']) for m in json.load(sys.stdin)['data']]"
```

---

## Full example — adding Phi-4-mini

### `recipes/phi-4-mini.yaml`

```yaml
# Recipe: Phi-4-Mini-Instruct — Microsoft
# Memory: ~12GB | tok/s: ~80
recipe_version: "1"
name: Phi-4-Mini-Instruct
description: Microsoft Phi-4-Mini — fast, low-RAM general assistant (port 8005)

model: microsoft/Phi-4-mini-instruct
container: vllm-node
solo_only: true

defaults:
  port: 8005
  host: 0.0.0.0
  tensor_parallel: 1
  gpu_memory_utilization: 0.12
  max_model_len: 16384
  max_num_seqs: 16

command: |
  vllm serve microsoft/Phi-4-mini-instruct \
    --host {host} \
    --port {port} \
    --max-model-len {max_model_len} \
    --gpu-memory-utilization {gpu_memory_utilization} \
    --max-num-seqs {max_num_seqs} \
    --enforce-eager \
    --kv-cache-dtype fp8 \
    --load-format fastsafetensors \
    --attention-backend flashinfer \
    --enable-prefix-caching \
    --enable-auto-tool-choice \
    --tool-call-parser hermes \
    --trust-remote-code
```

### `ironclaw/litellm/litellm_config.yaml` entry

```yaml
  - model_name: phi4-mini
    litellm_params:
      model: openai/microsoft/Phi-4-mini-instruct
      api_base: http://127.0.0.1:8005/v1
      api_key: sk-no-key
```

Then:
```bash
# Download the model
./scripts/run.sh   # → h<num> to download from HuggingFace

# Launch it
./scripts/run.sh phi-4-mini

# Restart LiteLLM
systemctl --user restart litellm

# Switch IronClaw to it
./spark.sh → [5] IronClaw Setup → [2] Change default model
```
