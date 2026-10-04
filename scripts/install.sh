#!/bin/bash
# install.sh — on the head: put kindling (pinned), this repo's patches, overlay and parser on all three boxes,
# and write the settings into each box's compose/.env. Idempotent. Does not start anything.
# Prerequisites per kindling's README: its image built on every box, mentat running, the TP=3 padded checkpoints.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"; . "$HERE/scripts/config.sh"
[ -n "$WORKER1" ] && [ -n "$WORKER2" ] || { echo "set WORKER1 and WORKER2 in scripts/local.sh"; exit 1; }
for h in "${HOSTS[@]}"; do
  echo "== $h"
  run_on "$h" "set -e; [ -d '$KINDLING_DIR/.git' ] || git clone -q '$KINDLING_REPO' '$KINDLING_DIR'; cd '$KINDLING_DIR'
    git fetch -q origin 2>/dev/null || true; git checkout -q '$KINDLING_REF' 2>/dev/null || git checkout -q -f '$KINDLING_REF'
    echo \"  kindling at \$(git rev-parse --short HEAD)\""
  for p in "$HERE"/patches/*.patch; do
    if [ "$h" = local ]; then cp "$p" /tmp/; else scp -q "$p" "$h:/tmp/"; fi
    run_on "$h" "cd '$KINDLING_DIR'; f=/tmp/$(basename "$p"); if git apply --reverse --check \$f 2>/dev/null; then echo '  already applied: $(basename "$p")'; else git apply \$f && echo '  applied: $(basename "$p")'; fi; rm -f \$f"
  done
  for f in compose/triangle-dgxos.yaml compose/glm47_repair.py; do
    if [ "$h" = local ]; then cp "$HERE/$f" "$KINDLING_DIR/$f"; else scp -q "$HERE/$f" "$h:$KINDLING_DIR/$f"; fi
  done
  run_on "$h" "cd '$KINDLING_DIR/compose'; touch .env
    set_kv() { grep -q \"^\$1=\" .env && sed -i \"s|^\$1=.*|\$1=\$2|\" .env || echo \"\$1=\$2\" >> .env; }
    set_kv MODEL_HOST_DIR '$MODEL_HOST_DIR'; set_kv DFLASH_HOST_DIR '$DFLASH_HOST_DIR'; set_kv SERVED_NAME '$SERVED_NAME'
    set_kv API_PORT '$API_PORT'; set_kv VLLM_ARXBIG 0; set_kv KV_CACHE_MEMORY '$KV_CACHE_MEMORY'; set_kv MAX_MODEL_LEN '$MAX_MODEL_LEN'
    set_kv DT_TAU '$DT_TAU'; set_kv GRAPH_ARGS '--cudagraph-capture-sizes $GRAPH_SIZES'
    grep -q '^ARX_RING_PREV_HCAS=' .env || set_kv ARX_RING_PREV_HCAS '$F1_HCAS'; grep -q '^ARX_RING_NEXT_HCAS=' .env || set_kv ARX_RING_NEXT_HCAS '$F0_HCAS'
    echo \"  compose/.env: KV \$(grep ^KV_CACHE_MEMORY= .env | cut -d= -f2) window \$(grep ^MAX_MODEL_LEN= .env | cut -d= -f2)\""
done
echo "done. Next: dgxos/dispram/install-dispram.sh on every box (optional, +2 GiB KV), then scripts/start.sh"
