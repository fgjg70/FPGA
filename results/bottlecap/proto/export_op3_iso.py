#!/usr/bin/env python3
"""export_op3_iso.py -- export the op3 ISO test vectors for the engine owner.

Outputs (results/bottlecap/proto/m6b_data/op3_iso/):
  op3_W.hex        1024 B layer W  (u32-LE hex, CONTRACT 6A dense layout)
  op3_Q.hex         112 B layer Q  (u32-LE hex, CONTRACT 7 layout)
  op3_A.hex      802816 B input A  (u32-LE hex, CONTRACT 8 NHWC C8=64)
  op3_golden.hex 200704 B output   (u32-LE hex, converter golden)
  README.txt      descriptor + Q params + how to run in ENGINE_TB
ASCII only.
"""

import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
PLAN_DIR = os.path.join(REPO, "results/bottlecap/plan")
OUT = os.path.join(HERE, "m6b_data/op3_iso")


def read_u32_hex(path):
    out = bytearray()
    with open(path, "r", encoding="ascii") as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            out += int(s.split()[0], 16).to_bytes(4, "little")
    return bytes(out)


def read_hex64(path):
    out = bytearray()
    with open(path, "r", encoding="ascii") as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            tok = s.split()[0]
            out += (b"\x00" * 8) if any(c in "xXzZ" for c in tok) \
                else int(tok, 16).to_bytes(8, "little")
    return bytes(out)


def write_u32_hex(path, data):
    if len(data) % 4:
        data = data + b"\x00" * (4 - len(data) % 4)
    with open(path, "w", encoding="ascii", newline="\n") as f:
        for i in range(0, len(data), 4):
            f.write("%08x\n" % int.from_bytes(data[i:i + 4], "little"))


def pad8(v):
    return ((int(v) + 7) // 8) * 8


def main():
    os.makedirs(OUT, exist_ok=True)
    plan = json.load(open(os.path.join(PLAN_DIR, "plan.json"), "r", encoding="utf-8"))
    op = plan["ops"][3]
    w = read_u32_hex(os.path.join(PLAN_DIR, "w.hex"))
    q = read_u32_hex(os.path.join(PLAN_DIR, "q.hex"))
    wl = w[int(op["woff"]):int(op["woff"]) + int(op["wlen"])]
    ql = q[int(op["qoff"]):int(op["qoff"]) + int(op["qlen"])]
    a = read_hex64(os.path.join(HERE, "m6b_data/golden_op002.hex"))
    g = read_u32_hex(os.path.join(PLAN_DIR, "opvec/pattern_v1/op003.hex"))

    oc_pad = int(op["oc_pad"])
    bias = np.frombuffer(ql[:4 * oc_pad], dtype=np.int32)
    mpos = np.frombuffer(ql[4 * oc_pad:6 * oc_pad], dtype=np.int16)
    tail = np.frombuffer(ql[6 * oc_pad:], dtype=np.int8)
    write_u32_hex(os.path.join(OUT, "op3_W.hex"), wl)
    write_u32_hex(os.path.join(OUT, "op3_Q.hex"), ql)
    write_u32_hex(os.path.join(OUT, "op3_A.hex"), a[:int(op["ih"]) * int(op["iw"]) * int(op["ic_pad"])])
    write_u32_hex(os.path.join(OUT, "op3_golden.hex"), g[:int(op["oh"]) * int(op["ow"]) * oc_pad])

    with open(os.path.join(OUT, "README.txt"), "w", encoding="ascii", newline="\n") as f:
        f.write("op3 ISO test vector for nn_conv_engine (M6b / task-15)\n")
        f.write("=====================================================\n")
        f.write("descriptor (CONTRACT fields):\n")
        f.write("  op    = 0 (CONV)\n")
        f.write("  flags = 0x%02x (no PACKED3/DW/LEAKY/ADD_R/RELU)\n" % int(op["flags"]))
        f.write("  ks/stride/pad = %d/%d/%d\n" % (int(op["k"]), int(op["stride"]), int(op["pad"])))
        f.write("  ih/iw/ic/oc   = %d/%d/%d/%d\n" % (int(op["ih"]), int(op["iw"]),
                                                     int(op["ic"]), int(op["oc"])))
        f.write("  src/dst       = 0x60000 / 0x78000 (stock A/B window offsets)\n")
        f.write("  woff/qoff     = 0 / 0 (layer-local; W 1024 B, Q 112 B)\n")
        f.write("Q parse (CONTRACT 7):\n")
        f.write("  bias_adj[0..15] = %s\n" % bias.tolist())
        f.write("  M_pos[0..15]    = %s\n" % mpos.tolist())
        f.write("  zp_out=%d zp_in=%d leaky_en=%d SHIFT=%d\n"
                % (int(tail[0]), int(tail[1]), int(tail[2]), int(tail[3]) & 0xFF))
        f.write("files (u32 little-endian hex, 8 hex digits/line):\n")
        f.write("  op3_W.hex      1024 B  (W layer)\n")
        f.write("  op3_Q.hex       112 B  (Q layer)\n")
        f.write("  op3_A.hex     802816 B (input A, NHWC C8=64)\n")
        f.write("  op3_golden.hex 200704 B (expected output, NHWC C8=16)\n")
        f.write("independent numpy recompute of these files == golden (0/200704 bytes);\n")
        f.write("M6b (tilecache+stream W) reproduces the same bytes as M6b ROM-mode run,\n")
        f.write("both differ from golden -> engine-side integration question.\n")
    print("[export] written to", OUT)
    for n in ("op3_W.hex", "op3_Q.hex", "op3_A.hex", "op3_golden.hex", "README.txt"):
        print("  ", n, os.path.getsize(os.path.join(OUT, n)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
