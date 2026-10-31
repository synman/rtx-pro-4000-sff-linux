#!/usr/bin/env bash
# Build the NVIDIA open kernel modules with Panchovix's VBIOS override patch, for one kernel, and sign them.
#
#   sudo ./build/build-vix-modules.sh [workdir]          default workdir: ./work
#
# Env (all optional):
#   KREL         kernel release to build for (default: uname -r). Set it to build for an installed, not-yet-booted
#                kernel before you reboot into it.
#   NV_VERSION   NVIDIA driver version (default: the installed nvidia-kernel-open-dkms package version). The
#                modules must match the userspace driver exactly.
#   VIX_COMMIT   nvidia-linux-vbios-vix-loader commit (default: the one this repo was tested with)
#   MOK_KEY, MOK_CERT  signing key and certificate (default: Debian's DKMS key). The key is passed by path only.
# Output: <workdir>/modules-<NV_VERSION>-vix-<KREL>/{nvidia,nvidia-uvm,nvidia-modeset,nvidia-drm,nvidia-peermem}.ko, signed.
# Nothing is installed. Run scripts/install-vix-modules.sh next.
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO=$(cd "$HERE/.." && pwd -P)
WORK=$(mkdir -p "${1:-$REPO/work}" && cd "${1:-$REPO/work}" && pwd -P)
KREL=${KREL:-$(uname -r)}
NV_VERSION=${NV_VERSION:-$(dpkg-query -W -f='${Version}' nvidia-kernel-open-dkms 2>/dev/null | cut -d- -f1)}
VIX_COMMIT=${VIX_COMMIT:-418942a}
MOK_KEY=${MOK_KEY:-/var/lib/dkms/mok.key}
MOK_CERT=${MOK_CERT:-/var/lib/dkms/mok.pub}
SIGN=$(ls /usr/lib/linux-kbuild-*/scripts/sign-file 2>/dev/null | sort -V | tail -1)
PATCH=patches/${NV_VERSION%%.*}-vbios-override-per-gpu.patch

[ -n "$NV_VERSION" ] || { echo "cannot read the NVIDIA version; set NV_VERSION"; exit 1; }
[ -d "/lib/modules/$KREL/build" ] || { echo "no headers for $KREL; install linux-headers-$KREL"; exit 1; }
[ -x "$SIGN" ] || { echo "sign-file not found"; exit 1; }
echo "kernel $KREL, NVIDIA $NV_VERSION, vix-loader $VIX_COMMIT, patch $PATCH"

cd "$WORK"
[ -d nvidia-linux-vbios-vix-loader ] || git clone -q https://github.com/Panchovix/nvidia-linux-vbios-vix-loader.git
git -C nvidia-linux-vbios-vix-loader checkout -q "$VIX_COMMIT"
SRC=open-gpu-kernel-modules-$NV_VERSION
if [ ! -d "$SRC" ]; then
  git clone -q --depth 1 --branch "$NV_VERSION" https://github.com/NVIDIA/open-gpu-kernel-modules.git "$SRC"
  git -C "$SRC" apply --check "$PWD/nvidia-linux-vbios-vix-loader/$PATCH"
  git -C "$SRC" apply "$PWD/nvidia-linux-vbios-vix-loader/$PATCH"
fi
grep -q RmLinuxVbiosOverride "$SRC/src/nvidia/arch/nvalloc/unix/src/registry.c" || { echo "patch not in the tree"; exit 1; }

# Build the way DKMS does. SYSSRC=/usr/src/linux-headers-<krel> fails on Debian ("stdarg.h: No such file"),
# because Debian splits its headers into -common and -<flavour> packages; KERNEL_UNAME finds both.
( cd "$SRC" && make clean >/dev/null 2>&1; make modules -j"$(nproc)" KERNEL_UNAME="$KREL" \
    IGNORE_PREEMPT_RT_PRESENCE=1 IGNORE_XEN_PRESENCE=1 > "$WORK/build-$KREL.log" 2>&1 ) \
  || { tail -30 "$WORK/build-$KREL.log"; exit 1; }

OUT=$WORK/modules-$NV_VERSION-vix-$KREL
mkdir -p "$OUT"
for m in nvidia nvidia-uvm nvidia-modeset nvidia-drm nvidia-peermem; do
  cp "$SRC/kernel-open/$m.ko" "$OUT/$m.ko"
  [ "$(modinfo -F vermagic "$OUT/$m.ko" | awk '{print $1}')" = "$KREL" ] || { echo "$m vermagic mismatch"; exit 1; }
  "$SIGN" sha256 "$MOK_KEY" "$MOK_CERT" "$OUT/$m.ko"
done
strings "$OUT/nvidia.ko" > "$WORK/nvidia.strings"
grep -q RmLinuxVbiosOverride "$WORK/nvidia.strings" || { echo "built nvidia.ko lacks the override"; exit 1; }
sha256sum "$OUT"/*.ko
echo "BUILD-OK $OUT"
