# Operator's guide

These steps take you from a stock card to a persisted 90 W profile, then cover how to keep it working and how to undo it.
Every command runs in a root shell (`sudo -i`): `KREL=x sudo ./build…` would lose `KREL`. Read [FINDINGS.md](FINDINGS.md), especially the slot-power caveat, first.

## 1. Preflight

```bash
lspci -D -nn -d 10de:                         # the card's PCI address, e.g. 0000:02:00.0
nvidia-smi --query-gpu=name,driver_version,power.max_limit,vbios_version --format=csv
dpkg-query -W nvidia-kernel-open-dkms         # the open driver from NVIDIA's apt repo
mokutil --sb-state; ls /var/lib/dkms/mok.key /var/lib/dkms/mok.pub
ls -d /lib/modules/$(uname -r)/build          # headers for this kernel
```

If the card drives your display, stop here. The live swap unloads its driver.

## 2. Make your own image (once per card)

The guide does not ship images. Make one from your own card with Panchovix's Vix Editor (`nvbios`).

Get the editor from https://github.com/Panchovix/nvidia-vbios-vix-editor and follow its install steps.

1. Back up the full EEPROM. NVFlash `--save` and sysfs both fail to give it, so follow Piszczek's gdb method: capture NVFlash's read buffer twice and compare the SHA-256.
   Under Secure Boot, `/dev/mem` is blocked by lockdown. Lifting that once is your call: `mokutil --disable-validation`, reboot, confirm in MokManager.
   Turn it back on afterwards with `mokutil --enable-validation`, reboot and confirm again. Check with `mokutil --sb-state`.
2. Slice one bank. On this card that is `[0x3c000:0x21c000]`, 1,966,080 bytes. The editor rejects the full two-bank dump.
3. Read the fields with `nvbios fields bank.rom`, then edit only the seven power fields:
   `nvbios edit bank.rom bank-90w.rom --set power_max_w=90 --set board_fixed_rated_w=90 --set slot_power_max_w=90 --set slot_power_rated_w=90 --set input_current_max_ma=8490 --set input_current_rated_ma=8490 --set input_current_policy7_limit_ma=8490`.
   Scale the three current values as `6600 x W / 70`, rounded up to a multiple of 10: 8485.7 becomes 8490.
4. Re-read every field, and confirm only those seven changed.
5. Normalize it into a loader payload: `nvbios normalize bank-90w.rom gpu0-90w.bin`.
6. Install it: `install -D -m 644 gpu0-90w.bin /lib/firmware/nvidia/<driver-version>/vbios-override/gpu0-90w.bin`.

**Never flash it.** It is only ever loaded into RAM.

## 3. Build and install the modules

```bash
./build/build-vix-modules.sh                   # ends BUILD-OK <abs-path>/work/modules-<nv>-vix-<krel>; log work/build-<krel>.log
./scripts/install-vix-modules.sh work/modules-<nv>-vix-$(uname -r)   # ends INSTALL-OK <krel> -> .../extra/vix/nvidia.ko
```

- The build checks out NVIDIA's tag for your installed driver, applies the loader patch for that branch, builds with `KERNEL_UNAME`, verifies the vermagic, signs all five modules, and checks that the override strings are inside.
- The install verifies that each module is signed and built for the kernel, writes `extra/vix`, adds this kernel's `override` lines to `/etc/depmod.d/nvidia-vix.conf`, and checks that depmod now resolves `nvidia` there.

## 4. Configure

```bash
install -m 644 config/nvidia-vbios-override.conf.example /etc/modprobe.d/nvidia-vbios-override.conf
install -m 644 config/rtx-power.conf.example /etc/rtx-power.conf
```

- In the modprobe file, set `pci=` on both lines, `RmLinuxVbiosOverrideSize` (`stat -c %s` of your image) and the image path, replacing `<driver-version>`. Nothing checks these. A wrong value shows up as `SWAP-NOT-LIVE`.
- In `rtx-power.conf`, set `GPU_INDEX`, `POWER_LIMIT_W`, `MEM_OFFSET`, `GFX_OFFSET`, and the users to stop: `STOP_CONTAINERS`, `STOP_SERVICES`, `KILL_COMMS`, `HEALTH_CONTAINER`. The example ships no overclock.

Start at stock offsets and step up. Each step deserves a sustained load while you watch Xid errors, AER, temperature and output hashes.

## 5. Load it

Either reboot, or swap live:

```bash
./scripts/swap-live.sh; tail -12 /var/log/rtx-power.log
```

| Result | Meaning |
|---|---|
| `SWAP-OK` | Patched modules loaded, max_limit reached `POWER_LIMIT_W`, profile applied, users restarted |
| `SWAP-NOT-LIVE` | Patched modules loaded, but the image did not raise max_limit. Check the modprobe file. The profile stayed stock |
| `SWAP-ROLLED-BACK` | The patched modules failed to load. This kernel's override lines were removed, a backup kept, and stock loaded |
| `SWAP-ABORTED` | A check failed, something still held `/dev/nvidia*`, or `rmmod nvidia` failed. Anything unloaded was loaded again and users restarted |

The script writes only to the log. All four outcomes except `SWAP-OK` exit 1.

Then check by hand:

```bash
nvidia-smi --query-gpu=power.limit,power.max_limit,power.draw --format=csv   # limit and max_limit 90.00 W
python3 tools/nvml_offsets.py -i 0 get                                       # mem P0/P2 = your offset
dmesg | grep -E "NVRM: Xid|AER" | tail
```

## 6. Persist

```bash
mkdir -p /opt/rtx-power && cp -r scripts tools /opt/rtx-power/
install -m 644 systemd/gpu-power-profile.service /etc/systemd/system/
systemctl daemon-reload && systemctl enable gpu-power-profile.service
```

How a boot works:
1. depmod already prefers the vix modules for this kernel.
2. The modprobe.d file passes the image.
3. After `nvidia-persistenced` starts, the service applies the limit and offsets, but only if max_limit reached `POWER_LIMIT_W`.

Check after a reboot with `journalctl -b -u gpu-power-profile` and the commands in section 5.

## 7. Kernel and driver updates

**Before rebooting into a new kernel,** install its headers and build for it:

```bash
KREL=<new-krel> ./build/build-vix-modules.sh
./scripts/install-vix-modules.sh work/modules-<nv>-vix-<new-krel> <new-krel>
```

Skip this, and the new kernel boots at stock 70 W. That is safe, because the profile does not apply, but the gain is gone until you rebuild.

**After an NVIDIA driver update,** rebuild for the new version. If the version changes branch, you need the loader's patch for that branch. Also move the image into `/lib/firmware/nvidia/<new-version>/vbios-override/` and fix the modprobe path.

## 8. Roll back

| To | Do |
|---|---|
| Stock now | Stop the users. `rmmod nvidia_peermem nvidia_drm nvidia_modeset nvidia_uvm nvidia`, ignoring "not loaded". Delete this kernel's lines: `sed -i "/ $(uname -r) extra\/vix$/d" /etc/depmod.d/nvidia-vix.conf`. Run `depmod -a`, then `modprobe` each of `nvidia nvidia_uvm nvidia_modeset nvidia_drm`, and restart the users |
| Stock at boot | Delete `/etc/modprobe.d/nvidia-vbios-override.conf` and reboot. With no image the patched module loads at stock 70 W, as observed on the reference card |
| Everything | Do the table's first row or reboot, then run the block below |

```bash
systemctl disable --now gpu-power-profile.service
rm -f /etc/systemd/system/gpu-power-profile.service && systemctl daemon-reload
rm -f /etc/modprobe.d/nvidia-vbios-override.conf /etc/depmod.d/nvidia-vix.conf /etc/depmod.d/nvidia-vix.conf.bak-*
rm -rf /lib/modules/*/extra/vix /opt/rtx-power /etc/rtx-power.conf /lib/firmware/nvidia/*/vbios-override
for k in /lib/modules/*/; do k=${k%/}; k=${k##*/}; [ -e "/lib/modules/$k/modules.dep" ] && depmod -a "$k"; done
rm -f /var/log/rtx-power.log    # optional; also delete the repo's work/ clones
reboot
```

The `vbios-override` folder holds your image. Keep a copy first if you want it again.

## Keep this current

Update this guide and FINDINGS when:
- the driver branch or the loader commit changes
- you re-measure at a new power level
- the build flags change
