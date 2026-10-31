# Operator's guide

These steps take you from a stock card to a persisted 90 W profile, then cover how to keep it working and how to undo it.
Every command runs as root. Read [FINDINGS.md](FINDINGS.md), especially the slot-power caveat, first.

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

1. Back up the full EEPROM. NVFlash `--save` and sysfs both fail to give it, so follow Piszczek's gdb method: capture NVFlash's read buffer twice and compare the SHA-256.
   Under Secure Boot, `/dev/mem` is blocked by lockdown. Lifting that once (`mokutil --disable-validation`, then MokManager) is your call. Turn it back on afterwards.
2. Slice one bank. On this card that is `[0x3c000:0x21c000]`, 1,966,080 bytes. The editor rejects the full two-bank dump.
3. Read the fields with `nvbios fields bank.rom`, then edit only the seven power fields:
   `nvbios edit bank.rom bank-90w.rom --set power_max_w=90 --set board_fixed_rated_w=90 --set slot_power_max_w=90 --set slot_power_rated_w=90 --set input_current_max_ma=8490 --set input_current_rated_ma=8490 --set input_current_policy7_limit_ma=8490`.
   Scale the three current values as `6600 x W / 70`.
4. Re-read every field, and confirm only those seven changed.
5. Normalize it into a loader payload: `nvbios normalize bank-90w.rom gpu0-90w.bin`.
6. Install it: `install -D -m 644 gpu0-90w.bin /lib/firmware/nvidia/<driver-version>/vbios-override/gpu0-90w.bin`.

**Never flash it.** It is only ever loaded into RAM.

## 3. Build and install the modules

```bash
./build/build-vix-modules.sh                   # ends BUILD-OK work/modules-<nv>-vix-<krel>; log work/build-<krel>.log
./scripts/install-vix-modules.sh work/modules-<nv>-vix-$(uname -r)   # ends INSTALL-OK <krel> -> .../extra/vix/nvidia.ko
```

- The build checks out NVIDIA's tag for your installed driver, applies the loader patch for that branch, builds with `KERNEL_UNAME`, verifies the vermagic, signs all five modules, and checks that the override strings are inside.
- The install verifies that each module is signed and built for the kernel, writes `extra/vix`, adds this kernel's `override` lines to `/etc/depmod.d/nvidia-vix.conf`, and checks that depmod now resolves `nvidia` there.

## 4. Configure

```bash
install -m 644 config/nvidia-vbios-override.conf.example /etc/modprobe.d/nvidia-vbios-override.conf
install -m 644 config/rtx-power.conf.example /etc/rtx-power.conf
```

- In the modprobe file, set `pci=`, `RmLinuxVbiosOverrideSize` (your image's size in bytes) and the image path.
- In `rtx-power.conf`, set `POWER_LIMIT_W`, `MEM_OFFSET`, `GFX_OFFSET`, and the users to stop.

Start at stock offsets and step up. Each step deserves a sustained load while you watch Xid errors, AER, temperature and output hashes.

## 5. Load it

Either reboot, or swap live:

```bash
./scripts/swap-live.sh && tail -12 /var/log/rtx-power.log
```

| Result | Meaning |
|---|---|
| `SWAP-OK` | Patched modules loaded, profile applied, users restarted |
| `SWAP-ROLLED-BACK` | The patched modules failed to load. The depmod file was restored and stock modules loaded |
| `SWAP-ABORTED` | A check failed before any unload, or something still held `/dev/nvidia*`. Users were restarted |

Then check by hand:

```bash
nvidia-smi --query-gpu=power.limit,power.max_limit,power.draw --format=csv   # 90.00 W, 90.00 W
python3 tools/nvml_offsets.py get                                            # mem P0/P2 = your offset
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
| Stock now | Stop the users, then `rmmod nvidia_drm nvidia_modeset nvidia_uvm nvidia`. Remove this kernel's lines from `/etc/depmod.d/nvidia-vix.conf`, run `depmod -a`, then `modprobe nvidia` |
| Stock at boot | Delete `/etc/modprobe.d/nvidia-vbios-override.conf` and reboot. The patched module without an image behaves as stock |
| Everything | Also delete `/etc/depmod.d/nvidia-vix.conf`, `/lib/modules/*/extra/vix`, the service, `/opt/rtx-power` and `/etc/rtx-power.conf`. Run `depmod -a` and reboot |

## Keep this current

Update this guide and FINDINGS when:
- the driver branch or the loader commit changes
- you re-measure at a new power level
- the build flags change
