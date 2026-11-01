#!/usr/bin/env python3
# ============================================================================
# gen_wq_image.py -- generate nn_mem v0.7 W/Q initialization images
# ----------------------------------------------------------------------------
# ASCII only (project rule for tool scripts).
#
# 【仿真格式 (32-bit 字/行, 8 hex)】
#   --wq-out <file> : 94,208 行 = W 81,920 + Q 12,288 顺序拼接 (旧 +nnwq= 口径)
#   --w-out  <file> : 81,920 行 (W 区, +nnw= 口径)
#   --q-out  <file> : 12,288 行 (Q 区, +nnq= 口径)
#
# 【综合格式 (物理字宽/行)】
#   --split-prefix <pre> :
#     <pre>_a.hex : 16384 行 x 64-bit  (W 段 A: 32-bit 字 0..32767, 128KB)
#     <pre>_b.hex :  8192 行 x 64-bit  (W 段 B: 32768..49151, 64KB)
#     <pre>_c.hex :  8192 行 x 64-bit  (W 段 C: 49152..65535, 64KB)
#     <pre>_d.hex :  8192 行 x 64-bit  (W 段 D: 65536..81919, 64KB)
#     <pre>_q.hex :  6144 行 x 64-bit  (Q 区; 行 k = Q32[2k] | Q32[2k+1]<<32)
#   W 行打包: 行 k = W32[2k] | W32[2k+1]<<32 (低字在低 32 位)。
#   （v0.7 R3: W 物理阵列从 128-bit 宽改为 64-bit 宽 —— 8B 对齐窗口需要两个
#     满宽读口, 128-bit 宽会让第二读口被裁成 64-bit 造成存储复制。）
#
# 内容模式:
#   默认 (不给 --seed): 测试样图, 与 sim/tb_nn_mem.sv 的 wpat32()/qpat32() 一致:
#     wpat32(i) = (i * 0x9E3779B9) ^ 0xC0DE0000
#     qpat32(i) = (i * 0x85EBCA6B) ^ 0x5A5A1234
#   --seed N: 用伪随机内容 (每 32-bit 字都不同), 用于综合取证 —— 真实权重/量化
#     参数不可压缩, 而测试样图是线性结构, Vivado 会把它优化成压缩实现,
#     导致综合资源数字偏小 (W/Q 都会被低估)。TB 期望值仍用测试样图。
#
# Usage:
#   python gen_wq_image.py --wq-out C:/tmp/yolo_wq.hex                      (TB)
#   python gen_wq_image.py --split-prefix C:/tmp/yolo --seed 20261101      (synthesis)
# ============================================================================
import argparse
import os
import random

W_WORDS = 320 * 1024 // 4      # 81,920 (32-bit 字)
Q_WORDS = 48 * 1024 // 4       # 12,288 (32-bit 字)
WSEG64 = [16384, 8192, 8192, 8192]   # 64-bit 字的段大小 (W, 单位=64-bit 字)


def wpat32(i: int) -> int:
    return ((i * 0x9E3779B9) ^ 0xC0DE0000) & 0xFFFFFFFF


def qpat32(i: int) -> int:
    return ((i * 0x85EBCA6B) ^ 0x5A5A1234) & 0xFFFFFFFF


def write_lines(path: str, lines) -> None:
    d = os.path.dirname(os.path.abspath(path))
    if d:
        os.makedirs(d, exist_ok=True)
    with open(path, "w", encoding="ascii", newline="\n") as f:
        for line in lines:
            f.write(line)


def main() -> int:
    ap = argparse.ArgumentParser(description="Generate nn_mem v0.7 W/Q images")
    ap.add_argument("--wq-out", default=None, help="94208-line 32-bit WQ image")
    ap.add_argument("--w-out", default=None, help="81920-line 32-bit W image")
    ap.add_argument("--q-out", default=None, help="12288-line 32-bit Q image")
    ap.add_argument("--split-prefix", default=None,
                    help="prefix for packed synthesis images (_a/_b/_c/_d/_q)")
    ap.add_argument("--seed", type=int, default=None,
                    help="use pseudo-random content (for realistic synthesis proof)")
    args = ap.parse_args()

    if not any([args.wq_out, args.w_out, args.q_out, args.split_prefix]):
        ap.error("give at least one output option")

    if args.seed is not None:
        rnd = random.Random(args.seed)
        W = [rnd.getrandbits(32) for _ in range(W_WORDS)]
        Q = [rnd.getrandbits(32) for _ in range(Q_WORDS)]
        print("gen_wq_image: pseudo-random content (seed=%d) for synthesis proof"
              % args.seed)
    else:
        W = [wpat32(i) for i in range(W_WORDS)]
        Q = [qpat32(i) for i in range(Q_WORDS)]
        print("gen_wq_image: test-pattern content (matches tb_nn_mem wpat32/qpat32)")

    if args.wq_out:
        write_lines(args.wq_out, ["%08x\n" % w for w in W] + ["%08x\n" % q for q in Q])
        print("gen_wq_image: WQ single image %d lines -> %s" % (W_WORDS + Q_WORDS, args.wq_out))
    if args.w_out:
        write_lines(args.w_out, ["%08x\n" % w for w in W])
        print("gen_wq_image: W image %d lines -> %s" % (W_WORDS, args.w_out))
    if args.q_out:
        write_lines(args.q_out, ["%08x\n" % q for q in Q])
        print("gen_wq_image: Q image %d lines -> %s" % (Q_WORDS, args.q_out))

    if args.split_prefix:
        base32 = 0                    # 32-bit word offset
        for seg, n64 in zip("abcd", WSEG64):
            path = args.split_prefix + "_" + seg + ".hex"
            lines = []
            for k in range(n64):
                w0 = W[base32 + 2 * k + 0]
                w1 = W[base32 + 2 * k + 1]
                lines.append("%016x\n" % (w0 | (w1 << 32)))
            write_lines(path, lines)
            print("gen_wq_image: W seg %s %d lines (64-bit) -> %s" % (seg, n64, path))
            base32 += n64 * 2
        qpath = args.split_prefix + "_q.hex"
        lines = []
        for k in range(Q_WORDS // 2):
            lo = Q[2 * k]
            hi = Q[2 * k + 1]
            lines.append("%016x\n" % (lo | (hi << 32)))
        write_lines(qpath, lines)
        print("gen_wq_image: Q %d lines (64-bit) -> %s" % (Q_WORDS // 2, qpath))
        print("gen_wq_image: W words covered = %d (expected %d)" % (base32, W_WORDS))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
