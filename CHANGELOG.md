# Benchmarks

## update 2016-05-08
Prompt: 500 tokens, transformer explanation

| Date | Model | tok/s | RAM | Mode |
|------|-------|-------|-----|------|
| 2026-05-08 00:00 | nvidia/Nemotron-3-Nano-Omni-30B-A3B-Reasoning-NVFP4 | 37.8 | ~32GB | Eager |
| 2026-05-08 02:56 | AEON-7/Nemotron-3-Nano-Omni-AEON-Ultimate-Uncensored-NVFP4 | 72.0 | ~32GB | CUDA graphs |
| 2026-05-08 10:17 | nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-NVFP4 | 62.2 | ~32GB | CUDA graphs |
| 2026-05-08 12:06 | nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-NVFP4 | 56.2 | ~32GB | Eager |
| 2026-05-08 13:02 | cybermotaz/nemotron3-nano-nvfp4-w4a16 | 43.4 | ~18GB | Eager |
| 2026-05-08 13:18 | Qwen/Qwen3.6-35B-A3B-FP8 | 53.7 | ~64GB | CUDA graphs |
| 2026-05-08 13:34 | Qwen/Qwen3.6-35B-A3B-FP8 | 33.5 | ~64GB | Eager |
| 2026-05-08 14:07 | nvidia/NVIDIA-Nemotron-3-Super-120B-A12B-NVFP4 | 15.6 | ~91GB | CUDA graphs |
| 2026-05-08 16:19 | nvidia/Gemma-4-26B-A4B-NVFP4 | 29.9 | ~117GB | CUDA graphs |