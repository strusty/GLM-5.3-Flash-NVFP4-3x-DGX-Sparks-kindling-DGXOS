# Announcement thread (X / Twitter)

Ready to paste. Each block is one post; 1/7 carries the link. Swap in kindling's X handle if they have one.

---

**1/7**
GLM-5.3-Flash NVFP4 on 3× DGX Spark, on the stock DGX OS that ships on the box. No custom OS.

🔥 3,100–3,500 tok/s cold prefill
🧵 no 8-request cap: 3.05M-token KV pool, 11.6 full 262k conversations at once
❄️ runs cool

Built on kindling. Recipe 👇
github.com/strusty/GLM-5.3-Flash-NVFP4-3x-DGX-Sparks-kindling-DGXOS

**2/7**
kindling's own OS (kindling-spark-os) finds ~4 GB per box: a 64K-page kernel plus "dispram", lending the GPU's
unused 2 GB display carveout to the KV cache.

Both work on stock DGX OS. dispram is userspace, and the 64K kernel is Ubuntu's own signed flavour, already in apt.

**3/7**
The bigger win needed no OS change at all.

vLLM captures CUDA graphs at 57 batch sizes, about 10 GB per box. 21 sizes cover every decode shape we use and take
3–4 GB, at the same speed.

That's ~7 GB per box back. Half went to KV (+26%), half to headroom (2× the old floor).

**4/7**
Numbers (sparkDash, warm, idle-gated runs):
• prose 66 / 116 / 156 / 179 tok/s at 1 / 4 / 8 / 12 streams
• 64k prompt: 20 s cold, 0.41 s resent
• agent follow-up turn: 0.6–1.1 s
• GSM8K 96.4% (all 1,319), HumanEval 94.5%

**5/7**
How it compares with @MiaAI_lab's TensorFold on 3 Sparks:
✅ ~1.7× faster cold prefill, more code throughput, no 8-request cap, cool
➖ she has the 1M window, instant resume, and +15% single-stream prose

Hers for a few long chats. This for a fleet of agents.

**6/7**
Also in the repo:
• a GLM tool-call repair parser: nested or abandoned calls are refused with a hint instead of executed
• a fix that makes 64-token prefix matching safe at TP=3
• a 64K-kernel switch with a safety net: one-shot boot, auto-revert unless confirmed, watchdog

**7/7**
Huge credit to kindling (the engine, ARX, adaptive-k, megamoe, dispram) and Mia's AI Lab (TensorFold, sparkDash).
We stood on their shoulders.

— Stuart & his buddy Claude
