# IronClaw Setup for DGX Spark

## Prerequisites
- PostgreSQL 15+ with pgvector
- Rust 1.85+
- vLLM running on port 8000

## Install
```bash
git clone https://github.com/nearai/ironclaw.git
cd ironclaw && cargo build --release && cargo install --path .
```

## Database
```bash
sudo -u postgres psql -c "CREATE USER \"$(whoami)\" WITH SUPERUSER;"
sudo -u postgres createdb ironclaw -O "$(whoami)"
psql ironclaw -c "CREATE EXTENSION IF NOT EXISTS vector;"
```

## Configure
```bash
ironclaw onboard
# Select: PostgreSQL, OpenAI-compatible, vLLM local
# DB URL: postgres://USER:PASS@localhost:5432/ironclaw?sslmode=disable
# LLM URL: http://127.0.0.1:8000/v1
# Model: nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-NVFP4
```

## Fix DB settings after onboard
```bash
psql "postgres://USER:PASS@localhost:5432/ironclaw?sslmode=disable" -c "
UPDATE settings SET value = '\"openai_compatible\"' WHERE key = 'llm_backend';
UPDATE settings SET value = '\"http://127.0.0.1:8000/v1\"' WHERE key = 'llm_base_url';
INSERT INTO settings (user_id, key, value) VALUES ('default', 'activated_channels', '[\"telegram\"]')
  ON CONFLICT (user_id, key) DO UPDATE SET value = '[\"telegram\"]';
"
```

## Service file
Copy `ironclaw.service` to `~/.config/systemd/user/` and set your values:
```bash
cp ironclaw.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now ironclaw
```

## Telegram pairing
After first start, approve the pairing code that the bot sends you:
```bash
ironclaw pairing approve telegram CODE
```

## Gotchas
- After `onboard`, the DB may have `llm_backend = "nearai"` — override it manually (see above).
- `channels.cli_mode` defaults to `"tui"` in the DB — set `CLI_MODE=plain` in the service to enable log output.
- `activated_channels` must be set in the DB for WASM channels to load at startup.
- Only one ironclaw instance can run (PID lock at `~/.ironclaw/ironclaw.pid`).

## Benchmarks
| Query | Response time |
|-------|--------------|
| Simple greeting | ~5s |
| Complex explanation (2 phases) | ~14s |


## Troubelshooting
Fix limit context

`Error: LLM error: Context length exceeded: 32768 tokens used, 400 allowed`

```bash
psql "postgres://user:passwd@localhost:5432/ironclaw?sslmode=disable" << 'SQL'
UPDATE settings SET value = '28000' WHERE key = 'skills.max_context_tokens';
UPDATE settings SET value = '28000' WHERE key = 'routines.max_lightweight_tokens';
UPDATE settings SET value = '100000' WHERE key = 'safety.max_output_length';
SELECT key, value FROM settings WHERE key LIKE '%token%' OR key LIKE '%context%' OR key LIKE '%output%';
SQL
```
```bash
systemctl --user restart ironclaw
```