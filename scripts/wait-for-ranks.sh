#!/bin/bash
# wait-for-ranks.sh — boot gate before start.sh (the systemd unit runs it as ExecStartPre). The TP=3 stack must
# not start until all three boxes are ready:
#   - docker answers and mentatd runs (status on :6380) on every box
#   - all four CX7 netdevs are UP on every box
#   - RoCE GID index 3 is populated on all four RDMA devices of every box. A port that got its address while its
#     peer was down can keep GID 3 empty; after 60 s the gate applies the known fix once per port
#     (nmcli device disconnect/connect). It runs before any engine container exists.
#   - optional: every cable answers (CABLE_CHECKS in scripts/config.sh)
# Polls up to 25 min, then exits non-zero (the unit retries).
HERE="$(cd "$(dirname "$0")/.." && pwd)"; . "$HERE/scripts/config.sh"
DEADLINE=$((SECONDS+1500))
declare -A EMPTY_SINCE FIXED
box_ok() {
  run_on "$1" "docker info >/dev/null 2>&1 && docker ps --format '{{.Names}}' | grep -qx mentatd \
    && curl -sf -m3 http://127.0.0.1:6380/status >/dev/null \
    && for d in $NETDEVS; do ip -br link show \$d | grep -q UP || exit 1; done" 2>/dev/null
}
gids_ok() {
  local host netdev rdma g key rc=0
  for host in "${HOSTS[@]}"; do
    for netdev in $NETDEVS; do
      rdma=$(run_on "$host" "basename \$(ls -d /sys/class/net/$netdev/device/infiniband/* 2>/dev/null | head -1)" 2>/dev/null)
      g=$(run_on "$host" "cat /sys/class/infiniband/$rdma/ports/1/gids/3" 2>/dev/null)
      key="$host/$netdev"
      if [ -z "$rdma" ] || [ -z "$g" ] || [ "$g" = "0000:0000:0000:0000:0000:0000:0000:0000" ]; then
        rc=1; [ -n "${EMPTY_SINCE[$key]}" ] || EMPTY_SINCE[$key]=$SECONDS
        if [ $((SECONDS - EMPTY_SINCE[$key])) -ge 60 ] && [ -z "${FIXED[$key]}" ]; then
          echo "wait-for-ranks: GID 3 empty on $key for 60 s -> nmcli device disconnect/connect"
          run_on "$host" "sudo -n nmcli device disconnect $netdev; sleep 2; sudo -n nmcli device connect $netdev" >/dev/null 2>&1
          FIXED[$key]=1
        fi
      else unset "EMPTY_SINCE[$key]"; fi
    done
  done
  return $rc
}
cables_ok() {
  local h s d
  while read -r h s d; do
    [ -z "$h" ] && continue
    run_on "$h" "ping -c1 -W2 -I $s $d" >/dev/null 2>&1 || { echo "wait-for-ranks: cable $s -> $d not ready"; return 1; }
  done <<< "$CABLE_CHECKS"
}
while [ $SECONDS -lt $DEADLINE ]; do
  if box_ok local && box_ok "$WORKER1" && box_ok "$WORKER2" && gids_ok && cables_ok; then
    echo "wait-for-ranks: all three ready after ${SECONDS}s"; exit 0
  fi
  sleep 10
done
echo "wait-for-ranks: not ready after ${SECONDS}s" >&2; exit 1
