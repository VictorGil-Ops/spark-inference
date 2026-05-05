# mod: nemotron-nano

Downloads the custom reasoning parser for Nemotron3-Nano from HuggingFace.

## What it does
Installs `nano_v3_reasoning_parser.py` in the container workspace.
Without this parser, `<think>...</think>` content appears mixed with
the response in clients (OpenClaw, Hermes, OpenWebUI).

## Source
https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-NVFP4
