#!/usr/bin/env bash
# Swap the loaded NVIDIA modules for the installed vix modules without a reboot, then apply the profile.
#
#   sudo ./scripts/swap-live.sh [/etc/rtx-power.conf]
#
# Needs install-vix-modules.sh run for the RUNNING kernel and the modprobe.d override file in place.
# Stops every user of /dev/nvidia*, unloads nvidia_drm, nvidia_modeset, nvidia_uvm, nvidia_peermem and
# nvidia, loads them again (depmod now resolves them to extra/vix), then restarts the users and runs
# gpu-power-profile.sh. If the patched load fails, it removes this kernel's override lines and loads stock.
# Ends in $LOG, and on stdout via the exit code:
#   SWAP-OK (0)           patched modules loaded and max_limit reached POWER_LIMIT_W
#   SWAP-NOT-LIVE (1)     patched modules loaded, but the image did not raise max_limit
#   SWAP-ROLLED-BACK (1)  patched load failed; stock modules loaded
#   SWAP-ABORTED (1)      a check or rmmod failed; whatever was unloaded was loaded again
# Not for a GPU that drives your display.
set -u
CONF=${1:-/etc/rtx-power.conf}
# shellcheck source=/dev/null
. "$CONF" || { echo "cannot read $CONF"; exit 1; }
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
exec >>"$LOG" 2>&1
K=$(uname -r)
DEPCONF=/etc/depmod.d/nvidia-vix.conf
say() { echo "$(date -Is) swap: $*"; }
holders() { for p in /proc/[0-9]*; do for f in "$p"/fd/*; do case "$(readlink "$f" 2>/dev/null)" in /dev/nvidia*) echo "${p#/proc/} $(cat "$p"/comm)"; break ;; esac; done; done; }
load_all() { modprobe nvidia && modprobe nvidia_uvm && modprobe nvidia_modeset && modprobe nvidia_drm && { [ -z "$PEERMEM" ] || modprobe nvidia_peermem; }; }
start_users() {
  for s in $STOP_SERVICES; do systemctl start "$s"; done
  bash "$HERE/gpu-power-profile.sh" "$CONF"
  for c in $STOP_CONTAINERS; do docker start "$c" >/dev/null && say "$c started"; done
  [ -n "$HEALTH_CONTAINER" ] || return 0
  for _ in $(seq 1 60); do [ "$(docker inspect -f '{{.State.Health.Status}}' "$HEALTH_CONTAINER")" = healthy ] && { say "$HEALTH_CONTAINER healthy"; return 0; }; sleep 5; done
  say "$HEALTH_CONTAINER not healthy after 300 s"
}

say "=== start on $K"
[ "$(modinfo -n nvidia)" = "/lib/modules/$K/extra/vix/nvidia.ko" ] || { say "nvidia does not resolve to extra/vix for $K"; say SWAP-ABORTED; exit 1; }
grep -q RmLinuxVbiosOverrideImage /etc/modprobe.d/*.conf || { say "no RmLinuxVbiosOverrideImage option in modprobe.d"; say SWAP-ABORTED; exit 1; }
for c in $STOP_CONTAINERS; do docker stop -t 60 "$c" >/dev/null && say "$c stopped"; done
for s in $STOP_SERVICES; do systemctl stop "$s"; done
for n in $KILL_COMMS; do for pid in $(holders | awk -v n="$n" '$2==n{print $1}'); do kill -TERM "$pid"; done; done
sleep 3
LEFT=$(holders)
if [ -n "$LEFT" ]; then say "unexpected holders: $LEFT"; start_users; say SWAP-ABORTED; exit 1; fi
PEERMEM=$(grep -q '^nvidia_peermem ' /proc/modules && echo yes || true)
rmmod nvidia_peermem 2>/dev/null; rmmod nvidia_drm nvidia_modeset nvidia_uvm 2>/dev/null
rmmod nvidia || { say "rmmod nvidia failed"; load_all; start_users; say SWAP-ABORTED; exit 1; }
if load_all; then
  say "patched modules loaded from $(modinfo -n nvidia)"
else
  say "modprobe failed; loading stock"
  rmmod nvidia_peermem nvidia_drm nvidia_modeset nvidia_uvm nvidia 2>/dev/null
  cp -p "$DEPCONF" "$DEPCONF.bak-$(date +%Y%m%d%H%M%S)"
  sed -i "/ $K extra\/vix$/d" "$DEPCONF"
  depmod -a "$K"
  if load_all; then say "stock back: $(modinfo -n nvidia)"; else say "ERROR: stock modules failed to load too; check dmesg"; fi
  start_users; say SWAP-ROLLED-BACK; exit 1
fi
start_users
say "$(nvidia-smi -i "$GPU_INDEX" --query-gpu=power.limit,power.max_limit --format=csv,noheader)"
dmesg | grep -E "NVRM: Xid" | tail -3
MAX=$(nvidia-smi -i "$GPU_INDEX" --query-gpu=power.max_limit --format=csv,noheader,nounits | cut -d. -f1)
if [ -n "$POWER_LIMIT_W" ] && [ "${MAX:-0}" -ge "$POWER_LIMIT_W" ]; then say SWAP-OK; else say "max_limit ${MAX:-?} W is below POWER_LIMIT_W '${POWER_LIMIT_W}'; check the image path, size and pci= in modprobe.d"; say SWAP-NOT-LIVE; exit 1; fi
