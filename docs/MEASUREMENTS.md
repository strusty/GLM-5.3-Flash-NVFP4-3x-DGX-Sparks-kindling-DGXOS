# Measurements

Three ASUS Ascent GX10 (GB10, 128 GB), DGX OS, CX7 triangle (direct cables), kindling a3c3a1d + this repo.
Kernel `6.17.0-1026-nvidia-64k`; NVIDIA open drivers 580.159.03 (two boxes) and 580.173.02 (one); dispram on all
three. sparkDash (prose / code suites, 512-token replies; prefill suite). Unless noted, values are medians of clean
runs on a warm engine.

## Method

- **Per configuration:** restart, then record graph memory and idle MemAvailable per rank. Warm up with one real
  8k-token request plus a short bench (discarded). Then prose ×2 and code ×2 at 1/4/8/12 streams, and prefill
  16k/64k ×2. Per-rank MemAvailable is sampled every 0.5 s throughout.
- **Clean runs:** each run waits for an idle server and is **repeated if any outside request overlapped it**.
  The first G1 prefill numbers (2,290–2,959 tok/s) were contaminated by live agent traffic; clean, they were 3,350–3,558.
- **Fresh vs warm:** a just-restarted engine reads 3–8% slower at 6–10 streams than one that has run for half an
  hour. Compare like with like.
- **Code variance:** code swings ±15–30% between runs at identical settings; only prose and prefill resolve small effects.

## CUDA graphs and the KV pin

| Config | Graphs per rank | Prose 1/4/8/12 | Code 1/4/8/12 | Prefill 16k / 64k | Head floor (bench) | KV tokens |
| --- | --- | --- | --- | --- | --- | --- |
| vLLM's 57 sizes, 14 GiB pin | 10.2–10.8 GiB | 66.8 / 114.7 / 147.8 / 179.3 | 113.6 / 217.3 / 247.4 / 410.2 | 3,276 / 3,473 | 3.1 GiB | 2,422,463 |
| 21 sizes, FULL_AND_PIECEWISE, 14 GiB | 3.2–4.0 GiB | 65.9 / 116.9 / 155.3 / 175.4 | 106.2 / 190.4 / 326.8 / 376.4 | 3,350–3,417 / 3,540–3,558 | 12.2 GiB | 2,422,463 |
| 21 sizes, FULL_DECODE_ONLY, 14 GiB | 1.7–2.8 GiB | 64.2 / 113.4 / 152.4 / 176.3 | 112.7 / 229.9 / 240.6 / 372.7 | 3,364 / 3,489 | 12.0 GiB | 2,422,463 |
| **21 sizes + 18 GiB pin (default)** | 3.2–4.3 GiB | 66.3 / 115.6 / 155.5 / 178.8 | 112.0 / 188.9 / 312.8 / 298.1 | 3,374 / 3,528 | **6.5 GiB** | **3,054,135** |

FULL_AND_PIECEWISE was chosen: the same floor under load as decode-only, and it keeps graphs for the mixed
prefill+decode steps agent traffic makes.

## Draft-trunc threshold (kindling's `VLLM_DRAFT_TRUNC_TAU`)

| τ | Prose 1/4/8/12 | Code 1/4/8/12 |
| --- | --- | --- |
| 0.2 | 65.9 / 113.3 / 160.2 / 176.1 | 111.2 / 201.7 / 278.5 / 333.3 |
| **0.3** | 66.3 / 115.6 / 155.5 / 178.8 | 112.0 / 188.9 / 312.8 / 298.1 |
| 0.45 | 65.0 / 111.7 / 154.8 / 172.3 | 117.1 / 188.4 / 256.5 / 371.2 |

This is already TensorFold's confidence-product draft cut (`fc7:0.3`). The noise-aware variant needs the drafter
to know the target's keyed sampling noise, which vLLM's sampler does not provide.

## Long prompts and the window

| Test | Result |
| --- | --- |
| 247,632-token cold needle (3 codes at 10/50/90%), 18 GiB pin | exact; 77.3 s (3,204 tok/s); floors head 6.18 / workers 8.92, 8.51 GiB; swap 0 |
| Same test on the old setup (vLLM graph sizes, 14 GiB pin) | exact; head floor 3.06 GiB |
| ~500k-token cold needle, window 1,048,576 | aborted by the guard at head 2.03 GiB (workers 2.9 / 3.3 GiB); afterwards the head idled at 1.94 GiB until restart |

## dispram (display carveout)

- The RM reports `DISPLAY_FRM` at `0x280200000`, 2046 MiB, on all three boxes. It lies inside the 2,616 MiB
  `reserved` hole of `/proc/iomem`; no firmware framebuffer is registered.
- In open-gpu-kernel-modules 580.159.03, 580.173.02 and 580.178.04, every scanout-carveout allocation path is
  gated on `PDB_PROP_GPU_IS_SOC_SDM` (GB20B/GB20C only), so GB10 never allocates from it. The carveout code
  (`mem_mgr_gb10b_phys.c`, `system_mem.c`, `video_mem.c`, `mem_list.c`) is identical across all three releases.
- **Fill/verify**, each box (0x5A5A5A5A, 0xA5A5A5A5, a word-unique address pattern over all 536,346,624 words,
  re-checked after 120 s of live serving): **0 wrong words**.
- **GPU-kernel bandwidth, carveout vs ordinary memory:** read 111 vs 110 GB/s, write 81 vs 82 GB/s; dependent-load
  latency 401 vs 403 ns.
- **DMA copy engines** (cuMemcpy) run at **half speed** on the carveout on the 4K kernel (59.8 vs 123 GB/s;
  coherency, page size and iommu mode ruled out). It does not matter for KV, which kernels move.
- **A/B with dispram on / off / on** (idle server): no measurable decode cost.

## The 64K kernel

- MemTotal: 121.69 → 123.79 GiB (+2.1 GiB of struct-page bookkeeping).
- Cold prefill against the same harness on the 4K kernel a day earlier: 8k 2,586 → 3,121, 16k 2,770 → 3,403,
  33k 2,732 → 3,473, 66k 2,587 → 3,509, 131k 2,926 → 3,494, 248k 2,393 → 3,135 tok/s.
- **Controlled A/B:** one worker booted 4K once while the other stayed 64K, under identical TP load.
  - GPU allocations were equal (96.6 vs 96.8 GiB).
  - On 64K: page cache +1.9 GiB, engine anonymous memory +1.1 GiB, and **≈+3.5 GiB that no kernel counter shows**.
  - A probe that allocates and frees 2 GiB of GPU memory gets back 1.64 GiB on 64K vs 2.01 GiB on 4K. The driver
    keeps about a quarter on 64K pages and reuses it for later GPU allocations, but MemAvailable can't see it.

## Quality

GSM8K and HumanEval, greedy, thinking off, 8 at a time, every output kept; HumanEval programs run in a container
with no network, read-only, uid 65534, 512 MB, 15 s (`bench/evals`).

| Set | Score | Notes |
| --- | --- | --- |
| GSM8K, full test (1,319) | **96.4%** (1,271) | median reply 76 tokens, none truncated. All 48 misses are wrong reasoning (no parsing losses); thinking on fixes 16 (low effort) or 21 (high effort) of them |
| GSM8K, first 250 | 97.2% (243) | |
| HumanEval (164) | **94.5%** (155) | 9 logic failures. Two earlier "failures" were a harness bug (the prompt's helper functions dropped); fixed in `run_evals.py` |

Batched serving is not bit-deterministic at temperature 0: HumanEval moved by 2 problems between identical runs.

## Tool calls

Over two days of real agent traffic, 5 of 5,094 GLM tool calls carried tool-call markup inside an argument (4
opened inside the reasoning, 1 abandoned mid-argument). Upstream's parser executed all five. `glm47_repair`
refuses them with the recovered call spelled out.
