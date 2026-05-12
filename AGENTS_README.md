# IronClaw Agent System

IronClaw is a local AI agent that runs persistently on your DGX Spark. It connects via Telegram and CLI, uses LiteLLM to route requests to local models, and maintains long-term memory using pgvector + semantic embeddings.

---

## Architecture

```
Telegram / CLI
      ↓
  IronClaw daemon
      ↓
  LiteLLM proxy (port 4000)
      ↓
  vLLM model container (port 8000–8200)
      ↓
  DGX Spark GB10 (128GB unified memory)

  llama.cpp embedding server (port 8010)
  PostgreSQL + pgvector (port 5432)
```

---

## Roles

The agent uses a role system to adapt its identity, behaviour, and default model to different use cases. Each role provides a set of `.md` files that define the agent's personality, tools, and background tasks.

Roles are stored in `ironclaw/roles/`. Switch roles at any time:

```bash
./ironclaw/setup.sh role
```

---

### Personal Assistant
**Default model:** `gemma-4` (fast, multimodal, handles Telegram images)

The general-purpose role. Designed for day-to-day tasks: reminders, notes, news summaries, system monitoring, and Telegram message management. Responds in the user's language. Keeps responses short and direct.

**Heartbeat tasks:** disk usage, service health, pending reminders, unread messages.

**Fallback model:** `nemotron-omni` for tasks requiring deeper reasoning.

---

### Software Developer
**Default model:** `qwen36` (196K context, CUDA graphs, `qwen3_coder` parser)

Coding-focused role. Writes, reviews, debugs, and architects software. Has access to shell and GitHub. Leads with code, follows with explanation. Direct about code quality — doesn't soften criticism.

**Heartbeat tasks:** open PRs, failing CI, TODO/FIXME tracking, dependency advisories.

**Heavy model:** `qwen3.5-122b` for large codebases or long refactor sessions.
**Architecture model:** `nemotron-super` for complex design decisions.

---

### AI/ML Engineer
**Default model:** `nemotron-super` (native reasoning, architecture analysis)

Infrastructure and experimentation role. Helps select, optimize, serve, and experiment with local LLMs. Understands the full stack: quantization formats (NVFP4, FP8, INT4, AWQ, GGUF), vLLM flags, LiteLLM routing, and Blackwell hardware constraints. Leads with benchmarks, not opinions.

**Key paths known to the agent:**
- Recipes: `recipes/`
- Mods: `mods/`
- HF cache: `~/.cache/huggingface/hub/`
- LiteLLM config: `~/.litellm/litellm_config.yaml`

**Heartbeat tasks:** vLLM upstream releases, new NVFP4 quantizations on HuggingFace, GB10 forum updates.

---

### Security Researcher
**Default model:** `foundation-sec` (purpose-built for security tasks)

Security analysis role. Threat modeling, vulnerability analysis, code review, CTF, and security research. Thinks adversarially. Always asks "how would an attacker approach this?" Flags findings by severity (Critical/High/Medium/Low/Info).

**Boundaries:** never performs active attacks without explicit authorization. Always clarifies scope before starting an assessment.

**Heartbeat tasks:** NVD/CVE feed, auth log anomalies, open ports, dependency audits.

**Reasoning model:** `primus` for complex multi-step attack chains.
**Deep analysis model:** `nemotron-super` for threat modeling sessions.

---

### Researcher
**Default model:** `nemotron-super` (deep reasoning, synthesis)

Research and analysis role. Finds, reads, synthesizes, and critically evaluates information. Handles long documents, papers, and multi-source research tasks. Always cites sources. Flags uncertainty explicitly — never presents speculation as fact.

**Long-context model:** `qwen3.5-122b` for full paper ingestion (196K context).
**Vision model:** `gemma-4` for image-heavy papers and diagrams.

**Heartbeat tasks:** arxiv daily (cs.AI, cs.LG, cs.CL), new datasets, contradictions in previously reviewed findings.

---

## Memory System

IronClaw uses a hybrid memory system:

- **Full-text search** — fast exact keyword matching
- **Semantic search** — powered by `nomic-embed-text-v1.5` running on llama.cpp at `localhost:8010` (768 dimensions, 2048 token context)
- **Storage** — PostgreSQL + pgvector

Memory is stored per-user and persists across sessions. The agent can read, write, and search its own memory using built-in tools.

```bash
# Search memory
ironclaw memory search "your query"

# Read a file
ironclaw memory read USER.md

# Show workspace tree
ironclaw memory tree

# Show status
ironclaw memory status
```

---

## Workspace Files

The workspace defines the agent's identity and context. Files are stored in `~/.ironclaw/workspace/` and imported into memory at install/reset time.

| File | Purpose |
|------|---------|
| `IDENTITY.md` | Agent name, vibe, role |
| `SOUL.md` | Core values, behaviour rules, language |
| `USER.md` | User profile — name, location, preferences |
| `AGENTS.md` | Model roster, tool access, infrastructure |
| `HEARTBEAT.md` | Background tasks run periodically |
| `MEMORY.md` | Long-term memory summary |

**Important:** editing these files on disk does not automatically update the agent. After editing, reimport:

```bash
ironclaw memory write USER.md "$(cat ~/.ironclaw/workspace/USER.md)"
systemctl --user restart ironclaw
```

Or run a full reset which reimports everything:

```bash
bash ~/repos/dev-private-spark-inference/ironclaw/reset-ironclaw.sh
```

---

## Model Selection Per Role

| Role | Default | Heavy | Fast |
|------|---------|-------|------|
| Personal Assistant | gemma-4 | nemotron-omni | nemotron-nano |
| Software Developer | qwen36 | qwen3.5-122b | gemma-4 |
| AI/ML Engineer | nemotron-super | qwen3.5-122b | qwen36 |
| Security Researcher | foundation-sec | nemotron-super | qwen36 |
| Researcher | nemotron-super | qwen3.5-122b | qwen36 |

> **Note:** switching roles in `setup.sh` only changes which model IronClaw sends requests to. It does not load or unload models from GB10 unified memory. Use **[2] Models** or **[5] Switch Mode** from the main menu to manage loaded models.

---

## Switching Roles

```bash
# Interactive menu
./ironclaw/setup.sh role

# Or from the main spark.sh menu → [6] IronClaw Setup → Switch agent role
```

When switching roles with a different model currently active, the agent will warn you and offer three options:
1. Switch IronClaw to the recommended model
2. Keep the current model (IronClaw will use it regardless of the role recommendation)
3. Cancel

---

## Installation

```bash
./ironclaw/setup.sh
# Select [1] Fresh install
# Follow the onboarding questionnaire to set agent name, user profile, and role
```

The onboarding questionnaire asks:
- Agent name
- Your name and location
- Role selection (sets workspace .md files and default model)
- Preferred language

---

## Resetting

If the agent behaves incorrectly, run a reset to restore a clean state:

```bash
bash ~/repos/dev-private-spark-inference/ironclaw/reset-ironclaw.sh
```

This fixes stale PIDs, stuck jobs, PostgreSQL SSL issues, LiteLLM connectivity, Telegram polling, and reimports all workspace files into memory.
