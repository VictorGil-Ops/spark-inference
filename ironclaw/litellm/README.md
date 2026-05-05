# LiteLLM Proxy

Unifies all vLLM models under a single OpenAI-compatible endpoint on port 4000.
IronClaw points to this proxy to route between models by name.

## Install / Update

```bash
bash ~/repos/dev-private-spark-inference/ironclaw/litellm/install.sh
```

Re-run at any time to update LiteLLM or apply config changes.

## Models

| Name | Port | RAM | Role |
|------|------|-----|------|
| `nemotron-nano` | 8000 | ~32GB | Orchestrator |
| `qwen36` | 8001 | ~45GB | Coding + Vision |
| `deepseek-r1` | 8002 | ~25GB | Reasoning + Pentest |

## Reconfigure IronClaw

```bash
ironclaw onboard --step provider
# Select: OpenAI-compatible
# URL: http://127.0.0.1:4000/v1
# API key: sk-spark-local
# Model: nemotron-nano
```

## Basic Management

```bash
# Status
systemctl --user status litellm

# Start / Stop / Restart
systemctl --user start litellm
systemctl --user stop litellm
systemctl --user restart litellm

# Live logs
journalctl --user -u litellm -f

# Test endpoint
curl -s http://127.0.0.1:4000/v1/models \
  -H "Authorization: Bearer sk-no-key" | python3 -m json.tool

# Test a model (requires Nemotron running on port 8000)
curl -s http://127.0.0.1:4000/v1/chat/completions \
  -H "Authorization: Bearer sk-no-key" \
  -H "Content-Type: application/json" \
  -d '{"model":"nemotron-nano","messages":[{"role":"user","content":"hello"}],"max_tokens":50}'

# Add a new model — edit litellm_config.yaml then:
systemctl --user restart litellm

# Check which models are registered
curl -s http://127.0.0.1:4000/v1/models \
  -H "Authorization: Bearer sk-no-key" | \
  python3 -c "import sys,json; [print(m['id']) for m in json.load(sys.stdin)['data']]"
```

## Add a New Model

Edit `litellm_config.yaml` and add a new entry under `model_list`:

```yaml
- model_name: my-new-model
  litellm_params:
    model: openai/model-id-in-vllm
    api_base: http://127.0.0.1:8003/v1
    api_key: sk-no-key
```

Then restart the proxy:
```bash
systemctl --user restart litellm
```
