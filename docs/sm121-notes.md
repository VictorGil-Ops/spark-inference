# SM12.1 (GB10) Compatibility Notes

## Architecture
- GPU: NVIDIA GB10, Blackwell, SM12.1
- 128GB unified CPU+GPU memory
- aarch64 (ARM Grace CPU)

## Working Configuration
- CUDA: 13.2
- PyTorch: 2.11.0+cu130
- vLLM: main branch (eugr prebuilt wheels)
- FlashInfer: 0.6.9
- Triton: 3.6.0

## Critical Environment Variables
| Variable | Value | Reason |
|----------|-------|--------|
| VLLM_ATTENTION_BACKEND | FLASHINFER | FlashAttn doesn't support SM12.1 |
| VLLM_FLASHINFER_MOE_BACKEND | latency | throughput backend crashes (SM120 kernel bug) |
| VLLM_USE_V1 | 1 | Required for CUDA graphs |
| VLLM_CUDA_GRAPH_MODE | full_and_piecewise | Max performance |

## CUDA Graph Activation
Add to recipe command:
--compilation-config '{"cudagraph_capture_sizes":[1,2,4,8,16,32,64,128,256]}'
--max-num-seqs 256
Without this: ~10 tok/s. With this: ~58 tok/s (5.4x).

## Known Limitations
- CUTLASS FP4 kernels unstable on SM12.1 → falls back to Marlin
- FlashMLA not compiled for SM12.1 
- TurboQuant KV compression (PR #38479) not merged yet
- NVFP4 native kernels not available → use --moe-backend cutlass

## Benchmark Results
| Model | Backend | tok/s | RAM |
|-------|---------|-------|-----|
| Nemotron-3-Nano-30B NVFP4 | CUDA graphs | 58.6 | ~50GB |
| Nemotron-3-Nano-30B NVFP4 | eager | 10.9 | ~50GB |
