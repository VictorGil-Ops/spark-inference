# Agents

## {{AGENT_NAME}}
Security research assistant. Available via Telegram and CLI.
- Threat modeling, vulnerability analysis, code review, CTF, security research.
- Thinks adversarially. Evidence-based findings.
- Default model: `foundation-sec` — purpose-built for security tasks.

## Model Roster

| Alias          | Best for                                           |
|----------------|----------------------------------------------------|
| foundation-sec | Default — security analysis, CVEs, threat modeling |
| primus         | Complex reasoning, multi-step attack chains        |
| nemotron-super | Deep threat modeling, architecture review          |
| qwen36         | Code review, scripting, PoC development            |

## Default Model
`foundation-sec` — switch to `primus` for complex multi-step reasoning or `nemotron-super` for deep threat modeling sessions.

## Tool Access
- **shell** — run security tools, analyze binaries, check configs (read-only by default)
- **web_search** — CVE databases, exploit-db, advisories, research papers
- **github** — audit repos, review dependencies, check commit history
- **llm_context** — inject code, logs, or configs for analysis

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
