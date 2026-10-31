# Findings on the reference card

These were measured on one RTX PRO 4000 Blackwell SFF (VBIOS `98.03.AA.00.02`, `10de:2c33`) in a Minisforum MS-02 Ultra,
in October 2026. Most profiles have one run each. Re-measure on your own system.

## The fields edited

The image is one bank sliced from the 4 MiB EEPROM dump, `[0x3c000:0x21c000]` (1,966,080 bytes). The editor accepts it
as `gb20x-object-directory-v3`, and its edit auto-repairs an object SHA-384, the directory SHA-384 and two additive checksums.
A full re-read of all 122 fields showed only these seven changed. No voltage field was touched.

| Field | Stock | 90 W image |
|---|---|---|
| `power_max_w` | 70 | 90 |
| `board_fixed_rated_w` | 70 | 90 |
| `slot_power_max_w` | 66 | 90 |
| `slot_power_rated_w` | 66 | 90 |
| `input_current_max_ma` | 6600 | 8490 |
| `input_current_rated_ma` | 6600 | 8490 |
| `input_current_policy7_limit_ma` | 6600 | 8490 |

The current limits scale with power: 6600 mA x 90 / 70. With the override live, `nvidia-smi` reports max_limit 90 W,
default stays 70 W, and `-pl 90` is accepted.

## Benchmark

The model was Qwen3.8-27B iMatrix NVFP4 with an MTP draft head, on llama.cpp CUDA at 262K context. Each run was 3 short
decodes of 768 tokens, then 3 cold 32K-token prefills, each followed by a 512-token decode. Results are means of 3.
Every run gave byte-identical output and logged no Xid or AER errors.

| Profile | Short decode tok/s | 32K prefill tok/s | Decode @32K tok/s | Core clock (decode) | Peak GPU temp |
|---|---|---|---|---|---|
| 70 W stock (avg of 2 runs) | 32.69 | 920.7 | 28.43 | ~970 MHz | 67-68 C |
| 70 W, memory +5% | 32.15 | 919.4 | 28.55 | 832 MHz | 69 C |
| 70 W, core +180 MHz | 32.83 | 934.1 | 28.77 | 1012 MHz | 68 C |
| 70 W, core +300 MHz | 33.03 | 930.0 | 28.73 | 1072 MHz | 67 C |
| 80 W | 34.95 | 1029.3 | 31.48 | 1485 MHz | 70 C |
| 90 W | 35.53 | 1109.4 | 32.76 | 1710 MHz | 73 C |
| 90 W, memory +10% | 38.80 | 1139.6 | 35.00 | 1582 MHz | 75 C |
| 90 W, memory +20% | 41.26 | 1158.9 | 36.64 | 1447 MHz | 74 C |

The 30-minute sustained runs were back-to-back cold 32K prefills, each followed by a 512-token decode:

| Limit | Requests | Prefill start → end | Decode | Peak temp | Avg power |
|---|---|---|---|---|---|
| 80 W | 38 | 1024 → 1019 tok/s (−0.5%) | 31.4 tok/s, flat | 75 C | ~79.5 W |
| 90 W | 40 | 1108 → 1089 tok/s (−1.7%) | 32.7 tok/s, flat | 77 C | 89.1 W |
| 100 W | 145 completions, 0 failed | — | — | 81 C (plateau 80 C from 5 min) | 99.3 W |

At 100 W against 90 W, on the same bench and model with memory +20% and ECC off, one run each side:
- 32K prefill +5.1%.
- 32K decode +0.5%.
- Short decode −2.3%.
- Decode power rose from 87.7 W to 97.4 W.

Decode is memory-bound by 90 W, so 100 W buys prefill only. The kept profile is 90 W.

## What I learned

- **At 70 W the card is power-capped the whole time.** The core sags to about 1 GHz under load. A memory offset at 70 W just takes watts from the core.
- **Power first, then memory.** Going from 70 W to 90 W gave +20% prefill. At 90 W, a +20% memory offset added +12% decode while the core clock fell 15%.
- **NVML memory offsets are in double-data-rate units.** +1800 is about +10% and +3600 about +20%. The kept +3599 reads 10800 MHz.
- **VRAM ECC can be turned on live,** with `nvidia-smi -e 1`, then unloading `nvidia_drm` and `nvidia_modeset`, `nvidia-smi -r`, and reloading. The override survived the GPU reset. In about seven hours of real load at 90 W with ECC on, it showed 0 corrected and 0 uncorrected errors. ECC was then turned off again for benchmarking, and the card runs with it off.

## Traps

- **A kernel update silently drops the override.** There is no apt or DKMS hook. DKMS rebuilds the stock modules for the new kernel, and the vix modules exist only for the old one. The card boots at 70 W, and `gpu-power-profile.sh` logs "override not live". Build for the new kernel BEFORE rebooting into it: `KREL=<new> ./build/build-vix-modules.sh`, then install.
- **Build with `KERNEL_UNAME`, not `SYSSRC`.** On Debian, `SYSSRC=/usr/src/linux-headers-<krel>` fails with `stdarg.h: No such file`, because the headers are split into `-common` and `-amd64`. DKMS uses `KERNEL_UNAME`.
- **The depmod override needs a `search` line.** `override nvidia <krel> extra/vix` alone does nothing, because depmod never indexes `extra/` without `search extra/vix updates built-in`.
- **Anything with `/dev/nvidia*` open blocks `rmmod`,** including an interactive `btop` in an SSH session. List the holders from `/proc/*/fd` first.
- **The running image outlives a config change.** After switching the modprobe option back from a 100 W image to 90 W, the 100 W image stays loaded and max_limit reads 100 W until the next module reload or boot. Set `-pl` to enforce the lower limit in the meantime.
- **The EEPROM backup.** NVFlash `--save` wrote a 0-byte file, and sysfs gives only the 162,304-byte option ROM. The full 4 MiB came from NVFlash's read buffer under gdb, as Piszczek describes. Under Secure Boot that read needs `/dev/mem`, which lockdown blocks, so I disabled shim validation once (`mokutil --disable-validation`), read the chip, and re-enabled it. Two reads matched byte for byte.
- **NVIDIA's patch tracks the driver version.** The loader patch is per driver branch (`615-…`). A driver update needs the matching patch and a rebuild.

## The slot-power caveat

- The card has no auxiliary connector. Minisforum states only "standard 75W PCIe slot power" per slot, with no margin figure, and the root port declares `SltCap PowerLimit 75W`.
- The PCIe CEM spec allows 5.5 A on the slot's 12 V pins, which is 66 W. 80 W is about 6.7 A and 90 W about 7.5 A, roughly 1.2x and 1.4x the spec.
- With an IR thermometer on the slot surface at 80 W, I read about 35 C at one end and 55 C at the end beside the CPU cooler. That was one reading, of surface temperature, not pin temperature.
- I would not run 106 W or 120 W slot-only in a mini PC. On a desktop board the margin may differ, but it is still unpublished.
