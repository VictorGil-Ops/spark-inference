# Development Notes (private — not synced to production)

This file is excluded from the production sync via `.prodignore`.

## Repo naming convention

This repo follows the `dev-private-<name>` pattern:
- `dev-private-*` repos are private, for development and testing
- Production repos have the same name without `dev-private-`
- Example: `dev-private-spark-inference` → `spark-inference`

## Sync to production

```bash
bash ~/repos/dev-private-spark-inference/scripts/sync-to-prod.sh
```

The script:
1. Clones this repo to a temp dir
2. Strips all `dev-private-` references from filenames and file contents
3. Removes files listed in `.prodignore`
4. Creates the production repo if it doesn't exist (public)
5. Rebases on existing commits if the production repo already has history
6. Pushes to production

To specify a custom production repo:
```bash
bash ~/repos/dev-private-spark-inference/scripts/sync-to-prod.sh VictorGil-Ops/spark-inference
```

## Files excluded from production (.prodignore)

- `scripts/sync-to-prod.sh` — internal tooling
- `DEV.md` — this file

## Development workflow

1. Make changes in `dev-private-spark-inference`
2. Test on the DGX Spark
3. Commit to dev repo
4. Run `sync-to-prod.sh` to publish clean version

## Notes

- Tokens and secrets are in `.env` files which are already in `.gitignore`
- The Telegram bot token in configs is real — don't sync accidentally
- PostgreSQL password `ironclaw` is local-only, safe to expose in docs
