# -*- coding: utf-8 -*-
"""从 yolo_w.hex / yolo_q.hex 生成 nn_mem v0.7 综合初始化镜像 (OOC 综合用)。

t-mem 2026-11-01 的口径（只影响 bitstream 初始化，不影响仿真）：
  W: 4 段 **64-bit/行** 镜像，宏名 NN_W_INIT_A..D 不变
     A = 16,384 行 / B = C = D = 8,192 行（共 40,960 x 64b = 320KB）
     （每行 = 2 个 32-bit 小端字：word[2i] 在低 32 位）
  Q: 不变，64-bit/行，6,144 行（宏 NN_Q_INIT_FILE）
仿真仍用 +nnwq=<32-bit 行>，由 nn_mem 内部打包。
"""
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

# W: 64-bit 行（低 32 位 = 低地址字）
w64 = [w[2 * i] | (w[2 * i + 1] << 32) for i in range(len(w) // 2)]
assert len(w64) == 40960
segs = [(0, 16384, "w_A.hex"), (16384, 24576, "w_B.hex"),
        (24576, 32768, "w_C.hex"), (32768, 40960, "w_D.hex")]
for a, b, fn in segs:
    with io.open(os.path.join(OUT, fn), "w", encoding="ascii") as f:
        for v in w64[a:b]:
            f.write("%016x\n" % v)

# Q: 64-bit 行（低 32 位 = 低地址 32-bit 字）
with io.open(os.path.join(OUT, "q_packed.hex"), "w", encoding="ascii") as f:
    for k in range(0, len(q), 2):
        f.write("%016x\n" % (q[k] | (q[k + 1] << 32)))

print("wrote", OUT)
for fn in ("w_A.hex", "w_B.hex", "w_C.hex", "w_D.hex", "q_packed.hex"):
    n = sum(1 for _ in io.open(os.path.join(OUT, fn), encoding="ascii"))
    print("  %-12s %7d lines" % (fn, n))
