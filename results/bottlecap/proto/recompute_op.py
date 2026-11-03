#!/usr/bin/env python3
"""recompute_op.py -- independent numpy recompute of one plan op.

Purpose (M6b / task-15): decide whether the engine differs from the converter
golden because of (a) engine dense-path semantics or (b) plan W/Q/activation
semantics.  Reimplements CONTRACT.md sections 5/6/7/8 from the *frozen plan
files* (plan.json + w.hex + q.hex + input tensor arena bytes) and compares:

    numpy(plan files)   vs   converter golden tensor (opvec)
    numpy(plan files)   vs   engine dump (tb_bottlecap_ddr_chain +dump_out)

ASCII only.

Usage:
  python results/bottlecap/proto/recompute_op.py --op 3 \
     --input results/bottlecap/proto/m6b_data/golden_op002.hex \
     --golden results/bottlecap/plan/opvec/pattern_v1/op003.hex \
     --engine results/bottlecap/proto/m6b_data/engine_op003_dump.hex
"""

import argparse
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
PLAN_DIR = os.path.join(REPO, "results/bottlecap/plan")


def read_u32_hex(path):
    out = bytearray()
    with open(path, "r", encoding="ascii") as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            out += int(s.split()[0], 16).to_bytes(4, "little")
    return bytes(out)


def read_hex64(path, xcount=None):
    """64b/line hex; words containing x/z (uninitialised RAM) are read as 0 and
    counted into xcount[0] so callers can report them separately."""
    out = bytearray()
    nx = 0
    with open(path, "r", encoding="ascii") as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            tok = s.split()[0]
            if any(c in "xXzZ" for c in tok):
                nx += 1
                out += b"\x00" * 8
            else:
                out += int(tok, 16).to_bytes(8, "little")
    if xcount is not None:
        xcount[0] = nx
    return bytes(out)


def pad8(v):
    return ((int(v) + 7) // 8) * 8


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--op", type=int, required=True)
    ap.add_argument("--input", required=True, help="input tensor arena bytes (64b hex)")
    ap.add_argument("--golden", default=None, help="converter opvec tensor (u32 hex)")
    ap.add_argument("--engine", default=None, help="engine dump (64b hex)")
    ap.add_argument("--plan", default=os.path.join(PLAN_DIR, "plan.json"))
    ap.add_argument("--whex", default=os.path.join(PLAN_DIR, "w.hex"))
    ap.add_argument("--qhex", default=os.path.join(PLAN_DIR, "q.hex"))
    ap.add_argument("--ih", type=int, default=0, help="override input height (crop)")
    ap.add_argument("--iw", type=int, default=0, help="override input width (crop)")
    ap.add_argument("--export-input", default=None, help="write cropped input 64b hex")
    ap.add_argument("--export-golden", default=None, help="write numpy output 64b hex")
    args = ap.parse_args(argv)

    plan = json.load(open(args.plan, "r", encoding="utf-8"))
    op = plan["ops"][args.op]
    k, st, pad = int(op["k"]), int(op["stride"]), int(op["pad"])
    ih, iw = int(op["ih"]), int(op["iw"])
    if args.ih:
        ih = args.ih
    if args.iw:
        iw = args.iw
    oh, ow = ih, iw       # synthetic cases are k1/s1/p0 only
    ic, oc = int(op["ic"]), int(op["oc"])
    ic_pad, oc_pad = int(op.get("ic_pad", pad8(ic))), int(op.get("oc_pad", pad8(oc)))
    woff, wlen = int(op["woff"]), int(op["wlen"])
    qoff, qlen = int(op["qoff"]), int(op["qlen"])
    kind, flags, act = op["kind"], int(op["flags"]), op.get("act")
    print(f"[recompute] op {args.op}: {kind} k{k} s{st} p{pad} {ih}x{iw}x{ic}->{oc} "
          f"flags={flags:#x} act={act} woff={woff} wlen={wlen} qoff={qoff} qlen={qlen}")

    wbytes = read_u32_hex(args.whex)
    qbytes = read_u32_hex(args.qhex)
    W = np.frombuffer(wbytes[woff:woff + wlen], dtype=np.uint8).astype(np.int8)
    Q = np.frombuffer(qbytes[qoff:qoff + qlen], dtype=np.uint8).astype(np.int8)

    # ---- W layout (CONTRACT 6A dense): [tap][IC_pad][OC_pad] ----------------
    if kind == "dwconv":
        exp_w = k * k * oc_pad
        assert wlen == exp_w, f"dwconv wlen {wlen} != {exp_w}"
    else:
        exp_w = k * k * ic_pad * oc_pad
        assert wlen == exp_w, f"dense wlen {wlen} != {exp_w}"
    Wm = W.reshape(k * k, ic_pad, oc_pad)

    # ---- Q layout (CONTRACT 7): bias int32[oc_pad], M_pos int16[oc_pad], tail
    exp_q = 6 * oc_pad + 16
    assert qlen == exp_q, f"qlen {qlen} != {exp_q}"
    bias = np.frombuffer(Q[:4 * oc_pad].tobytes(), dtype=np.int32).astype(np.int64)
    mpos = np.frombuffer(Q[4 * oc_pad:6 * oc_pad].tobytes(), dtype=np.int16).astype(np.int64)
    tail = Q[6 * oc_pad:].astype(np.int64)
    zp_out, zp_in, leaky_en, shift = int(tail[0]), int(tail[1]), int(tail[2]), int(tail[3])
    print(f"[recompute] Q parse: zp_out={zp_out} zp_in={zp_in} leaky_en={leaky_en} "
          f"SHIFT={shift} bias[0..3]={bias[:4].tolist()} M_pos[0..3]={mpos[:4].tolist()}")
    mneg = mpos if leaky_en == 0 else ((mpos * 3277 + 16384) >> 15)

    # ---- input tensor arena layout (CONTRACT 8): NHWC C8 --------------------
    ib = read_hex64(args.input)
    need = ih * iw * ic_pad
    assert len(ib) >= need, f"input bytes {len(ib)} < {need}"
    A = np.frombuffer(ib[:need], dtype=np.uint8).astype(np.int8).reshape(ih, iw, ic_pad)
    A = A[:, :, :ic].astype(np.int64)            # real channels only
    if op.get("packed"):
        raise SystemExit("packed3 input not supported by this recompute (op0 only)")

    Wr = Wm[:, :ic, :oc].astype(np.int64)        # (K*K, ic, oc)
    acc = np.zeros((oh, ow, oc), dtype=np.int64)
    for ky in range(k):
        for kx in range(k):
            tap = ky * k + kx
            for y in range(oh):
                iy = y * st - pad + ky
                if iy < 0 or iy >= ih:
                    continue
                for x in range(ow):
                    ix = x * st - pad + kx
                    if ix < 0 or ix >= iw:
                        continue
                    acc[y, x] += Wr[tap, :, :].T @ A[iy, ix, :]
    acc += bias[None, None, :oc]

    # ---- requant (CONTRACT 5) ----------------------------------------------
    m = np.where(acc >= 0, np.broadcast_to(mpos[None, None, :oc], acc.shape),
                 np.broadcast_to(mneg[None, None, :oc], acc.shape))
    y = (acc * m) >> shift
    out = np.clip(y + zp_out, -128, 127).astype(np.int8)
    print(f"[recompute] numpy out: shape {out.shape}, "
          f"min={int(out.min())} max={int(out.max())}")

    # ---- load references ---------------------------------------------------
    def cmp(name, data_bytes, c8):
        ref = np.frombuffer(data_bytes, dtype=np.uint8).astype(np.int8)
        ref = ref[:oh * ow * c8].reshape(oh, ow, c8)[:, :, :oc]
        bad = int(np.count_nonzero(ref != out))
        total = int(ref.size)
        print(f"[recompute] vs {name}: mismatch {bad}/{total} bytes "
              f"({100.0*bad/total:.2f}%)")
        if bad:
            flat_ref = ref.reshape(-1)
            flat_out = out.reshape(-1)
            idx = np.nonzero(flat_ref != flat_out)[0][:8]
            for i in idx:
                px = i // oc
                print(f"    byte {i} (y={px//ow},x={px%ow},c={i%oc}): "
                      f"numpy={int(flat_out[i])} ref={int(flat_ref[i])}")
        return bad

    if args.export_input:
        def w64(path, data):
            with open(path, "w", encoding="ascii", newline="\n") as f:
                for i in range(0, len(data) - len(data) % 8, 8):
                    f.write("%016x\n" % int.from_bytes(data[i:i+8], "little"))
        w64(args.export_input, ib[:ih * iw * ic_pad])
        print(f"[recompute] exported cropped input ({ih*iw*ic_pad} B) -> {args.export_input}")
    if args.export_golden:
        raw = np.frombuffer(out.reshape(-1).tobytes(), dtype=np.uint8)
        padded = out.reshape(-1)
        def w32(path, data_bytes):
            with open(path, "w", encoding="ascii", newline="\n") as f:
                for i in range(0, len(data_bytes), 4):
                    f.write("%08x\n" % int.from_bytes(data_bytes[i:i+4], "little"))
        w32(args.export_golden, np.ascontiguousarray(padded).tobytes())
        print(f"[recompute] exported numpy golden ({oh*ow*oc} B) -> {args.export_golden}")
    if args.golden:
        cmp("golden", read_u32_hex(args.golden), oc_pad)
    if args.engine:
        xc = [0]
        eng_bytes = read_hex64(args.engine, xc)
        print(f"[recompute] engine dump: X words = {xc[0]} (treated as 0)")
        nbad = cmp("engine(non-X ref)", eng_bytes, oc_pad)
        # also report per-16B-word X distribution (which pixel/octile groups)
        if xc[0]:
            print(f"[recompute] X words/64b = {xc[0]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
