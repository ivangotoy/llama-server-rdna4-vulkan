# llama-server vs vLLM on AMD RX 9070 XT (RDNA4)

Benchmark comparing llama-server (Vulkan backend) vs vLLM (ROCm 7.2) on AMD Radeon RX 9070 XT (gfx1201 / RDNA4 architecture).

**TL;DR:** llama-server Vulkan delivers 62 t/s vs vLLM ROCm 48 t/s on the same hardware — 29% faster — due to missing native RDNA4 kernel support in vLLM at time of testing.

---

## Hardware & Software

| Component | Details |
|---|---|
| GPU | AMD Radeon RX 9070 XT (gfx1201 / RDNA4) |
| Vulkan | 1.4.341.0 |
| Mesa | mesa-git 26.1.0_devel.219852.59fc5ae7c1b-1 (RADV) |
| ROCm | 7.2.0 |
| OS | CachyOS (Arch-based) |

---

## Model

| Backend | Model |
|---|---|
| llama-server | `Qwen3.5-9B-UD-Q6_K_XL.gguf` |
| vLLM | `Qwen3.5-9B-FP8` |

Note: llama-server runs GGUF Q6_K quantization via Vulkan. vLLM runs FP8 quantization via ROCm — theoretically the more optimized path for AI accelerators.

---

## Launch Flags

### llama-server (Vulkan)
```bash
llama-server \
  --model ~/models/qwen35-9b/Qwen3.5-9B-UD-Q6_K_XL.gguf \
  --alias "qwen3" \
  --n-gpu-layers 999 \
  -c 65536 \
  --batch-size 2048 \
  --ubatch-size 2048 \
  --parallel 1 \
  --prio 2 \
  --host 0.0.0.0 \
  --port 8081 \
  --reasoning-budget 0 \
  --presence-penalty 1.5 \
  --metrics \
  --cache-reuse 256
```

### vLLM (ROCm 7.2)
```bash
vllm serve ~/models/Qwen3.5-9B-FP8 \
  --served-model-name qwen3 \
  --max-model-len 32768 \
  --max-num-batched-tokens 8192 \
  --max-num-seqs 1 \
  --gpu-memory-utilization 0.90 \
  --kv-cache-dtype fp8_e4m3 \
  --enable-prefix-caching \
  --language-model-only \
  --reasoning-parser qwen3 \
  --default-chat-template-kwargs '{"enable_thinking": false}' \
  --port 8081 \
  --host 0.0.0.0
```

---

## Benchmark Methodology

Benchmark script: [`llm-bench.sh`](llm-bench.sh)

- **Runs:** 10 measured + 2 warmup (warmup discarded)
- **Max tokens:** 512
- **Temperature:** 0
- **Seed:** 42
- **Prompt:** Technical Linux kernel memory management question (consistent across both backends)
- **Metric:** tokens/second (completion tokens / elapsed time)

---

## Results

| Backend | Avg t/s | Notes |
|---|---|---|
| llama-server (Vulkan) | **62 t/s** | GGUF Q6_K, Vulkan backend |
| vLLM (ROCm 7.2) | **48 t/s** | FP8, ROCm — missing gfx1201 kernel support |

**llama-server Vulkan is 29% faster on this hardware.**

---

## Root Cause

vLLM on RDNA4 (gfx1201) silently falls back to FP32 dequantization for all FP8 operations — completely bypassing the hardware's 128 AI accelerators. This happens because gfx1201 is not yet in vLLM's platform detection, so it never follows the optimized FP8 Triton kernel path.

The community workaround requires patching `vllm/platforms/rocm.py` to add gfx1201 to the `on_mi3xx()` detection and providing RDNA4-specific FP8 kernel config files.

Open upstream issue: [vllm-project/vllm#28649](https://github.com/vllm-project/vllm/issues/28649)

---

## Conclusion

If you just bought an RX 9070 XT and your vLLM inference feels underperforming — it's not your hardware, it's the backend. Until RDNA4 support lands in vLLM mainline, llama-server with Vulkan is the better choice for local inference on this GPU.

ROCm/vLLM will catch up. The community is actively working on it.

---

## Related

- [vLLM RDNA4 FP8 upstream issue](https://github.com/vllm-project/vllm/issues/28649)
- [llama.cpp](https://github.com/ggml-org/llama.cpp)
- Live homelab AI stack: [digtvbg.com](https://digtvbg.com)
