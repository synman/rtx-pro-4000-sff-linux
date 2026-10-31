#!/usr/bin/env python3
"""Read or set GPU clock offsets via NVML (stock firmware). Usage: nvml_offsets.py get | set <gfx_mhz> <mem_mhz>"""
import ctypes as C, sys

nv = C.CDLL("libnvidia-ml.so.1")
GFX, MEM = 0, 2           # NVML_CLOCK_GRAPHICS, NVML_CLOCK_MEM
PSTATES = (0, 2)          # P0 and P2, as the maker set both


class Off(C.Structure):
    _fields_ = [("version", C.c_uint), ("type", C.c_int), ("pstate", C.c_int),
                ("clockOffsetMHz", C.c_int), ("minClockOffsetMHz", C.c_int), ("maxClockOffsetMHz", C.c_int)]


VER = C.sizeof(Off) | (1 << 24)


def ck(rc, what):
    if rc != 0:
        s = nv.nvmlErrorString; s.restype = C.c_char_p
        sys.exit(f"{what}: {s(rc).decode()} ({rc})")


ck(nv.nvmlInit_v2(), "init")
dev = C.c_void_p(); ck(nv.nvmlDeviceGetHandleByIndex_v2(0, C.byref(dev)), "handle")


def get(t, p):
    o = Off(version=VER, type=t, pstate=p); ck(nv.nvmlDeviceGetClockOffsets(dev, C.byref(o)), "get")
    return o


if sys.argv[1:2] == ["get"]:
    for t, n in ((GFX, "gfx"), (MEM, "mem")):
        for p in PSTATES:
            o = get(t, p); print(f"{n} P{p}: offset {o.clockOffsetMHz} MHz, range {o.minClockOffsetMHz}..{o.maxClockOffsetMHz}")
elif sys.argv[1:2] == ["set"] and len(sys.argv) == 4:
    want = {GFX: int(sys.argv[2]), MEM: int(sys.argv[3])}
    for t in (GFX, MEM):
        for p in PSTATES:
            o = get(t, p)
            if not o.minClockOffsetMHz <= want[t] <= o.maxClockOffsetMHz:
                sys.exit(f"out of range: type {t} P{p} wants {want[t]}, allowed {o.minClockOffsetMHz}..{o.maxClockOffsetMHz}")
            o.clockOffsetMHz = want[t]; ck(nv.nvmlDeviceSetClockOffsets(dev, C.byref(o)), f"set type {t} P{p}")
            print(f"type {t} P{p}: readback {get(t, p).clockOffsetMHz} MHz")
else:
    sys.exit(__doc__)
