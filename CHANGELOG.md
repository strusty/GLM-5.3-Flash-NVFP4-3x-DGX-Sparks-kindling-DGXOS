# Changelog

## v1.1 (2026-10-10)

Measurements and docs; nothing changes unless you opt in.

- **Many agents at once (opt-in):** two kindling commits on our fork, proposed upstream as kindling #87:
  - prefill cadence: the others keep 4.6–4.9 tok/s instead of 1.5–1.7 while a 100k prompt is read in;
  - priority parking plus sub-agent tagging: an interactive turn behind six sub-agent reads waits 12.7 s instead of 38.6 s;
  - an opt-in `effort_tail` template.
- **Overlay:** `SCHED_ARGS` (empty) for `--scheduling-policy priority`, and `BREAKABLE_CG` (default 1, unchanged
  behaviour) as the kindling #85 escape hatch.
- **README:**
  - running headless (dispram fails beside a logged-in desktop), one RoCE GID index, mentat island placement, pinning the head;
  - quality with thinking on at low vs max effort: 98.4 / 93.9% vs 99.2 / 98.2%;
  - restart re-warm and heat notes.
- **Measured** (docs/MEASUREMENTS.md):
  - breakable CUDA graphs off costs 8% prefill and 25% code at 8 streams;
  - kindling's fused DFlash2 conv vs the upstream revert: a tie;
  - adaptive-k per-request mode, forced k=7 and exploration: no gain on clean traffic.

## v1.0 (2026-10-04)

First release: kindling a3c3a1d at TP=3 on three GB10 boxes, on stock DGX OS.

- **Memory without a custom OS:**
  - dispram on DGX OS (+2 GiB KV per rank);
  - the 64K kernel with a safety net (faster prefill);
  - 21 CUDA-graph sizes instead of 57 (~7 GiB per rank back);
  - KV pin 18 GiB: **3,054,135 tokens, 11.65 lanes at 262k**, with the head's worst-case free memory twice the old setup's.
- **TP=3 triangle overlay:** ARX one-shot to 512 KiB, the DFlash block-drop fix, `--prefix-match-unit 64`,
  low default reasoning effort.
- **Fixes:** drafter-pool skip in `copy_kv_cache_blocks_inplace` (enables 64-token prefix matching);
  megamoe no-expert rows.
- **`glm47_repair`:** nested or abandoned tool calls refused with a recovery hint; keep-alives; name sent once.
- **Launch:** start/stop across three boxes with the ARX ring-order fix; a boot gate with the RoCE GID-3 fix; a systemd unit.
- **Measured:**
  - prose 66 / 116 / 156 / 179 tok/s at 1/4/8/12 streams;
  - prefill 3,100–3,550 tok/s;
  - GSM8K 96.4% (full set), HumanEval 94.5%.
