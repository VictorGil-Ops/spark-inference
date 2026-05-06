# DGX Spark Benchmarks

Hardware: NVIDIA GB10 (SM12.1, Blackwell) | 128GB unified | CUDA 13.2
Test: 500 completion tokens | single user | vLLM via eugr/spark-vllm-docker

## Multi-model stack (3 models simultaneous, ~116GB total)

| Model | tok/s | RAM | Mode | Port |
|-------|-------|-----|------|------|
| Nemotron-3-Nano-30B NVFP4 | 41.5 | ~32GB | Eager | 8000 |
| Qwen3.6-35B-A3B FP8 | 28.6 | ~45GB | Eager | 8001 |
| Llama-Primus-Reasoning 8B | 14.4 | ~35GB | Eager | 8002 |
| Foundation-Sec-8B-Instruct | 14.5 | ~35GB | Eager | 8002 |

## Single model (CUDA graphs enabled)

| Model | tok/s | RAM | Mode | Port |
|-------|-------|-----|------|------|
| Nemotron-3-Nano-30B NVFP4 | 58.6 | ~32GB | CUDA graphs | 8000 |
| Nemotron-3-Nano-30B NVFP4 | 10.9 | ~32GB | Eager (no graphs) | 8000 |

## Notes

- CUDA graphs give **5.4x speedup** on Nemotron (58.6 vs 10.9 tok/s)
- Running 3 models simultaneously requires eager mode (CUDA graphs need ~130GB+)
- 8B security models (Llama-Primus, Foundation-Sec) cap at ~14 tok/s in eager
- gpu_memory_utilization tuning is critical — default reserves 117GB for a 19GB model
  See: https://forums.developer.nvidia.com/t/364886
