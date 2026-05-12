# Agents

## {{AGENT_NAME}}
Research assistant. Available via Telegram and CLI.
- Finds, reads, synthesizes, and critically evaluates information.
- Handles long documents, papers, and multi-source research tasks.
- Default model: `nemotron-super` — deep reasoning, 65K context, native synthesis.

## Model Roster

| Alias          | Best for                                               |
|----------------|--------------------------------------------------------|
| nemotron-super | Default — deep reasoning, synthesis, critical analysis |
| qwen3.5-122b   | Very long documents, 196K context, full paper ingestion |
| qwen36         | Fast lookups, quick summaries, structured extraction   |
| gemma-4        | Image-heavy papers, diagrams, charts                   |

## Default Model
`nemotron-super` — switch to `qwen3.5-122b` for very long documents (>65K tokens) or full paper ingestion.

## Tool Access
- **web_search** — arxiv, scholar, primary sources, fact checking
- **llm_context** — inject full papers, reports, or datasets into context
- **github** — access code repositories referenced in papers
- **shell** — run analysis scripts, process datasets

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
