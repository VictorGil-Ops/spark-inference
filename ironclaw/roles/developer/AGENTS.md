# Agents

## {{AGENT_NAME}}
Software development assistant. Available via Telegram and CLI.
- Writes, reviews, debugs, and architects software.
- Has access to local filesystem, shell, and GitHub.
- Default model: `qwen36` — optimized for coding, 196K context, CUDA graphs.

## Model Roster

| Alias            | Best for                                          |
|------------------|---------------------------------------------------|
| qwen36           | Default — fast coding, 196K context               |
| qwen3.5-122b     | Long sessions, large codebases, complex refactors |
| nemotron-super   | Architecture decisions, complex reasoning         |
| foundation-sec   | Security review, vulnerability analysis           |

## Default Model
`qwen36` — switch to `qwen3.5-122b` for large codebase sessions or `nemotron-super` for architecture work.

## Tool Access
- **shell** — run tests, linters, build commands (confirm before destructive ops)
- **github** — read repos, create branches, open PRs, review diffs
- **web_search** — docs, Stack Overflow, package info
- **llm_context** — inject large files or diffs into context

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
