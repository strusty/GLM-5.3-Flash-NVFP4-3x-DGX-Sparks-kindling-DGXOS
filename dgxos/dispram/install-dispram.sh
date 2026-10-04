#!/bin/bash
# install-dispram.sh — run ON EACH BOX (sudo needed): lend the GB10 display carveout (2046 MiB the NVIDIA driver
# reserves and never uses on GB10) to the KV cache, on stock DGX OS. Uses kindling-spark-os's dispram unmodified
# (fetched at a pinned commit; server AGPL-3.0, client GPL-3.0 with a bundling exception).
#  1. fetches dispram and open-gpu-kernel-modules' RM headers at THIS box's driver tag
#  2. builds librmlist.so, installs /opt/kindling/dispram, /etc/kindling/dispram.env, dispramd.service
#  3. DISPRAM_DRIVER pins the driver it was built for: after any driver update dispramd refuses to run (exit 3)
#     and vLLM simply sizes KV without it until you re-run this script and verify.py.
# Then, with NOTHING borrowing the carveout (engine stopped): python3 dgxos/dispram/verify.py
set -euo pipefail
HERE="$(cd "$(dirname "$0")/../.." && pwd)"; . "$HERE/scripts/config.sh"
DRV=$(grep -oE '[0-9]{3}\.[0-9]+\.[0-9]+' /proc/driver/nvidia/version | head -1)
[ -n "$DRV" ] || { echo "NVIDIA driver not loaded"; exit 1; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
echo "driver $DRV; fetching dispram ($KSO_REF) and RM headers (open-gpu-kernel-modules $DRV)"
git -C "$W" init -q kso && git -C "$W/kso" remote add origin "$KSO_REPO" && git -C "$W/kso" sparse-checkout set dispram >/dev/null
git -C "$W/kso" fetch -q --depth 1 --filter=blob:none origin "$KSO_REF" && git -C "$W/kso" checkout -q FETCH_HEAD
git -C "$W" init -q ogkm && git -C "$W/ogkm" remote add origin https://github.com/NVIDIA/open-gpu-kernel-modules.git
git -C "$W/ogkm" sparse-checkout set src/common/sdk/nvidia/inc kernel-open/common/inc src/nvidia/arch/nvalloc/unix/include >/dev/null
git -C "$W/ogkm" fetch -q --depth 1 --filter=blob:none origin "refs/tags/$DRV" && git -C "$W/ogkm" checkout -q FETCH_HEAD
gcc -O2 -Wall -Werror -shared -fPIC "$W/kso/dispram/rmlist.c" -o "$W/librmlist.so" \
    -I"$W/ogkm/src/common/sdk/nvidia/inc" -I"$W/ogkm/kernel-open/common/inc" -I"$W/ogkm/src/nvidia/arch/nvalloc/unix/include"
D=/opt/kindling/dispram
sudo install -d -m 755 $D/python/dispram_vllm-0.1.dist-info $D/vllm /etc/kindling
sudo install -m 755 "$W/kso/dispram/dispramd.py" $D/
sudo install -m 644 "$W/librmlist.so" "$W/kso/dispram/"{LICENSE,LICENSE-GPL,BUNDLING-EXCEPTION,README.md} $D/
sudo install -m 644 "$W/kso/dispram/python/"{dispram.py,dispram_vllm.py} $D/python/
sudo install -m 644 "$W/kso/dispram/python/dispram_vllm-0.1.dist-info/"* $D/python/dispram_vllm-0.1.dist-info/
printf '# written by install-dispram.sh: the driver release librmlist.so was built and verified for\nDISPRAM_DRIVER=%s\n' "$DRV" | sudo tee /etc/kindling/dispram.env >/dev/null
sudo install -m 644 "$HERE/dgxos/dispram/dispramd.service" /etc/systemd/system/dispramd.service
sudo systemctl daemon-reload && sudo systemctl enable --now dispramd
sleep 2; sudo journalctl -u dispramd -b --no-pager -o cat | tail -1
echo "next (engine stopped): python3 $HERE/dgxos/dispram/verify.py"
