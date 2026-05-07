#!/bin/bash
# sync-to-prod.sh
# Syncs dev-private repo to production, stripping all dev-private references.
#
# Scenarios handled:
#   1. Prod repo doesn't exist → creates it (public by default)
#   2. Prod repo exists on GitHub but not locally → clones, merges, pushes
#   3. Prod repo exists and is up to date → fast-forward push
#
# Usage:
#   ./scripts/sync-to-prod.sh                    # auto-detect prod repo name
#   ./scripts/sync-to-prod.sh my-org/prod-repo   # explicit target

set -e

# ── Config ────────────────────────────────────────────────────────────────────
DEV_REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || \
           git remote get-url origin | sed 's|.*github.com[:/]||;s|\.git$||')
PROD_REPO="${1:-$(echo "$DEV_REPO" | sed 's|dev-private-||')}"
WORK_DIR="/tmp/sync-prod-$$"

echo "=== sync-to-prod ==="
echo "Source (dev):  ${DEV_REPO}"
echo "Target (prod): ${PROD_REPO}"
echo ""

# ── Confirm ───────────────────────────────────────────────────────────────────
read -p "Continue? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ── Clone dev repo to temp dir ────────────────────────────────────────────────
echo "--- Cloning dev repo ---"
gh repo clone "$DEV_REPO" "$WORK_DIR"
cd "$WORK_DIR"

# ── Apply .prodignore ────────────────────────────────────────────────────────
if [ -f .prodignore ]; then
    echo "--- Applying .prodignore ---"
    grep -v "^#" .prodignore | grep -v "^$" | while read f; do
        echo "  Removing: $f"
        rm -f "$f"
    done
fi

# ── Strip dev-private references ─────────────────────────────────────────────
echo "--- Stripping dev-private references ---"

# 1. Rename files containing dev-private in the name
find . -name "*dev-private*" -not -path "./.git/*" | while read f; do
    newname=$(echo "$f" | sed 's|dev-private-||g')
    echo "  Renaming: $f → $newname"
    mkdir -p "$(dirname "$newname")"
    mv "$f" "$newname"
done

# 2. Replace dev-private references inside file contents
find . -type f -not -path "./.git/*" \
    \( -name "*.md" -o -name "*.sh" -o -name "*.yaml" -o -name "*.yml" \
       -o -name "*.json" -o -name "*.toml" -o -name "*.txt" -o -name "*.py" \
       -o -name "*.rs" -o -name "*.js" -o -name "*.ts" \) | \
while read f; do
    if grep -q "dev-private" "$f" 2>/dev/null; then
        echo "  Processing: $f"
        sed -i 's|dev-private-||g' "$f"
    fi
done

# ── Commit the stripped working tree ─────────────────────────────────────────
git config user.email "sync@local" && git config user.name "sync-to-prod"
git add -A
git diff --cached --quiet || git commit -m "chore: strip dev-private references for production"

# ── Check if prod repo exists on GitHub ──────────────────────────────────────
echo "--- Checking production repo ---"
git remote remove origin 2>/dev/null || true

if gh repo view "$PROD_REPO" > /dev/null 2>&1; then
    echo "  Prod repo exists — force-pushing (dev is source of truth)..."
    git remote add origin "https://github.com/${PROD_REPO}.git"
    git push origin master --force
else
    echo "  Prod repo does not exist — creating..."
    DESCRIPTION=$(gh repo view "$DEV_REPO" --json description -q .description 2>/dev/null || echo "")
    gh repo create "$PROD_REPO" \
        --public \
        --description "$DESCRIPTION" \
        --source=. \
        --remote=origin \
        --push
    echo "  Created and pushed: https://github.com/${PROD_REPO}"
fi

# ── Cleanup ───────────────────────────────────────────────────────────────────
cd ~
rm -rf "$WORK_DIR"

echo ""
echo "=== Done ==="
echo "Production repo: https://github.com/${PROD_REPO}"
