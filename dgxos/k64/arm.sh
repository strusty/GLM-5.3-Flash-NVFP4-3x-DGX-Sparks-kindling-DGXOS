#!/bin/bash
# arm.sh — run on the box about to try the 64K kernel: trial-only safety (HW watchdog + boot timeout), arm the guard, one-shot boot entry for the 64K kernel.
set -euo pipefail
D="$(cd "$(dirname "$0")" && pwd)"
E64=$(cat /var/lib/k64-trial/E64)
sudo -n install -d /etc/systemd/system.conf.d /etc/systemd/system/multi-user.target.d
sudo -n install -m 644 $D/k64-trial-watchdog.conf /etc/systemd/system.conf.d/
sudo -n install -m 644 $D/k64-trial-timeout.conf /etc/systemd/system/multi-user.target.d/
sudo -n systemctl daemon-reexec; sleep 3
echo "watchdog armed now: $(systemctl show -p RuntimeWatchdogUSec --value) / reboot $(systemctl show -p RebootWatchdogUSec --value) | hw: $(cat /sys/class/watchdog/watchdog0/state 2>/dev/null) timeout=$(cat /sys/class/watchdog/watchdog0/timeout 2>/dev/null)s"
sudo -n rm -f /var/lib/k64-trial/confirmed; sudo -n touch /var/lib/k64-trial/armed
sudo -n grub-reboot "$E64"
echo "grubenv: $(sudo -n grub-editenv list | tr '\n' ' ')"
echo "uptime at arm: $(cut -d' ' -f1 /proc/uptime)"
