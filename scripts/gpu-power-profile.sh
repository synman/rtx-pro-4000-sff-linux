#!/usr/bin/env bash
# Apply the power limit and clock offsets ONLY when the VBIOS override is live, i.e. when the driver's
# max power limit reaches POWER_LIMIT_W. On a stock boot (new kernel, new driver, or no override) it
# leaves stock limits and zero offsets, so a failed override never runs a memory overclock at 70 W.
#
#   sudo ./scripts/gpu-power-profile.sh [/etc/rtx-power.conf]
set -u
CONF=${1:-/etc/rtx-power.conf}
# shellcheck source=/dev/null
. "$CONF" || { echo "cannot read $CONF"; exit 1; }
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
MAX=$(nvidia-smi -i "$GPU_INDEX" --query-gpu=power.max_limit --format=csv,noheader,nounits | cut -d. -f1)
if [ -n "$POWER_LIMIT_W" ] && [ "${MAX:-0}" -ge "$POWER_LIMIT_W" ]; then
  nvidia-smi -i "$GPU_INDEX" -pl "$POWER_LIMIT_W" && python3 "$HERE/../tools/nvml_offsets.py" -i "$GPU_INDEX" set "$GFX_OFFSET" "$MEM_OFFSET"
else
  echo "override not live (max limit ${MAX:-?} W): leaving stock limits and zero offsets"
fi
