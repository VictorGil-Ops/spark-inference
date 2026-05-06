#!/bin/bash
# setup-local.sh — Configure this clone for local use only.
# Run once after cloning. Prevents accidental pushes to the upstream repo.

set -e

BOLD='\033[1m'
GREEN='\033[32m'
CYAN='\033[36m'
RESET='\033[0m'

echo ""
printf "${BOLD}DGX Spark — Local Setup${RESET}\n"
echo ""

# 1. Disable push to origin
git remote set-url --push origin DISABLED
printf "  ${GREEN}✓${RESET} Push to origin disabled (pull still works)\n"

# 2. Point git to the hooks/ directory in this repo
git config core.hooksPath hooks
chmod +x hooks/pre-push
printf "  ${GREEN}✓${RESET} Pre-push hook installed (hooks/pre-push)\n"

echo ""
printf "  ${CYAN}→${RESET} You can now modify recipes and scripts freely.\n"
printf "  ${CYAN}→${RESET} To push changes, add your own remote:\n"
printf "      git remote add myfork https://github.com/<your-user>/<repo>.git\n"
printf "      git push myfork main\n"
echo ""
