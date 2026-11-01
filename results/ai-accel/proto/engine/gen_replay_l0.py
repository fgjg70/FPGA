# -*- coding: utf-8 -*-
"""把 t-model 的 full-size conv0 (l0) 向量转成 TB 向量目录 vec_l0/，用于复现 SoC 级 op0。
   desc: op=0 flags=0x22(PACKED3|LEAKY) ks=3 st=2 pad=1 ih=iw=128 ic=3 oc=8
         src=0x60000(A@0) dst=0x6C000(A@0xC000) woff=0 qoff=0
"""
import io
import os

HERE = os.path.dirname(os.path.abspath(__file__))
YOLO = os.path.abspath(os.path.join(HERE, "..", "..", "..", "..", "sim", "prog", "yolo"))
OUT = os.path.join(HERE, "vec_l0")
os.makedirs(OUT, exist_ok=True)

NN_A = 0x60000
NN_Q = 0x50000


def read_bytes(name):
    return [int(x, 16) for x in io.open(os.path.join(YOLO, name), encoding="ascii").read().split()]


def read_words(name):
    return [int(x, 16) for x in io.open(os.path.join(YOLO, name), encoding="ascii").read().split()]


inp = read_bytes("l0_in.hex")       # 49152 bytes
w = read_bytes("l0_w.hex")          # 576 bytes
q = read_words("l0_q.hex")          # 16 x 32-bit
exp = read_bytes("l0_out.hex")      # 32768 bytes
assert len(inp) == 128 * 128 * 3 and len(w) == 576 and len(q) == 16 and len(exp) == 32768

SRC = 0x60000
DST = 0x6C000
name = "replay_l0_conv0"

# ---- manifest ----
with io.open(os.path.join(OUT, "manifest.txt"), "w", encoding="ascii") as f:
    f.write("%s %d %d %d %d %d %d %d %d %d %d %d %d %d\n" % (
        name, 0, 0x22, 3, 2, 1, 128, 128, 3, 8, SRC, DST, 0, 0))

# ---- wq.wr: W 在 woff=0, Q 在 qoff=0 ----
agg = {}
for i, b in enumerate(w):
    agg[i // 4] = agg.get(i // 4, 0) | (b << (8 * (i % 4)))
lines = [("%05x %08x" % (a * 4, agg[a])) for a in sorted(agg)]
qagg = {}
for i, wd in enumerate(q):
    qagg[NN_Q + i * 4] = wd
lines += [("%05x %08x" % (a, qagg[a])) for a in sorted(qagg)]
io.open(os.path.join(OUT, name + ".wq.wr"), "w", encoding="ascii").write("\n".join(lines) + "\n")

# ---- a.wr: 输入字节写到 SRC (按 8B 字, 相对 NN_A) ----
def ab_words(base_abs, data):
    words = {}
    for i, b in enumerate(data):
        a = base_abs + i
        rel = a - NN_A
        wd = rel >> 3
        words.setdefault(wd, [0, 0])
        words[wd][(rel >> 2) & 1] |= b << (8 * (rel & 3))
    return words


def write_ab(fn, words):
    with io.open(os.path.join(OUT, fn), "w", encoding="ascii") as f:
        for wd in sorted(words):
            f.write("%04x %08x %08x\n" % (wd, words[wd][1], words[wd][0]))


write_ab(name + ".a.wr", ab_words(SRC, inp))
# 期望输出在 A 区 DST 处 -> 用 aexp 比较
write_ab(name + ".aexp.wr", ab_words(DST, exp))
# b 区不用: 空文件
io.open(os.path.join(OUT, name + ".b.wr"), "w", encoding="ascii").write("")
io.open(os.path.join(OUT, name + ".bexp.wr"), "w", encoding="ascii").write("")
print("wrote", OUT, "case", name, "in", len(inp), "w", len(w), "exp", len(exp))
