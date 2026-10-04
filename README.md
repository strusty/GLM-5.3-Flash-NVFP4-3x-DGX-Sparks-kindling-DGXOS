<h1 align="center">GLM-5.3-Flash NVFP4 on three DGX Sparks, stock DGX OS</h1>

<p align="center">
  <sub>by Stuart Trusty and his buddy Claude · built on <a href="https://github.com/kindlingai/glm-5.3-flash-gx10">kindling</a></sub>
</p>

Serve **GLM-5.3-Flash** from three NVIDIA DGX Sparks / ASUS Ascent GX10 (GB10, 128 GB each), cabled as a
triangle on their ConnectX-7 ports with no switch, through an OpenAI-compatible API. It runs
[kindling](https://github.com/kindlingai/glm-5.3-flash-gx10) (vLLM, NVFP4, DFlash2, ARX, mentat) at TP=3, **on the
stock DGX OS that ships on the box**. You get the memory gains of kindling's custom OS without installing it, plus
TP=3 tunings measured over a weekend of agent traffic.

**Why use it:** a workhorse that runs cool. There is no practical cap on the number of working threads, and
prefill feels almost instant.

- **~3,100–3,500 tok/s cold prefill.** A 64k-token prompt is ready in 20 s; resending it takes 0.41 s.
- **No 8-request cap.** vLLM schedules up to 64 sequences. The FP8 KV pool holds **3,054,135 tokens**, which is
  **11.65 full 262k-token conversations** at once (or ~45 at 66k). Bursts of 12–15 concurrent agents run without queuing.
- **Runs cool.** The NVFP4 tensor-core path keeps a GB10 out of thermal clamps that EXL3 trellis decode hits
  (head clamps ~0.6/h against ~21/h on an EXL3 engine on the same boxes).
- **Same intelligence.** GSM8K 96.4% on all 1,319 problems with thinking off (an estimated ~97.6–98% with thinking on), HumanEval 94.5%.
- **Agent-safe tool calls.** Nested or abandoned GLM tool calls are refused with a recovery hint instead of
  executed, and long buffered calls send keep-alives.
- Checkpoint: [`nvidia/GLM-5.3-Flash-NVFP4`](https://huggingface.co/nvidia/GLM-5.3-Flash-NVFP4)
  (zero-padded for TP=3 by kindling's `experimental/tp3/make_padded.py`).
  Drafter: [`incoai/GLM-5.3-Flash-DFlash2`](https://huggingface.co/incoai/GLM-5.3-Flash-DFlash2).
- Context: **262,144 tokens** per request (a longer window starts but isn't memory-safe on this configuration;
  see [Limits](#limits)).

## Performance

Measured with [sparkDash](https://github.com/MiaAI-Lab/sparkDash) (the same tool other GB10 recipes publish with) on
a warm engine. Every run waited for an idle server and was repeated if live traffic overlapped it. Three ASUS GX10,
DGX OS, kernel `6.17.0-1026-nvidia-64k`, drivers 580.159.03 / 580.173.02, CX7 triangle. Full tables and method:
[docs/MEASUREMENTS.md](docs/MEASUREMENTS.md).

**Decode, aggregate tok/s (512-token replies)**

| Concurrent requests | 1 | 4 | 8 | 12 |
| --- | ---: | ---: | ---: | ---: |
| Prose | 66.3 | 115.6 | 155.5 | 178.8 |
| Code | 106–118 | 189–230 | 267–327 | 298–376 |

Code swings ±15–30% from run to run at the same settings (DFlash2 acceptance on code is bursty), so ranges are given.

**Prefill (cold) and time to first token**

| Prompt | Prefill | Time to first token |
| ---: | ---: | ---: |
| 8k | 3,121 tok/s | — |
| 16k | 3,374–3,417 tok/s | — |
| 64k | 3,528–3,558 tok/s | 20.0 s |
| 131k | 3,494 tok/s | — |
| 248k | 3,135–3,204 tok/s | 77 s |

| Resume | Time to first token |
| --- | ---: |
| The same 64k prompt sent again | 0.41 s |
| A new conversation with the same ~8k system prompt | 0.28 s (cold: 3.10 s) |
| An agent's next turn (previous prompt + reply + ~800 new tokens) at 26k / 79k / 157k | 0.60 / 0.94 / 1.08 s |

**Memory** (the head, rank 0, is the tightest box). Lowest free memory with a 248k-token cold prompt: **6.2 GiB**
on the head, 8.5–8.9 GiB on the workers. Under a 12-stream bench: 6.5 GiB.

**Quality** (greedy, thinking off, every output kept): GSM8K **96.4%** on the full 1,319-problem test set (97.2%
on the first 250). All 48 misses were genuine reasoning slips in short answers; asked again with thinking on, 16–21
of them come right (~97.6–98.0%). HumanEval **94.5%** (155/164). See [docs/MEASUREMENTS.md](docs/MEASUREMENTS.md#quality).

## Why this instead of kindling-spark-os or Mia's TensorFold recipe

**Compared with [kindling-spark-os](https://github.com/kindlingai/kindling-spark-os)** (kindling's own minimal OS):
it is an excellent piece of work, and two of its ideas are why this repo exists. It boots a read-only image in place
of DGX OS to get ~4 GB more memory per box: a 64 KiB-page kernel and *dispram* (lending the GPU's unused 2 GiB
display carveout to the KV cache). Both work on stock DGX OS:

- **dispram** is userspace. This repo fetches kindling-spark-os's dispram unmodified and builds its RM library
  against *your* driver's exact headers (the RM API headers are byte-identical across 580.159.03 / 580.173.02 /
  580.178.04). 2046 MiB per box passed a full fill/verify (0 wrong words), and GPU kernels read and write it at the
  same speed as ordinary memory. **+2 GiB of KV per rank.**
- **The 64K kernel** is Ubuntu's own Canonical-signed `nvidia-64k` flavour, with matching NVIDIA module builds for
  both drivers, already in DGX OS's apt. `dgxos/k64` switches each box behind a safety net: the saved default
  stays on the old kernel until confirmed, a one-shot trial boot reverts by itself unless confirmed over SSH,
  plus a hardware watchdog during the trial and `panic=10`. On these boxes it bought **~19–36% faster cold
  prefill**. Its RAM gain was mostly eaten by the NVIDIA driver retaining freed GPU memory on 64K pages (see [Limits](#limits)).
- **The bigger memory win needs no OS change at all:** capturing CUDA graphs at **21 batch sizes instead of
  vLLM's 57** frees **~7 GiB per rank** at equal speed. Half of that went to a bigger KV pin (14 → 18 GiB); the
  rest doubled the head's headroom.

You keep DGX OS, NVIDIA's dashboard and support path, and anything else you run on the boxes.

**Compared with [Mia's TensorFold recipe](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold)**
(v1.5, three Sparks, experimental). Her numbers are from her README; both sides are sparkDash.

| | This repo | Mia v1.5, three Sparks |
| --- | --- | --- |
| Cold prefill 8k / 64k / 262k | **3,121 / ~3,540 / ~3,150** tok/s | 2,001 / 2,004 / 1,655 tok/s |
| Code, 6–8 requests | **~230–327** tok/s | 193–212 tok/s |
| Requests at once | **up to 64** (pool 3.05M) | 8 (pool 4.0–4.2M) |
| Prose, 1 request | 66 | **77.6** (4-stream mode) / 65.7 (8-stream default) |
| Prose, 8 requests | 155 | **166** |
| Window | 262k | **1M** |
| Resume (identical 64k / shared system prompt) | 0.41 / 0.28 s | **<0.07 / 0.13 s** |
| Head free memory under load | 6.2–6.5 GiB | **11.5–12.5 GiB** |
| GSM8K / HumanEval (thinking off) | 96.4% (full set) / 94.5% | 98.8% (first 250) / 95.7% |
| Heat | cool (NVFP4 tensor cores) | EXL3 trellis decode runs hot |

Her recipe is the better pick for a few long-context conversations (1M window, instant resume, best single-stream
prose). This one is the better pick for many agents at once: tool-heavy turns over big contexts, where the
prompt, not the reply, dominates the wait.

## Requirements

- Three GB10 boxes (DGX Spark or ASUS Ascent GX10) on DGX OS (Ubuntu 24.04), NVIDIA's open driver from DGX OS apt
  (580.159.03 and 580.173.02 tested), Docker, passwordless sudo for the admin user, ssh between the boxes.
- Each box cabled to the other two on its ConnectX-7 ports (a triangle; no switch), addressed per kindling's
  `experimental/tp3` README.
- kindling's prerequisites on every box: its image built, [mentat](https://github.com/mmastrac/mentat) running, and
  the TP=3 padded checkpoints (~180 GB) plus room for one ~69 GB weight snapshot per box.

## Quick start

On the **head** (the box that serves the API):

    git clone https://github.com/strusty/GLM-5.3-Flash-NVFP4-3x-DGX-Sparks-kindling-DGXOS.git && cd GLM-5.3-Flash-NVFP4-3x-DGX-Sparks-kindling-DGXOS
    cat > scripts/local.sh <<'X'
    WORKER1=admin@box2      # ssh targets of the other two boxes (LAN)
    WORKER2=admin@box3
    X
    ./scripts/install.sh    # kindling @ a3c3a1d + patches + overlay + parser + settings, on all three boxes

Optional, recommended: **dispram** (+2 GiB KV per rank). On every box, then verify with the engine stopped:

    ./dgxos/dispram/install-dispram.sh && python3 dgxos/dispram/verify.py

Optional: **the 64K kernel** (faster prefill). One box at a time, engine stopped, ideally with physical access the
first time ([dgxos/k64/README.md](dgxos/k64/README.md)):

    dgxos/k64/prepare.sh   # no reboot: safety net + 64K packages; the default stays on today's kernel
    dgxos/k64/arm.sh && sudo systemctl reboot    # one-shot trial; reverts by itself in 15 min unless confirmed
    dgxos/k64/verify.sh && dgxos/k64/confirm.sh  # after it is back: ~29 checks, then make 64K the default

Start, and prove it:

    ./scripts/start.sh      # all ranks down, up head-first, ARX ring order check, /health, one real generation
    (cd ~/glm53-kindling && bash smoketest/run.sh http://127.0.0.1:8888 GLM-5.3-Flash)

At boot, gated on docker, mentat, all four CX7 links and RoCE GIDs on every box:

    sed "s#@REPO@#$PWD#; s#@USER@#$USER#" scripts/glm53-triangle.service | sudo tee /etc/systemd/system/glm53-triangle.service
    sudo systemctl daemon-reload && sudo systemctl enable glm53-triangle

## Configuration

`scripts/config.sh`, overridden by `scripts/local.sh`. `install.sh` writes them into each box's `compose/.env`.

| Setting | Default | What |
| --- | --- | --- |
| `WORKER1`, `WORKER2` | — | ssh targets of the two other boxes |
| `KV_CACHE_MEMORY` | `19327352832` (18 GiB) | KV pin per rank. **Only with `GRAPH_SIZES` below**: with vLLM's own 57 graph sizes the graphs take ~10 GiB per rank and 18 GiB leaves the head too little room. Measured on the 64K kernel with dispram; without them, start at 16 GiB and measure with `bench/longwin.sh`. |
| `GRAPH_SIZES` | `1 8 12 15 16 24 32 48 64 80 96 112 128 160 192 224 256 320 384 448 512` | CUDA-graph capture sizes (tokens per step). Keeps every adaptive-k decode shape for 1–5 requests and steps of 8–16 to 128. 21 sizes take 3.2–4.0 GiB per rank against 10.2–10.8 GiB for vLLM's 57, at equal speed. |
| `MAX_MODEL_LEN` | `262144` | per-request window ([Limits](#limits)) |
| `DT_TAU` | `0.3` | kindling's draft-trunc threshold (0.2 / 0.3 / 0.45 measured flat; 0.3 best) |
| `NETDEVS`, `F0_HCAS`, `F1_HCAS` | GB10 defaults | CX7 netdevs and the ARX ring's RDMA devices; `start.sh` swaps the two lists once if mentat orders the workers the other way round |
| `CABLE_CHECKS` | empty | optional `host src dst` lines the boot gate pings |

## What this changes on top of kindling (a3c3a1d)

| | File | Why |
| --- | --- | --- |
| TP=3 triangle overlay | `compose/triangle-dgxos.yaml` | ARX ring on direct cables with the one-shot limit raised to its compiled 512 KiB (decode batches of ~6–11 requests stay off NCCL), the DFlash block-drop fix, `--prefix-match-unit 64`, the repair parser, dispram mounts, the 21 graph sizes, low default reasoning effort |
| Drafter-pool skip | `patches/0001-…` | `copy_kv_cache_blocks_inplace` walked the DFlash drafter's own KV pool with target block ids; the first partial prefix hit crashed every rank. This is what makes 64-token prefix matching safe: a follow-up turn computes ~780 new tokens instead of ~1,740. Proposed upstream as [#76](https://github.com/kindlingai/glm-5.3-flash-gx10/issues/76). |
| megamoe no-expert rows | `patches/0002-…` | rows vLLM marks with expert -1 crashed every mixed prefill+decode batch. Fixed upstream later in 6ffa0b6 (#67). |
| Tool-call repair | `compose/glm47_repair.py` | subclasses kindling's `glm47_failclosed`. Calls opened inside the reasoning, or abandoned mid-argument (5 of 5,094 on real agent traffic), are refused with the recovered call spelled out, never executed. Plus keep-alives while a long call is buffered, and the tool name sent once (OpenAI SDK clients concatenate deltas). Tests: `tests/test_glm47_repair.py`, 19/19. |
| dispram on DGX OS | `dgxos/dispram/` | see above |
| 64K kernel on DGX OS | `dgxos/k64/` | see above |
| Launch | `scripts/` | all three ranks down, then up head-first; fix the ARX ring order once if mentat mirrors it; /health; one generation. Boot gate with the RoCE GID-3 fix. |
| Measurement | `bench/` | idle-gated sparkDash benches, a guarded long-prompt needle test, GSM8K/HumanEval with a sandbox and miss classification |

## Limits

- **Window.** `MAX_MODEL_LEN=1048576` (the model's native maximum) starts and serves, but a ~500k-token cold
  prompt drove the head to 2.0 GiB free (the guard in `bench/longwin.sh` aborted it). The engine then kept that
  peak until restart. Long prefill's working memory grows with context: ~2.7 GiB at 250k, ~4.5 GiB at 500k on the
  head. A 1M window needs a smaller long-prefill chunk or a smaller KV pin, then re-testing. Not done.
- **64K kernel RAM.** The kernel returns 2.1 GiB of page bookkeeping per box. Under identical load on two workers
  (one on 4K, one on 64K), the 64K box's NVIDIA driver kept ~1/4 of the GPU memory processes freed (≈+3.5 GiB of
  memory no counter shows), plus ~1.9 GiB more page cache. Take the 64K kernel for prefill speed, not capacity.
  Cause not yet located (RM, UVM or libcuda); NVIDIA's 580.178.04 not yet compared.
- **Async scheduling** is unavailable with kindling's Ray/mentat executor in this vLLM. During single-stream
  decode the head GPU is busy 96% of the time anyway, so it could win at most ~4%.
- **Copy drafts** (TensorFold's prompt-lookup drafts): simulated over 3,040 real agent replies, only 12% of
  generated tokens repeat context, and even a perfect selector gives ~1.00× over DFlash2. Not built.
- **A restart empties the prefix cache**, so every conversation's next turn pays one cold prefill.
- kindling has moved on since a3c3a1d (c748079 adds its own dispram integration for kindling-spark-os). This
  recipe pins what was measured.

## Repository layout

    compose/triangle-dgxos.yaml   TP=3 overlay (stack last)        compose/glm47_repair.py   tool-call parser plugin
    patches/                      two fixes for kindling a3c3a1d   tests/                    parser tests (run in the image)
    scripts/                      config, install, start/stop, boot gate, systemd unit
    dgxos/dispram/                dispram on stock DGX OS          dgxos/k64/                64K kernel with a safety net
    bench/                        sparkDash wrapper, needle/long-window test, GSM8K + HumanEval
    docs/MEASUREMENTS.md          every number above, with method

## License

The files in this repository are MIT ([LICENSE](LICENSE)). Nothing from kindling is redistributed here:
`install.sh` clones it from its own repository at a pinned commit, and the two patches are diffs against it.
dispram is fetched from kindling-spark-os at install time and keeps its licences (server AGPL-3.0, client GPL-3.0
with a bundling exception).

## Credits

- **[kindling](https://github.com/kindlingai/glm-5.3-flash-gx10)** (kindlingai): the engine everything here runs on.
  Its vLLM integration, ARX, adaptive-k, draft-trunc, megamoe, dense FP8/NVFP4, weight snapshots and the fail-closed
  GLM parser are what make NVFP4 fast on GB10. Join their discord from the kindling README.
- **[kindling-spark-os](https://github.com/kindlingai/kindling-spark-os)**: dispram, and the 64 KiB-page / THP-off
  insight. This repo is a way to take those gains without its OS.
- **[Mia's AI Lab](https://x.com/MiaAI_lab)**: the [TensorFold recipe](https://github.com/MiaAI-Lab/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold)
  that set the bar and inspired the resume and tool-call work, and [sparkDash](https://github.com/MiaAI-Lab/sparkDash),
  the benchmark everyone shares.
- Z.AI ([GLM-5.3-Flash](https://huggingface.co/zai-org)), NVIDIA (the NVFP4 checkpoint, open-gpu-kernel-modules),
  incoai (DFlash2), [mentat](https://github.com/mmastrac/mentat), vLLM.
- Put together by **Stuart Trusty and his buddy Claude**.
