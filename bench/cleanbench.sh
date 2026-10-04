#!/bin/bash
# cleanbench.sh LABEL KIND CONCS RUNS — sparkDash benches that wait for an idle server first and are retried (up to
# 3x) when outside requests overlapped them (max running > largest concurrency). Without this, live traffic made a
# config look 11-17% slower at prefill than it was. Run on the head, or set HEAD_SSH=user@head.
#   KIND: prose | code | prefill     CONCS: e.g. "[1,4,8,12]" (prefill: context sizes, e.g. "[16384,65536]")
#   Needs SPARK_ID / SPARKDASH_URL (see psbench.py) and MODEL. Writes results/cb-LABEL-KIND-N.json
cd "$(dirname "$0")"; mkdir -p results
L=$1; K=$2; C=$3; N=${4:-2}; M="${MODEL:-GLM-5.3-Flash}"; P="${API_PORT:-8888}"; MAXC=$(python3 -c "print(max($C))")
hc() { if [ -n "${HEAD_SSH:-}" ]; then ssh -o BatchMode=yes "$HEAD_SSH" "$1"; else bash -c "$1"; fi; }
running() { hc "curl -s -m5 http://127.0.0.1:$P/metrics | grep -E '^vllm:num_requests_running\{' | awk '{print int(\$NF)}'"; }
wait_idle() { local n=0 i; for i in $(seq 1 120); do [ "$(running)" = 0 ] && n=$((n+1)) || n=0; [ $n -ge 3 ] && return; sleep 5; done; }
for r in $(seq 1 $N); do
  for t in 1 2 3; do
    wait_idle; T0=$(date -u +%s)
    if [ "$K" = prefill ]; then python3 psbench.py prefill-bench "{\"port\":$P,\"modelId\":\"$M\",\"contextSizes\":$C}" >/dev/null 2>&1; f=$(ls -t psbench-prefill-bench-*.json | head -1); lim=1
    else python3 psbench.py bench "{\"port\":$P,\"modelId\":\"$M\",\"concurrencies\":$C,\"maxTokens\":512,\"promptType\":\"$K\"}" >/dev/null 2>&1; f=$(ls -t psbench-bench-*.json | head -1); lim=$MAXC; fi
    m=$(hc "docker logs --since \$(( \$(date -u +%s) - $T0 + 3 ))s glm53 2>&1 | grep -aoE 'Running: [0-9]+' | awk '{print \$2}' | sort -n | tail -1"); m=${m:-0}
    if [ "$m" -le "$lim" ]; then cp "$f" "results/cb-$L-$K-$r.json"; break; fi
    echo "  ($L $K run $r: outside traffic, max running $m > $lim, retry $t)" >&2
  done
done
python3 - "$L" "$K" <<'PY'
import json, glob, statistics as st, sys
L, K = sys.argv[1], sys.argv[2]; rows = {}
for f in sorted(glob.glob(f"results/cb-{L}-{K}-*.json")):
    for r in json.load(open(f))["results"]:
        rows.setdefault(r.get("concurrency", r.get("targetTokens")), []).append(r.get("aggregateDecodeTps", r.get("prefillTps")))
print(f"  {L} {K:7s} " + "  ".join(f"{('x' + str(c)) if K != 'prefill' else (str(c // 1024) + 'k')} {st.median(v):6.1f}" for c, v in sorted(rows.items())))
PY
