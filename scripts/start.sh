#!/bin/bash
# start.sh — start (or with "down", stop) the kindling GLM-5.3-Flash TP=3 stack on all three boxes, from the head.
#   start.sh        start: all ranks down (confirmed gone), then up head-first; check mentat's
#                             rank order against the ARX ring devices (fix + restart once if mirrored);
#                             wait for /health; prove one real generation.
#   start.sh down   stop all three ranks.
# kindling in $KINDLING_DIR (compose/.env + compose/triangle-dgxos.yaml). Replacing a running stack rank by
# rank can hang the group, so every start takes all three down first (kindling README §5).
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"; . "$HERE/scripts/config.sh"
DIR="$KINDLING_DIR"
CMP="./glm53 -f experimental/compose/tp3.yaml -f compose/triangle-dgxos.yaml"
URL="http://127.0.0.1:$API_PORT"
MODEL="$SERVED_NAME"
# ARX ring devices. mentat makes the head rank 0 and orders the workers itself:
#   WORKER2=1, WORKER1=2  -> on every box port f0 faces NEXT, f1 faces PREV (for a triangle cabled f0->f1 around the ring)
#   WORKER1=1, WORKER2=2  -> mirrored: start.sh swaps the two lists and restarts once
F0="$F0_HCAS"; F1="$F1_HCAS"

log() { echo "glm-kindling: $*"; }

down_all() {
  local h n i
  for h in "${HOSTS[@]}"; do run_on "$h" "cd $DIR && $CMP down --timeout 60 >/dev/null 2>&1"; done
  for i in $(seq 1 30); do
    n=0; for h in "${HOSTS[@]}"; do n=$((n + $(run_on "$h" "docker ps -a --format '{{.Names}}' | grep -cx glm53"))); done
    [ "$n" -eq 0 ] && return 0; sleep 2
  done
  log "containers still present after down"; return 1
}

up_all() {
  local h
  for h in "${HOSTS[@]}"; do run_on "$h" "cd $DIR && $CMP up -d >/dev/null 2>&1" || { log "up failed on $h"; return 1; }; done
}

set_ring() {  # set_ring <prev> <next> on all three boxes
  local h
  for h in "${HOSTS[@]}"; do
    run_on "$h" "cd $DIR && sed -i -e 's/^ARX_RING_PREV_HCAS=.*/ARX_RING_PREV_HCAS=$1/' -e 's/^ARX_RING_NEXT_HCAS=.*/ARX_RING_NEXT_HCAS=$2/' compose/.env"
  done
}

worker2_rank() {  # waits for WORKER2's NCCL init line, echoes its rank (1 or 2), or nothing on timeout
  local i r
  for i in $(seq 1 60); do
    r=$(run_on "$WORKER2" "docker logs glm53 2>&1 | grep -aoE 'rank [0-9] nRanks 3' | head -1 | awk '{print \$2}'")
    [ -n "$r" ] && { echo "$r"; return; }
    sleep 5
  done
}

wait_ready() {
  local deadline=$((SECONDS + 1500))
  while [ $SECONDS -lt $deadline ]; do
    curl -sf -m5 "$URL/health" >/dev/null && return 0
    if ! run_on local "docker ps --format '{{.Names}}' | grep -qx glm53"; then log "head container gone during boot"; return 1; fi
    if run_on local "docker logs glm53 2>&1 | grep -qaE 'RayActorError|DEGENERATE|FATAL'"; then log "engine failed during boot"; return 1; fi
    sleep 10
  done
  log "not healthy after 25 min"; return 1
}

smoke() {
  local out
  out=$(curl -s -m120 "$URL/v1/chat/completions" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: PING\"}],\"max_tokens\":512,\"chat_template_kwargs\":{\"enable_thinking\":false}}" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); t=(d['choices'][0]['message'].get('content') or '').strip(); n=(d.get('usage') or {}).get('completion_tokens') or 0; print(t or ('<%d tokens, still thinking>' % n if n else ''))" 2>/dev/null)
  # kindling thinks briefly even with thinking off; 512 tokens, and generated tokens count as alive.
  [ -n "$out" ] && { log "smoke: '$out'"; return 0; }
  log "smoke: no text"; return 1
}

if [ "${1:-start}" = down ]; then down_all; exit $?; fi

sync; sudo -n sh -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null
for attempt in 1 2; do
  down_all || exit 1
  sleep 3
  up_all || exit 1
  r=$(worker2_rank)
  [ -z "$r" ] && { log "no NCCL rank line from WORKER2"; exit 1; }
  if [ "$r" = 1 ]; then want_prev=$F1; want_next=$F0; else want_prev=$F0; want_next=$F1; fi
  have=$(grep -E '^ARX_RING_PREV_HCAS=' "$DIR/compose/.env" | cut -d= -f2)
  if [ "$have" != "$want_prev" ]; then
    log "mentat put WORKER2 at rank $r: ARX ring devices mirrored, rewriting compose/.env on all three and restarting "
    set_ring "$want_prev" "$want_next"
    continue
  fi
  log "rank order ok (WORKER2 = rank $r)"
  wait_ready || exit 1
  smoke || exit 1
  log "READY: $(curl -s -m5 $URL/v1/models | python3 -c "import sys,json; print([m['id'] for m in json.load(sys.stdin)['data']])")"
  exit 0
done
log "rank order still wrong after rewrite"; exit 1
