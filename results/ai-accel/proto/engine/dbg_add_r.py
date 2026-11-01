# -*- coding: utf-8 -*-
"""对比 add_r_8ch_a 的 golden vs 实际写 (从 TB 日志 TBWR 数据反推)。"""
import io
import re

base = "vec_v3extra/"
n = "add_r_8ch_a"
NA, NB = 0x60000, 0x78000


def load8(path):
    d = {}
    for ln in io.open(path):
        a = ln.split()
        if len(a) < 3:
            continue
        idx = int(a[0], 16)
        hi = int(a[1], 16)
        lo = int(a[2], 16)
        for k in range(8):
            d[idx * 8 + k] = (lo >> (8 * k)) & 0xFF
    return d


src = load8(base + n + ".a.wr")
dst = load8(base + n + ".b.wr")
q = load8(base + n + ".wq.wr") if False else None
# Q 从 wq.wr 取 32 位字
qw = {}
for ln in io.open(base + n + ".wq.wr"):
    a = ln.split()
    off = int(a[0], 16)
    wd = int(a[1], 16)
    for k in range(4):
        qw[off + k] = (wd >> (8 * k)) & 0xFF

zp_s = qw[0x50100] if 0x50100 in qw else qw[min(qw)]
# Q 区从 0x50100 开始 (qoff=0x200)
qbase = 0x50000 + 0x200
zps = qw[qbase]
zpd = qw[qbase + 1]
R = qw[qbase + 2] | (qw[qbase + 3] << 8)
KADD = qw[qbase + 4]
print("zp_s", zps, "zp_d", zpd, "R", R, "KADD", KADD)


def s8(v):
    return v - 256 if v >= 128 else v


got_w0 = bytes.fromhex("8dc3 1055 8034 014c" .replace(" ", ""))
print("got word0", [hex(b) for b in got_w0])
# pixel0 = word0 ; golden
print("src0", [s8(src[i]) for i in range(8)])
print("dst0", [s8(dst[i]) for i in range(8)])
g = []
for ch in range(8):
    v = (s8(src[ch]) - s8(zps)) * R
    v = v >> KADD
    v = v + s8(dst[ch])
    v = max(-128, min(127, v))
    g.append(v & 0xFF)
print("golden0", [hex(b) for b in g])
