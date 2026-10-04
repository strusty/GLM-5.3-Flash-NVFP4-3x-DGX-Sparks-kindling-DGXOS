#!/bin/bash
# longwin.sh NTOK — run on the HEAD: one needle prompt of ~0.83*NTOK tokens with an abort guard (kills the client,
# which aborts the request, if MemAvailable drops under GUARD_MIB, default 2048), and the lowest MemAvailable seen.
# Note: after a very long prompt the engine keeps its peak working memory reserved until restart.
N=${1:-300000}; G=${GUARD_MIB:-2048}; H="$(cd "$(dirname "$0")" && pwd)"
python3 "$H/needle.py" "$N" > /tmp/needle.out 2>&1 & P=$!; m=999999
while kill -0 $P 2>/dev/null; do a=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo); [ $a -lt $m ] && m=$a
  if [ $a -lt $G ]; then kill $P; echo "ABORTED by guard: MemAvailable $a MiB"; break; fi; sleep 0.5; done
wait $P 2>/dev/null; tail -2 /tmp/needle.out; echo "head floor $m MiB, swap used $(free -m | awk '/Swap/{print $3}') MiB"
