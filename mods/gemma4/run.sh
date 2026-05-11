#!/bin/bash
set -e
cd $WORKSPACE_DIR

# Copy custom chat template to workspace root for vLLM to find via --chat-template
cp /workspace/mods/gemma4/gemma4.jinja $PWD/gemma4.jinja

echo "Gemma-4 mod applied"
