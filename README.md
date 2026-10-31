# RTX PRO 4000 Blackwell SFF on Linux: power limit above 70 W, persisted safely

Scripts and notes for running an NVIDIA RTX PRO 4000 Blackwell SFF above its 70 W firmware cap on Debian with Secure Boot on.
The card reads an edited VBIOS image from system RAM at driver load, and the EEPROM is never flashed.
The pieces here make that survive reboots and fall back to stock safely. A kernel update needs one rebuild before you reboot into it.

Maintained by synman. Tested on Debian 13 with NVIDIA's apt-repo driver `615.71.10`, kernels `7.2.9` and `7.2.11` from trixie-backports, Secure Boot on.
`build-vix-modules.sh` was run from this repo on that host and produced signed modules carrying the override.
`install-vix-modules.sh` and `swap-live.sh` repeat the steps done by hand there, but these exact versions have not yet been run.

> **Warning.** This card has no auxiliary power connector, so everything above 70 W comes through the PCIe slot.
> The slot is specified for 75 W. 90 W is about 7.5 A on 12 V against a 5.5 A pin budget. You own that risk.
> Read [docs/FINDINGS.md](docs/FINDINGS.md) first. **Never flash an edited VBIOS.** It carries a mismatched signature.

## What this repo is, and what it is not

The method is not mine. Michał Piszczek mapped the seven VBIOS power fields and showed it working at 120 W.
Panchovix wrote the loader patch for the NVIDIA open kernel modules, and the editor that writes and normalizes the image.
See [NOTICE.md](NOTICE.md). This repo adds what it took to run that on a Debian server and keep it running:

| Addition | Where |
|---|---|
| Build the patched open modules for any installed kernel, the way DKMS does, and sign them with your MOK | `build/build-vix-modules.sh` |
| Install them so they win over the stock DKMS build on that kernel only | `scripts/install-vix-modules.sh` |
| Swap them in live, with no reboot, and roll back to stock if loading fails | `scripts/swap-live.sh` |
| Apply the power limit and memory offset at boot only when the override is actually live, so a stock boot never runs an overclock at 70 W | `scripts/gpu-power-profile.sh`, `systemd/gpu-power-profile.service` |
| Read and set clock offsets through NVML | `tools/nvml_offsets.py` |
| A modprobe.d template for the image, and the config | `config/` |
| Measured results, the slot-power caveat, and the traps that cost me time | `docs/FINDINGS.md` |

**Not included, on purpose:** VBIOS images, original or edited. They are NVIDIA's firmware, and an edited image that
gets flashed can brick a card. Make your own from your own card, as the guide shows.

## Prerequisites

- Debian with NVIDIA's apt-repo open driver (`nvidia-kernel-open-dkms`), and headers for every kernel you build for.
- Under Secure Boot: an enrolled MOK. Debian's DKMS key at `/var/lib/dkms/mok.key` works.
- An edited, normalized VBIOS image for YOUR card. See [docs/OPERATORS-GUIDE.md](docs/OPERATORS-GUIDE.md), section 2.
- `git`, `make`, `gcc` matching the kernel's compiler, `linux-kbuild` (for `sign-file`), `binutils` (for `strings`) and network access for the build.
- `nvidia-persistenced`, which the profile service runs after.
- Panchovix's [Vix Editor](https://github.com/Panchovix/nvidia-vbios-vix-editor) (`nvbios`), to make the image.

## Quick start

Run as root (`sudo -i`), so variables like `KREL=` reach the scripts:

```bash
./build/build-vix-modules.sh                       # ends BUILD-OK <abs-path>/work/modules-<nv>-vix-<krel>
./scripts/install-vix-modules.sh work/modules-*-vix-$(uname -r)
install -D -m 644 gpu0-90w.bin /lib/firmware/nvidia/<nv-version>/vbios-override/gpu0-90w.bin
install -m 644 config/nvidia-vbios-override.conf.example /etc/modprobe.d/nvidia-vbios-override.conf   # edit pci= (twice), Size and the path
install -m 644 config/rtx-power.conf.example /etc/rtx-power.conf                                     # set POWER_LIMIT_W, offsets, users
./scripts/swap-live.sh; tail -12 /var/log/rtx-power.log   # ends SWAP-OK; or just reboot
```

Then copy the repo to `/opt/rtx-power` and enable `systemd/gpu-power-profile.service`.
[docs/OPERATORS-GUIDE.md](docs/OPERATORS-GUIDE.md) has every step, the checks, and the rollback.

## Results in one line

On Qwen3.8-27B NVFP4 with llama.cpp: 90 W plus a +20% memory offset gave +26% short decode, +26% 32K prefill and
+29% decode at 32K over stock 70 W. GPU peak 74-77 C, no Xid or AER errors, byte-identical outputs. 100 W added only prefill.
Full tables: [docs/FINDINGS.md](docs/FINDINGS.md). Write-up: https://www.shellware.com/post/2026/10/27/ms-02-ultra-rtx-pro-4000-sff-power-scaling-70w-to-90w/

## Layout

| Path | What it is |
|---|---|
| `build/build-vix-modules.sh` | Clone, patch, build and sign for one kernel |
| `scripts/install-vix-modules.sh` | Install for one kernel plus the depmod override |
| `scripts/swap-live.sh` | Live module swap with rollback |
| `scripts/gpu-power-profile.sh` | The guarded boot-time profile |
| `systemd/gpu-power-profile.service` | Runs it after `nvidia-persistenced` |
| `config/` | `rtx-power.conf.example`, `nvidia-vbios-override.conf.example` |
| `tools/nvml_offsets.py` | NVML clock offsets, P0 and P2 |
| `docs/` | Findings and the operator's guide |

## Undo

See the rollback table in [docs/OPERATORS-GUIDE.md](docs/OPERATORS-GUIDE.md), section 8. In short, remove the
modprobe.d file, the depmod.d file and every `extra/vix`, rerun depmod for each kernel, and reboot.
The card is back to stock 70 W, because nothing was ever written to it.

## License

The scripts and docs are MIT ([LICENSE](LICENSE)). The build fetches the NVIDIA open modules (MIT/GPL-2.0 dual) and
Panchovix's patch (GPL-3.0) at build time. Neither is redistributed here. See [NOTICE.md](NOTICE.md).
