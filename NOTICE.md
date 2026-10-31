# Attribution

This repo ships only its own scripts and notes. The build fetches everything else at build time, and nothing
below is redistributed here.

| Piece | Author and source | License | How this repo uses it |
|---|---|---|---|
| The method: which seven VBIOS power fields to edit, the in-memory override, the gdb backup of the EEPROM, the 120 W measurements | Michał Piszczek, https://piszczek.pl/blog/rtx-pro-4000-blackwell-sff-120w-qwen-benchmark | — | Followed, and cited in the findings |
| NVIDIA VBIOS Vix Loader: the `615-vbios-override-per-gpu.patch` for the open kernel modules, which reads an image from a per-GPU registry option and passes it to the GSP | Panchovix, https://github.com/Panchovix/nvidia-linux-vbios-vix-loader | GPL-3.0 | Fetched at commit `418942a` and applied by `build/build-vix-modules.sh` |
| NVIDIA VBIOS Vix Editor (`nvbios fields`, `edit`, `normalize`) | Panchovix, https://github.com/Panchovix/nvidia-vbios-vix-editor | See its repo | Used by hand to make the image. Not bundled |
| NVIDIA open GPU kernel modules | NVIDIA, https://github.com/NVIDIA/open-gpu-kernel-modules | MIT / GPL-2.0 dual | Fetched at the tag matching the installed driver |
| NVML (`nvmlDeviceSetClockOffsets`) | NVIDIA, part of the driver | NVIDIA driver license | Called through `ctypes` by `tools/nvml_offsets.py` |

Everything in this repo was written for it by synman under MIT: `build/`, `scripts/`, `systemd/`, `config/`, `tools/`
and `docs/`. It covers the Debian build path, per-kernel install, the live swap, the guarded profile, and the findings.
