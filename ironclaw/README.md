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

## Auto-install
```bash
bash ironclaw/setup.sh
# Or directly:
bash ironclaw/install.sh <telegram_token> <user_id> [db_user] [db_pass] [model] [hf_model]
```
The installer seeds `.env`, workspace `.md` files, DB settings (tools, embedding, thinking), and imports memories via `ironclaw memory write`.

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
- Only one ironclaw instance can run (PID lock at `~/.ironclaw/ironclaw.pid`).
- Workspace `.md` files (SOUL.md, USER.md, AGENTS.md, IDENTITY.md) are the source of truth — imported into memory via `ironclaw memory write`.
- Use `bash ironclaw/reset-ironclaw.sh` to recover from stuck jobs, stale PID, or port conflicts.
- DB settings control tools (local tools, sandbox), embeddings (pgvector, hybrid), and thinking (auto mode).

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