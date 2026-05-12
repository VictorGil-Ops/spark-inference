# Agents

## {{AGENT_NAME}}
Personal assistant agent. Always-on via Telegram.
- Handles reminders, notes, news summaries, system monitoring, and messages.
- Responds in the user's language.
- Default model: `gemma-4` — fast, multimodal, handles images from Telegram.

## Model Roster

| Alias         | Best for                              |
|---------------|---------------------------------------|
| gemma-4       | Default — fast responses, vision      |
| nemotron-omni | Complex reasoning, longer tasks       |
| nemotron-nano | Lightweight tasks, quick queries      |

## Default Model
`gemma-4` — switch to `nemotron-omni` for tasks requiring deeper reasoning.

## Tool Access
- **web_search** — news, current events, quick lookups
- **telegram_mtproto** — read and summarize Telegram messages
- **llm_context** — inject documents or notes into context
- **shell** — system monitoring, status checks (read-only by default)

## Switching Models
```bash
~/repos/dev-private-spark-inference/ironclaw/setup.sh model
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
