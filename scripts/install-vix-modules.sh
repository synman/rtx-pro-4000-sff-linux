#!/usr/bin/env bash
# Install signed vix modules for one kernel so they win over the stock DKMS build on that kernel only.
#
#   sudo ./scripts/install-vix-modules.sh <module-dir> [krel]
#
# <module-dir> is build-vix-modules.sh's output. krel defaults to the vermagic of the modules.
# Writes /lib/modules/<krel>/extra/vix/*.ko and override lines in /etc/depmod.d/nvidia-vix.conf, then runs depmod.
# Other kernels keep their own lines and modules. Nothing is loaded; reboot, or run swap-live.sh.
# Undo for one kernel: delete its override lines and /lib/modules/<krel>/extra/vix, then depmod -a <krel>.
set -euo pipefail
DIR=$1
KREL=${2:-$(modinfo -F vermagic "$DIR/nvidia.ko" | awk '{print $1}')}
DST=/lib/modules/$KREL/extra/vix
CONF=/etc/depmod.d/nvidia-vix.conf
MODS="nvidia nvidia-uvm nvidia-modeset nvidia-drm nvidia-peermem"
for m in $MODS; do
  [ "$(modinfo -F vermagic "$DIR/$m.ko" | awk '{print $1}')" = "$KREL" ] || { echo "$m is not for $KREL"; exit 1; }
  [ -n "$(modinfo -F signer "$DIR/$m.ko")" ] || { echo "$m is unsigned"; exit 1; }
done
mkdir -p "$DST"
for m in $MODS; do install -m 644 "$DIR/$m.ko" "$DST/$m.ko"; done
if [ ! -f "$CONF" ]; then
  printf '# Patched NVIDIA open modules (VBIOS override loader) win over the stock DKMS build,\n# per kernel. depmod never indexes extra/ without the search line.\nsearch extra/vix updates built-in\n' > "$CONF"
fi
cp -p "$CONF" "$CONF.bak-$(date +%Y%m%d%H%M%S)"
for m in $MODS; do grep -q "^override $m $KREL extra/vix$" "$CONF" || echo "override $m $KREL extra/vix" >> "$CONF"; done
depmod -a "$KREL"
R=$(modinfo -k "$KREL" -n nvidia)
[ "$R" = "$DST/nvidia.ko" ] || { echo "depmod resolves nvidia to $R, not $DST/nvidia.ko"; exit 1; }
echo "INSTALL-OK $KREL -> $R"
