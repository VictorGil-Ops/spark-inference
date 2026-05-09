# Agents

## Sparky
The primary agent. Personal assistant running on sparky-one.
- Handles day-to-day tasks, questions, and automation via Telegram.
- Has full access to tools: web search, GitHub, Telegram MTProto, LLM context.
- Default model: set via LiteLLM (see `selected_model` in DB).
- Acts cautiously on external actions, autonomously on internal ones.

## Model Roster
Models available through LiteLLM on port 4000:

| Alias           | Model                                      | Backend | Port  |
|-----------------|--------------------------------------------|---------|-------|
| nemotron-nano   | NVIDIA-Nemotron-3-Nano-30B-A3B-NVFP4       | vLLM    | 8000  |
| nemotron-omni   | Nemotron-3-Nano-Omni-30B-A3B-Reasoning     | vLLM    | 8000  |
| qwen36          | Qwen3.6-35B-A3B-FP8                        | vLLM    | 8001  |
| foundation-sec  | Foundation-Sec-8B-Instruct                 | vLLM    | 8002  |
| primus          | Llama-Primus-Reasoning                     | vLLM    | 8002  |
| nemotron-super  | NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4    | vLLM    | 8100  |
| nemotron-nano-w4| nemotron3-nano-nvfp4-w4a16                 | vLLM    | 8004  |
| gemma-4         | Gemma-4-26B-A4B-NVFP4                      | vLLM    | 8200  |

## Switching Models
Use the setup wizard:
```bash
~/repos/spark-inference/ironclaw/setup.sh model
```

## Tool Access
- **web_search** — general search
- **github** — repo access and operations
- **telegram_mtproto** — read Telegram messages and chats
- **llm_context** — inject context into LLM calls