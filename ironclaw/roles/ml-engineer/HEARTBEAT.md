# Heartbeat Checklist

## System
- [ ] Check inference services running (LiteLLM :4000, llama-embed :8010)
- [ ] Check running vLLM containers and their memory usage
- [ ] Check disk usage on HF cache partition — alert if above 85%

## Daily
- [ ] Check for vLLM upstream releases or breaking changes
- [ ] Check for new NVFP4 model quantizations on HuggingFace relevant to GB10

## Weekly
- [ ] Review tok/s and TTFT trends for active models
- [ ] Check NVIDIA developer forums for GB10-specific optimizations
- [ ] Flag any new models that fit within 128GB unified memory budget
