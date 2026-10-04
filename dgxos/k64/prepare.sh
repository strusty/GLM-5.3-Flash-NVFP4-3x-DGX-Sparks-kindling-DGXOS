#!/bin/bash
# prepare.sh — non-disruptive, run on EACH box: back up GRUB/fstab, pin the CURRENT kernel as GRUB's saved
# default (so installing the 64K flavour cannot silently become entry 0), install the safety net and the
# 64K-only units, then install Ubuntu's signed 64K flavour of the SAME kernel with the NVIDIA module build that
# matches THIS box's driver. Refuses if the dry run would touch any other package.
set -euo pipefail
K4=$(uname -r); case "$K4" in *-64k) echo "already on a 64K kernel"; exit 0;; esac; K64="$K4-64k"
NVPKG=$(dpkg-query -W -f '${Package}\n' "linux-modules-nvidia-*-open-$K4" 2>/dev/null | head -1)
[ -n "$NVPKG" ] || { echo "no linux-modules-nvidia-*-open-$K4 installed (DKMS-based setups are not handled)"; exit 1; }
NVVER=$(dpkg-query -W -f '${Version}' "$NVPKG"); NVPKG64="${NVPKG%-$K4}-$K64"
TS=$(date +%Y%m%dT%H%M%S); A=~/k64-backup-$TS; mkdir -p $A
sudo cp -a /etc/default/grub /etc/default/grub.d /etc/fstab /boot/grub/grubenv /boot/grub/grub.cfg $A/; sudo chown -R "$USER" $A; echo "backup: $A"
UUID=$(sudo grep -oE "gnulinux-simple-[0-9a-f-]+" /boot/grub/grub.cfg | head -1 | sed 's/gnulinux-simple-//')
E4="gnulinux-advanced-$UUID>gnulinux-$K4-advanced-$UUID"; E64="gnulinux-advanced-$UUID>gnulinux-$K64-advanced-$UUID"
sudo install -d -m 755 /var/lib/k64-trial; echo "$E4" | sudo tee /var/lib/k64-trial/E4 >/dev/null; echo "$E64" | sudo tee /var/lib/k64-trial/E64 >/dev/null
D="$(cd "$(dirname "$0")" && pwd)"
sudo grub-set-default "$E4"
sudo install -m 644 "$D/zz-saved-default.cfg" "$D/zz-panic-reboot.cfg" /etc/default/grub.d/
sudo install -m 755 "$D/k64-trial-guard" /usr/local/sbin/k64-trial-guard
sudo install -m 644 "$D/k64-trial-guard.service" "$D/k64-thp-never.service" "$D/swap-pagesize-fix.service" /etc/systemd/system/
sudo systemctl daemon-reload; sudo systemctl enable k64-trial-guard.service k64-thp-never.service swap-pagesize-fix.service >/dev/null 2>&1
grep -qE "^/swap.img\s.*\bnofail\b" /etc/fstab || sudo sed -i -E 's#^(/swap\.img\s+none\s+swap\s+)sw(\s)#\1sw,nofail\2#' /etc/fstab
sudo update-grub >/dev/null 2>&1
TOOLS=$(dpkg-query -W -f '${Package}\n' "linux-tools-$K4" 2>/dev/null | head -1); [ -n "$TOOLS" ] && TOOLS="linux-tools-$K64"
PK="linux-image-$K64 $NVPKG64=$NVVER $TOOLS"
SIM=$(sudo apt-get -s install --no-install-recommends $PK 2>&1)
echo "$SIM" | grep -E "^(Inst|Remv)" | sed 's/^/  dry run: /'
if echo "$SIM" | grep -E "^(Inst|Remv)" | grep -vE "linux-image-$K64 |linux-modules-$K64 |$NVPKG64 |linux-tools-$K64 " | grep -q .; then
  echo "ABORT: the install would touch other packages"; exit 2; fi
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends $PK >/tmp/k64-apt.log 2>&1 || { tail -20 /tmp/k64-apt.log; exit 3; }
echo "saved default still: $(sudo grub-editenv list | grep -oE 'saved_entry=.*' | grep -oE '[^>]*$')"
for m in r8127 mlx5_core mlx5_ib sbsa_gwdt nvme nvidia nvidia-uvm nvidia-modeset nvidia-drm nvidia-peermem; do
  f=$(find /lib/modules/$K64 -name "$m.ko*" | head -1); echo "  $m: ${f:+ok}${f:-MISSING}"; done
echo "nvidia module for $K64: $(modinfo -k $K64 -F version nvidia 2>/dev/null) (driver $(grep -oE '[0-9]{3}\.[0-9]+\.[0-9]+' /proc/driver/nvidia/version | head -1))"
