#!/bin/bash
# verify.sh — after the trial boot: everything that must work before the 64K boot is confirmed.
ok=0; bad=0; pass() { echo "  PASS $*"; ok=$((ok+1)); }; fail() { echo "  FAIL $*"; bad=$((bad+1)); }
chk() { if eval "$2" >/dev/null 2>&1; then pass "$1"; else fail "$1"; fi; }
echo "== $(hostname) $(uname -r) up $(cut -d. -f1 /proc/uptime)s"
chk "kernel is 64K flavour" '[[ $(uname -r) == *-64k ]]'
chk "page size 65536" '[ "$(getconf PAGESIZE)" = 65536 ]'
GW=$(ip route show default | awk '{print $3; exit}')
chk "default route present" '[ -n "$GW" ]'
chk "default gateway answers ($GW)" 'ping -c2 -W2 $GW'
command -v tailscale >/dev/null && chk "tailscale up" 'tailscale ip -4 | grep -q "^100\."'
for i in enp1s0f0np0 enp1s0f1np1 enP2p1s0f0np0 enP2p1s0f1np1; do
  a=$(ip -4 -br addr show $i | awk '{print $3}' | cut -d/ -f1); n=${a%.*}; me=${a##*.}
  chk "CX7 $i up ($a)" 'ip -br link show '$i' | grep -q "UP"'
  for p in 1 2 3; do [ "$p" = "$me" ] && continue; ping -c1 -W1 $n.$p >/dev/null 2>&1 && { pass "CX7 $i reaches $n.$p"; break; }; done
done
for d in /sys/class/infiniband/*; do b=$(basename $d); st=$(cat $d/ports/1/state 2>/dev/null); g=$(cat $d/ports/1/gids/3 2>/dev/null)
  chk "RDMA $b ACTIVE, GID[3] set" '[[ "'"$st"'" == *ACTIVE* ]] && [ -n "'"$g"'" ] && [ "'"$g"'" != "0000:0000:0000:0000:0000:0000:0000:0000" ]'; done
chk "nvidia-smi works" 'nvidia-smi -L | grep -q GPU'
echo "  info driver $(grep -oE '[0-9]{3}\.[0-9]+\.[0-9]+' /proc/driver/nvidia/version | head -1)"
chk "dispramd active, carveout found" 'systemctl is-active dispramd && sudo -n journalctl -u dispramd -b --no-pager -o cat | grep -q "DISPLAY_FRM 0x280200000 + 2046 MiB"'
chk "docker active" 'systemctl is-active docker'
chk "mentatd container up" 'docker ps --format "{{.Names}}" | grep -qx mentatd'
chk "THP never" 'grep -q "\[never\]" /sys/kernel/mm/transparent_hugepage/enabled'
chk "min_free_kbytes 1 GiB" '[ "$(cat /proc/sys/vm/min_free_kbytes)" = 1048576 ]'
chk "swap /swap.img active" 'swapon --show=NAME --noheadings | grep -qx /swap.img'
chk "trial guard waiting" 'systemctl is-active k64-trial-guard && [ -e /var/lib/k64-trial/armed ]'
chk "HW watchdog armed for the trial" '[ "$(systemctl show -p RuntimeWatchdogUSec --value)" = 1min ]'
chk "no NVRM/Xid/mlx5 errors" '! sudo -n journalctl -k -b --no-pager | grep -iE "NVRM.*(error|fail)|Xid|mlx5.*(error|fail)" | grep -q .'
echo "  info MemTotal $(awk '/MemTotal/{printf "%.2f GiB", $2/1048576}' /proc/meminfo)  MemAvailable $(awk '/MemAvailable/{printf "%.2f GiB", $2/1048576}' /proc/meminfo)"
echo "  info failed units: $(systemctl --failed --no-legend --plain | awk '{print $1}' | tr '\n' ' ')"
echo "  info kernel err lines: $(sudo -n journalctl -k -b -p err --no-pager -o cat | wc -l)"
for u in ${EXTRA_UNITS:-}; do chk "unit $u active" "systemctl is-active $u"; done   # EXTRA_UNITS="a.service b.service" bash verify.sh
echo "RESULT $ok pass, $bad fail"
