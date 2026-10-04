# Changelog

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
