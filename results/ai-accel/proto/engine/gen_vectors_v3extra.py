# -*- coding: utf-8 -*-
"""v3 增量向量: PACKED3 (conv0) + ADD_R 用例 (独立于 gen_vectors.py; 不依赖 RTL)。
语义唯一来源 CONTRACT §5/§6/§8/§11 + v0.7 SPEC §2。

用法: python gen_vectors_v3extra.py
输出: results/ai-accel/proto/engine/vec_v3extra/
  manifest.txt  (14 列: name op flags ks st pad ih iw ic oc src dst woff qoff)
  <name>.wq.wr / .a.wr / .b.wr / .aexp.wr / .bexp.wr
"""
import os
import random

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "vec_v3extra")
os.makedirs(OUT, exist_ok=True)

# ---- nn_pkg 常量 (现场解析, 不手写死) ----
import re
pkg = open(os.path.join(HERE, "..", "..", "..", "..", "nn_pkg.sv"), encoding="utf-8", errors="ignore").read()


def pint(name):
    m = re.search(r"localparam\s+(?:logic\s*\[31:0\]\s+|int\s+unsigned\s+)" + name +
                  r"\s*=\s*(32'h[0-9A-Fa-f_]+|[0-9]+\*1024|[0-9]+)", pkg)
    assert m, name
    t = m.group(1).replace("_", "")
    if t.startswith("32'h"):
        return int(t[4:], 16)
    if "*" in t:
        a, b = t.split("*")
        return int(a) * int(b)
    return int(t)


NQ = pint("NN_Q_OFF")
NW = pint("NN_W_OFF")
NA = pint("NN_A_OFF")
NB = pint("NN_B_OFF")

rng = random.Random(0x5EED)


def s8():
    return rng.randint(-128, 127)


def pad8(c):
    return ((c + 7) // 8) * 8


# ---------------------------------------------------------------- 基本打包
class Case:
    def __init__(self, name, op, flags, ks, st, pad, ih, iw, ic, oc, src, dst):
        self.name = name
        self.op = op
        self.flags = flags
        self.ks = ks
        self.st = st
        self.pad = pad
        self.ih = ih
        self.iw = iw
        self.ic = ic
        self.oc = oc
        self.src = src
        self.dst = dst
        self.woff = 0
        self.qoff = 0
        self.w_bytes = {}     # byte offset -> int (within W region)
        self.q_bytes = {}
        self.a_img = {}       # byte -> int, absolute window offset
        self.b_img = {}
        self.a_exp = {}
        self.b_exp = {}

    def put_w(self, off, data):
        for i, b in enumerate(data):
            self.w_bytes[off + i] = b & 0xFF

    def put_q(self, off, data):
        for i, b in enumerate(data):
            self.q_bytes[off + i] = b & 0xFF

    def put_ab(self, img, off, data):
        for i, b in enumerate(data):
            img[off + i] = b & 0xFF


def i32(v):
    return [(v >> (8 * i)) & 0xFF for i in range(4)]


def i16(v):
    return [(v >> (8 * i)) & 0xFF for i in range(2)]


def requant(acc, mpos, leaky, shift, zp_out):
    if acc >= 0:
        y = acc * mpos
    else:
        mneg = ((mpos * 3277 + 16384) >> 15) if leaky else mpos
        y = acc * mneg
    y >>= shift
    y += zp_out
    return max(-128, min(127, y))


def emit(case, aexp_pixels, bexp_pixels):
    """写向量文件: aexp/bexp 以 64 位字 (idx hi lo) 形式。"""
    n = case.name
    # manifest
    with open(os.path.join(OUT, n + ".man"), "w", encoding="ascii") as f:
        pass
    # wq
    words = {}
    for off, b in case.w_bytes.items():
        words.setdefault((NW + off) >> 2, [0, 0, 0, 0])[((NW + off) >> 2, (NW + off) & 3) and 0] = 0
    # 简化: 重新按字节聚合
    agg = {}
    for off, b in case.w_bytes.items():
        a = NW + off
        agg.setdefault(a >> 2, 0)
        agg[a >> 2] |= (b & 0xFF) << (8 * (a & 3))
    for off, b in case.q_bytes.items():
        a = NQ + off
        agg.setdefault(a >> 2, 0)
        agg[a >> 2] |= (b & 0xFF) << (8 * (a & 3))
    with open(os.path.join(OUT, n + ".wq.wr"), "w", encoding="ascii") as f:
        for a in sorted(agg):
            f.write("%05x %08x\n" % ((a * 4) & 0xFFFFF, agg[a]))
    # a/b 装载 + 期望
    def dump(imgs, tag, base):
        words = {}
        for a, b in imgs.items():
            rel = a - base
            w = rel >> 3
            hi = (rel & 4) != 0
            words.setdefault(w, [0, 0])
            words[w][1 if hi else 0] |= (b & 0xFF) << (8 * (rel & 3))
        with open(os.path.join(OUT, "%s.%s.wr" % (n, tag)), "w", encoding="ascii") as f:
            for w in sorted(words):
                f.write("%04x %08x %08x\n" % (w & 0xFFFF, words[w][1], words[w][0]))

    dump(case.a_img, "a", NA)
    dump(case.b_img, "b", NB)
    dump(case.a_exp, "aexp", NA)
    dump(case.b_exp, "bexp", NB)
    return (n, case.op, case.flags, case.ks, case.st, case.pad, case.ih, case.iw,
            case.ic, case.oc, case.src, case.dst, NW + case.woff, NQ + case.qoff)


# ---------------------------------------------------------------- PACKED3 conv0
def gen_packed3():
    ih = iw = 16
    ks, st, pad = 3, 2, 1
    oc = 8
    ic = 3
    ic8 = pad8(ic)
    oc8 = pad8(oc)
    oh = (ih + 2 * pad - ks) // st + 1
    ow = (iw + 2 * pad - ks) // st + 1
    name = "packed3_conv0_k3s2"
    c = Case(name, 0, 0x20, ks, st, pad, ih, iw, ic, oc, NA + 0x0, NB + 0x0)
    c.woff = 0x4000
    c.qoff = 0x100
    zp_in = 0          # 简化: padding 用 0, 金标准也 0
    zp_out = rng.randint(-5, 5)
    shift = 18
    mpos = rng.randint(3000, 20000)
    leaky = 1

    # 权重: [tap][ic8][oc8] (ic>=3 全 0)
    w = [[[0] * oc8 for _ in range(ic8)] for _ in range(ks * ks)]
    for tap in range(ks * ks):
        for i in range(ic):
            for o in range(oc):
                w[tap][i][o] = s8()
    wbytes = []
    for tap in range(ks * ks):
        for i in range(ic8):
            for o in range(oc8):
                wbytes.append(w[tap][i][o])
    c.put_w(c.woff, wbytes)

    # Q: bias int32[oc8], M_pos int16[oc8], tail 16B
    bias = [rng.randint(-5000, 5000) for _ in range(oc8)]
    qb = []
    for o in range(oc8):
        qb += i32(bias[o])
    for o in range(oc8):
        qb += i16(mpos if o < oc else 0)
    tail = [zp_out & 0xFF, zp_in & 0xFF, leaky, shift] + [0] * 12
    qb += tail
    c.put_q(c.qoff, qb)

    # 输入: packed 3B/px
    img = [[[rng.randint(-128, 127) for _ in range(ic)] for _ in range(iw)] for _ in range(ih)]
    flat = []
    for y in range(ih):
        for x in range(iw):
            for ch in range(ic):
                flat.append(img[y][x][ch])
    c.put_ab(c.a_img, c.src, [b & 0xFF for b in flat])

    # 金标准
    exp = []
    for oy in range(oh):
        for ox in range(ow):
            for o in range(oc8):
                acc = bias[o]
                for ky in range(ks):
                    yy = oy * st + ky - pad
                    for kx in range(ks):
                        xx = ox * st + kx - pad
                        if 0 <= yy < ih and 0 <= xx < iw:
                            for ch in range(ic):
                                acc += img[yy][xx][ch] * w[ky * ks + kx][ch][o]
                v = requant(acc, mpos, leaky, shift, zp_out) if o < oc else zp_out
                exp.append(v & 0xFF)
    c.put_ab(c.b_exp, c.dst, exp)
    # A/B 初值: A 输入; B 全 0 (输出区会被写满)
    return emit(c, None, None)


# ---------------------------------------------------------------- ADD_R
def gen_add_r(name, ih, iw, ch, R, KADD, zp_s, zp_d, leaky_ignored=0):
    ic = oc = ch
    c8 = pad8(ch)
    name = name
    c = Case(name, 3, 0x40, 0, 1, 0, ih, iw, ic, oc, NA + 0x0, NB + 0x0)
    c.qoff = 0x200
    qb = [zp_s & 0xFF, zp_d & 0xFF] + i16(R) + [KADD & 0xFF] + [0] * 11
    c.put_q(c.qoff, qb)

    src = [[[rng.randint(-128, 127) for _ in range(c8)] for _ in range(iw)] for _ in range(ih)]
    dst = [[[rng.randint(-128, 127) for _ in range(c8)] for _ in range(iw)] for _ in range(ih)]
    a_bytes, b_bytes, exp = [], [], []
    for y in range(ih):
        for x in range(iw):
            for chn in range(c8):
                s = src[y][x][chn]
                d = dst[y][x][chn]
                a_bytes.append(s & 0xFF)
                b_bytes.append(d & 0xFF)
                # 只对真实通道计算 (padding 通道不动)
                if chn < ch:
                    v = (s - zp_s) * R
                    v = v >> KADD
                    v = v + d
                    v = max(-128, min(127, v))
                else:
                    v = d
                exp.append(v & 0xFF)
    c.put_ab(c.a_img, c.src, a_bytes)
    c.put_ab(c.b_img, c.dst, b_bytes)
    c.put_ab(c.b_exp, c.dst, exp)
    return emit(c, None, None)


def main():
    rows = []
    rows.append(gen_packed3())
    rows.append(gen_add_r("add_r_8ch_a", 6, 5, 8, 4249, 15, -3, 7))
    rows.append(gen_add_r("add_r_8ch_b", 8, 8, 8, 20000, 16, 5, -2))
    rows.append(gen_add_r("add_r_16ch", 5, 7, 16, 41736, 17, -7, 3))
    with open(os.path.join(OUT, "manifest.txt"), "w", encoding="ascii") as f:
        for r in rows:
            f.write("%s %d %d %d %d %d %d %d %d %d %d %d %d %d\n" % r)
    print("wrote %d cases to %s" % (len(rows), OUT))
    for r in rows:
        print("  ", r[0], "op", r[1], "flags", hex(r[2]), r[6], "x", r[7])


if __name__ == "__main__":
    main()
