#!/bin/bash
set -e
VLLM_TEMPLATES="/usr/local/lib/python3.12/dist-packages/vllm/transformers_utils/chat_templates"
cp qwen3.5-enhanced.jinja "$VLLM_TEMPLATES/qwen3.5-enhanced.jinja"
cp qwen3.6-enhanced.jinja "$VLLM_TEMPLATES/qwen3.6-enhanced.jinja" 2>/dev/null || true
echo "=======> chat templates installed to $VLLM_TEMPLATES/"
