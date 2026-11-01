# -*- coding: utf-8 -*-
"""从 yolo_w.hex / yolo_q.hex 生成 nn_mem v0.7 的 4 段 W 128b 初始化 + Q 64b 初始化 (OOC 综合用)。"""
import io
import os

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", ".."))
SRC = os.path.join(ROOT, "sim", "prog", "yolo")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "wq_init")
os.makedirs(OUT, exist_ok=True)

w = [int(x, 16) for x in io.open(os.path.join(SRC, "yolo_w.hex"), encoding="ascii").read().split()]
q = [int(x, 16) for x in io.open(os.path.join(SRC, "yolo_q.hex"), encoding="ascii").read().split()]
assert len(w) == 81920, len(w)
assert len(q) == 12288, len(q)

# W: 128b 字 = 4 个 32-bit 字 (小端: word0 在低 32 位)
w128 = []
for k in range(0, len(w), 4):
    v = w[k] | (w[k + 1] << 32) | (w[k + 2] << 64) | (w[k + 3] << 96)
    w128.append(v)
segs = [(0, 8192, "w_A.hex"), (8192, 12288, "w_B.hex"), (12288, 16384, "w_C.hex"),
        (16384, 20480, "w_D.hex")]
for a, b, fn in segs:
    with io.open(os.path.join(OUT, fn), "w", encoding="ascii") as f:
        for v in w128[a:b]:
            f.write("%032x\n" % v)

# Q: 64b 字 = 2 个 32-bit 字 (word0 低 32 位)
with io.open(os.path.join(OUT, "q_packed.hex"), "w", encoding="ascii") as f:
    for k in range(0, len(q), 2):
        f.write("%016x\n" % (q[k] | (q[k + 1] << 32)))

print("wrote", OUT,
      "W128 words", len(w128), "Q64 words", len(q) // 2)
for fn in ("w_A.hex", "w_B.hex", "w_C.hex", "w_D.hex", "q_packed.hex"):
    p = os.path.join(OUT, fn)
    print(" ", fn, os.path.getsize(p))
