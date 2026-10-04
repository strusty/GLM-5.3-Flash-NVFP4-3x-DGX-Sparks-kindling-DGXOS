# The 64 KiB-page kernel on stock DGX OS, with a safety net

Ubuntu ships a Canonical-signed `nvidia-64k` flavour of the same kernel DGX OS runs (`6.17.0-1026-nvidia-64k`),
with NVIDIA open-module builds for each driver (`…26` for 580.159.03, `…26+3` for 580.173.02), in DGX OS's own
apt. Secure Boot keeps working. On three GB10 boxes it gave ~19–36% faster cold prefill. Its 2.1 GiB of RAM was
mostly offset by the NVIDIA driver retaining freed GPU memory on 64K pages ([../../README.md#limits](../../README.md#limits)).

**Nothing here can leave a box unreachable for good.**

1. `prepare.sh` (no reboot) first pins the **current** kernel as GRUB's saved default (`GRUB_DEFAULT=saved`).
   With both flavours installed, "entry 0" is whichever sorts newest, so installing the 64K flavour alone would
   change the next boot. It then installs the safety net and the 64K-only units, dry-runs the package install
   (it refuses if anything else would change), and installs the 64K image, modules and the NVIDIA module build
   matching your driver.
2. `arm.sh` sets the 64K entry for **one boot only** (`grub-reboot`). It also arms the SBSA hardware watchdog for
   the trial (`RuntimeWatchdogSec=60s`; soak it 75 s before rebooting to see no spurious reset), a boot timeout
   that force-reboots if multi-user.target never arrives, and `k64-trial-guard`. The guard reboots back to the
   saved default 15 minutes after boot unless `/var/lib/k64-trial/confirmed` appears, which you write over SSH.
   **A boot that lost networking can never be confirmed, so it always reverts.**
   `panic=10` (permanent) turns a kernel panic into a reboot, and GRUB's one-shot entry is spent by then.
3. After the reboot: `verify.sh` (page size, gateway, tailscale if present, all four CX7 links pinging a peer,
   RoCE GID 3, GPU, dispram, docker, THP, min_free, swap, failed units, NVRM/Xid/mlx5 errors;
   `EXTRA_UNITS="a.service"` adds yours), then `confirm.sh` disarms the guard and makes 64K the saved default.
4. Do one box at a time, the engine stopped. To go back: `sudo grub-set-default "$(cat /var/lib/k64-trial/E4)" && sudo systemctl reboot`.

**Gotchas found on the way:**
- `nv-cpu-governor` calls `cpupower`, which ships per flavour: `prepare.sh` installs `linux-tools-…-64k`.
- A swap header records its page size, so `/swap.img` from the 4K kernel is refused on 64K and vice versa.
  `swap-pagesize-fix.service` re-makes it for whichever kernel booted.
- THP on a 64K kernel means 512 MiB huge pages and a `min_free_kbytes` that grows toward 5% of RAM:
  `k64-thp-never.service` turns THP off on the 64K kernel only.
- CUDA can hang copying from a file-backed mmap on 64K. kindling already loads safetensors eagerly and restores
  weight snapshots with O_DIRECT reads into pinned buffers, so it is unaffected.
- If your engine unit is a long `Type=oneshot` that multi-user.target waits for, raise `JobTimeoutSec` in
  `k64-trial-timeout.conf` past its start time.
- DGX OS's docker has a 60–180 s `ExecStartPre=/bin/sleep` power-stagger. Docker reading "activating" for
  minutes after boot is not a fault.
