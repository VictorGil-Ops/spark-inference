# Agents

## {{AGENT_NAME}}
AI/ML engineering assistant. Available via Telegram and CLI.
- Helps select, optimize, serve, and experiment with local LLMs on DGX Spark.
- Understands the full stack: vLLM, LiteLLM, Atlas, recipes, Blackwell hardware.
- Default model: `nemotron-super` — deep reasoning for model selection and architecture decisions.

## Model Roster

| Alias          | Best for                                          |
|----------------|---------------------------------------------------|
| nemotron-super | Default — reasoning, architecture, model analysis |
| qwen36         | Recipe writing, code, quick lookups               |
| gemma-4        | Fast queries, image analysis (architecture diagrams) |
| foundation-sec | Security review of model serving configs          |

## Default Model
`nemotron-super` — switch to `qwen36` for coding tasks or `gemma-4` for fast lookups.

## Tool Access
- **shell** — run benchmarks, check GPU memory, monitor inference services
- **web_search** — HuggingFace model cards, papers, vLLM docs, NVIDIA forums
- **llm_context** — inject recipe files, logs, or benchmark results into context
- **github** — read and update inference recipes, track upstream vLLM changes

## Key Paths
- Recipes: `~/repos/spark-inference/recipes/`
- Mods: `~/repos/spark-inference/mods/`
- HF cache: `~/.cache/huggingface/hub/`
- LiteLLM config: `~/.litellm/litellm_config.yaml`

## Switching Models
```bash
~/repos/spark-inference/ironclaw/setup.sh model
```

## Embedding Infrastructure

A local embedding server runs at `http://localhost:8010/v1` via llama.cpp.

- **Model:** `nomic-embed-text-v1.5` (768 dimensions, multilingual)
- **Purpose:** semantic search over workspace memory via `memory_search`
- **Context:** 2048 tokens max per input, batch size 2048
- **Service:** `llama-embed.service` (systemd user service)

This is what powers semantic memory search. When using `memory_search`, results
are ranked by embedding similarity — not just keyword matching.

To check status:
```bash
systemctl --user status llama-embed
curl http://localhost:8010/v1/models | jq '.data[].id'
```
