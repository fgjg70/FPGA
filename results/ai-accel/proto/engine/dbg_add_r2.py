# -*- coding: utf-8 -*-
"""对比 add_r_8ch_a: 重新正确解析 hi/lo, 对比 golden 与 TB 实际写数据。"""
import io

base = "vec_v3extra/"
n = "add_r_8ch_a"


def load8(path):
    d = {}
    for ln in io.open(path):
        a = ln.split()
        if len(a) < 3:
            continue
        idx = int(a[0], 16)
        hi = int(a[1], 16)
        lo = int(a[2], 16)
        for k in range(4):
            d[idx * 8 + k] = (lo >> (8 * k)) & 0xFF
            d[idx * 8 + 4 + k] = (hi >> (8 * k)) & 0xFF
    return d


qw = {}
for ln in io.open(base + n + ".wq.wr"):
    a = ln.split()
    off = int(a[0], 16)
    wd = int(a[1], 16)
    for k in range(4):
        qw[off + k] = (wd >> (8 * k)) & 0xFF

src = load8(base + n + ".a.wr")
dst = load8(base + n + ".b.wr")
exp = load8(base + n + ".bexp.wr")
qbase = 0x50000 + 0x200
zps = qw[qbase]
zpd = qw[qbase + 1]
R = qw[qbase + 2] | (qw[qbase + 3] << 8)
KADD = qw[qbase + 4]
print("zp_s", zps - 256 if zps >= 128 else zps, "zp_d", zpd, "R", R, "KADD", KADD)


def s8(v):
    return v - 256 if v >= 128 else v


# 实际 TB 写 (前 6 次, 从日志手抄): word0/1/2
got = {
    0: bytes.fromhex("4c01803410558dc3")[::-1],   # low 64 of TBWR[0] little endian
    1: bytes.fromhex("c4049049fcaf60d5")[::-1],
    2: bytes.fromhex("7f5088a4ec93f28c")[::-1],
}
for w in range(3):
    s = [s8(src[w * 8 + i]) for i in range(8)]
    d = [s8(dst[w * 8 + i]) for i in range(8)]
    g = []
    for ch in range(8):
        v = (s[ch] - s8(zps)) * R
        v = v >> KADD
        v = v + d[ch]
        v = max(-128, min(127, v))
        g.append(v & 0xFF)
    e = [exp[w * 8 + i] for i in range(8)]
    print("word", w)
    print("  src ", s)
    print("  dst ", d)
    print("  gold", [x - 256 if x >= 128 else x for x in g])
    print("  exp ", [x - 256 if x >= 128 else x for x in e])
    if w in got:
        print("  got ", [x - 256 if x >= 128 else x for x in got[w]])
