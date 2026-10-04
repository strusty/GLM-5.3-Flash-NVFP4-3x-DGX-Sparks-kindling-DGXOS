#!/bin/bash
# confirm.sh — disarm the guard, drop the trial-only watchdog/timeout, make the 64K kernel the saved default.
set -euo pipefail
[[ $(uname -r) == *-64k ]] || { echo "not on the 64K kernel; refusing"; exit 1; }
sudo -n touch /var/lib/k64-trial/confirmed
for i in $(seq 1 15); do [ -e /var/lib/k64-trial/armed ] || break; sleep 1; done
[ ! -e /var/lib/k64-trial/armed ] || { echo "guard did not disarm"; exit 1; }
sudo -n rm -f /etc/systemd/system.conf.d/k64-trial-watchdog.conf /etc/systemd/system/multi-user.target.d/k64-trial-timeout.conf
if [ -z "$(systemctl list-jobs --no-legend)" ]; then sudo -n systemctl daemon-reexec; sleep 2; else echo "boot jobs still running: watchdog stays armed until the next daemon-reexec or boot (harmless)"; fi
sudo -n grub-set-default "$(cat /var/lib/k64-trial/E64)"
echo "confirmed: guard $(systemctl is-active k64-trial-guard), watchdog $(systemctl show -p RuntimeWatchdogUSec --value), grubenv: $(sudo -n grub-editenv list | tr '\n' ' ')"
sudo -n journalctl -u k64-trial-guard -b --no-pager -o cat | tail -2
