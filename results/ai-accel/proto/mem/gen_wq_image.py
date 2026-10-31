#!/usr/bin/env python3
# ============================================================================
# gen_wq_image.py -- generate the WQ initialization image(s) for nn_mem (v0.3)
# ----------------------------------------------------------------------------
# ASCII only (project rule for tool scripts). CONTRACT v0.3 format:
#   one 32-bit word per line, 8 hex digits, little-endian 4-byte packing,
#   line count = WQ_BYTES/4 = (W_BYTES + Q_BYTES)/4 = 94208 for the default.
# Pattern (must match sim/tb_nn_mem.sv wq_exp()):
#   word[i] = (i * 0x9E3779B9) ^ 0xC0DE0000   (32-bit wrap)
#
# Two output modes:
#   (a) --out <file>            : single image (simulation +nnwq=, contract)
#   (b) --split-prefix <prefix> : images for Vivado synthesis, matching
#                                 nn_mem_wq's 4 sub-arrays (power-of-two sizes):
#                                   <prefix>_a.hex : words [0, 65536)
#                                   <prefix>_b.hex : words [65536, 81920)
#                                   <prefix>_c.hex : next 8192 (or the rest)
#                                   <prefix>_d.hex : remaining (only if > 0)
# Usage:
#   python gen_wq_image.py --words 94208 --out C:/temp/yolo_wq.hex \
#                          --split-prefix C:/temp/yolo_wq_split
# ============================================================================
import argparse
import os


def word(i: int) -> int:
    return ((i * 0x9E3779B9) ^ 0xC0DE0000) & 0xFFFFFFFF


def main() -> int:
    ap = argparse.ArgumentParser(description="Generate nn_mem WQ init image(s)")
    ap.add_argument("--words", type=int, required=True,
                    help="number of 32-bit words (= WQ_BYTES/4)")
    ap.add_argument("--out", default=None, help="single output .hex path")
    ap.add_argument("--split-prefix", default=None,
                    help="prefix for the synthesis images (<prefix>_a/_b/_c/_d.hex)")
    args = ap.parse_args()

    if args.out is None and args.split_prefix is None:
        ap.error("at least one of --out / --split-prefix is required")

    if args.out:
        out_dir = os.path.dirname(os.path.abspath(args.out))
        if out_dir:
            os.makedirs(out_dir, exist_ok=True)
        with open(args.out, "w", encoding="ascii", newline="\n") as f:
            for i in range(args.words):
                f.write("%08x\n" % word(i))
        print("gen_wq_image: wrote single image %d words -> %s"
              % (args.words, os.path.abspath(args.out)))

    if args.split_prefix:
        wa, wb = 65536, 16384
        rest = args.words - wa - wb
        if rest < 0:
            raise SystemExit("split mode requires --words >= 81920")
        wc = 8192 if rest >= 8192 else rest
        wd = rest - wc

        pre_dir = os.path.dirname(os.path.abspath(args.split_prefix))
        if pre_dir:
            os.makedirs(pre_dir, exist_ok=True)
        parts = [(wa, "_a"), (wb, "_b"), (wc, "_c")]
        if wd > 0:
            parts.append((wd, "_d"))
        base = 0
        for n, suffix in parts:
            path = args.split_prefix + suffix + ".hex"
            with open(path, "w", encoding="ascii", newline="\n") as f:
                for i in range(base, base + n):
                    f.write("%08x\n" % word(i))
            print("gen_wq_image: wrote %d words -> %s" % (n, os.path.abspath(path)))
            base += n
        print("gen_wq_image: split total = %d words" % base)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
