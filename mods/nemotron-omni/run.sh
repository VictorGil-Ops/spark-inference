#!/bin/bash
set -e
cd $WORKSPACE_DIR

# Install audio support required for Nemotron-Omni
# Must be installed before vllm serve when using audio/video inputs
echo "Installing vllm[audio] for Nemotron-Omni..."
python3 -m pip install "vllm[audio]" --quiet

# Download the reasoning parser
echo "Downloading nemotron reasoning parser..."
wget -q https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-NVFP4/resolve/main/nano_v3_reasoning_parser.py \
    2>/dev/null || echo "Parser already present or download failed — continuing"

echo "Nemotron-Omni setup complete"