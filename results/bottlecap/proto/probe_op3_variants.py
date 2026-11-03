#!/usr/bin/env python3
"""probe_op3_variants.py -- compare engine dump against numpy variants.

M6b diagnostic: numpy(CONTRACT) == converter golden exactly, so the engine dump
must be explained by some alternative semantic.  Try plausible variants and
report mismatch counts; the variant that reproduces the engine dump reveals the
integration bug.  ASCII only.
"""

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


def read_hex64(path):
    out = bytearray()
    with open(path, "r", encoding="ascii") as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            tok = s.split()[0]
            if "x" in tok or "X" in tok or "z" in tok or "Z" in tok:
                out += b"\x00" * 8
            else:
                out += int(tok, 16).to_bytes(8, "little")
    return bytes(out)


def pad8(v):
    return ((int(v) + 7) // 8) * 8


def compute(op, wbytes, qbytes, inp, *, w_transpose=False, a_blocked=False,
            relu_neg=False, leaky_neg=False, q_bias16=False, no_bias=False,
            shift_override=None, a_zero=False, a_halfswap=False,
            w_off_override=None, q_off_override=None,
            ic_limit=None, oc_limit=None):
    k, st, pad = int(op["k"]), int(op["stride"]), int(op["pad"])
    ih, iw = int(op["ih"]), int(op["iw"])
    ic, oc = int(op["ic"]), int(op["oc"])
    ic_pad, oc_pad = int(op.get("ic_pad", pad8(ic))), int(op.get("oc_pad", pad8(oc)))
    oh, ow = int(op["oh"]), int(op["ow"])
    woff, wlen, qoff, qlen = int(op["woff"]), int(op["wlen"]), int(op["qoff"]), int(op["qlen"])

    if w_off_override is not None:
        woff = int(w_off_override)
    if q_off_override is not None:
        qoff = int(q_off_override)
    W = np.frombuffer(wbytes[woff:woff + wlen], dtype=np.uint8).astype(np.int8)
    Q = np.frombuffer(qbytes[qoff:qoff + qlen], dtype=np.uint8).astype(np.int8)
    if w_transpose:
        Wm = W.reshape(k * k, oc_pad, ic_pad).transpose(0, 2, 1)
    else:
        Wm = W.reshape(k * k, ic_pad, oc_pad)

    if q_bias16:
        bias = np.frombuffer(Q[:2 * oc_pad].tobytes(), dtype=np.int16).astype(np.int64)
        mpos_off = 2 * oc_pad
        tail_off = 4 * oc_pad
    else:
        bias = np.frombuffer(Q[:4 * oc_pad].tobytes(), dtype=np.int32).astype(np.int64)
        mpos_off = 4 * oc_pad
        tail_off = 6 * oc_pad
    mpos = np.frombuffer(Q[mpos_off:mpos_off + 2 * oc_pad].tobytes(),
                         dtype=np.int16).astype(np.int64)
    tail = Q[tail_off:].astype(np.int64)
    zp_out, zp_in, leaky_en, shift = int(tail[0]), int(tail[1]), int(tail[2]), int(tail[3])
    if shift_override is not None:
        shift = shift_override
    if relu_neg:
        mneg = np.zeros_like(mpos)
    elif leaky_neg:
        mneg = ((mpos * 3277 + 16384) >> 15)
    else:
        mneg = mpos

    ic_use = ic if ic_limit is None else min(ic, int(ic_limit))
    oc_use = oc if oc_limit is None else min(oc, int(oc_limit))
    need = ih * iw * ic_pad
    A = np.frombuffer(inp[:need], dtype=np.uint8).astype(np.int8)
    if a_blocked:
        # planar-ish: [ic_pad][ih*iw] reconstructed from arena? not available; skip
        raise SystemExit("a_blocked requires planar source, not supported")
    if a_zero:
        A = np.zeros(need, dtype=np.int64)
    A = A.reshape(ih, iw, ic_pad)
    if a_halfswap:
        # swap the two 8B halves of every 16B (16-channel) group
        A = A.reshape(ih, iw, ic_pad // 16, 2, 8)[:, :, :, ::-1, :].reshape(ih, iw, ic_pad)
    A = A[:, :, :ic].astype(np.int64)
    if ic_limit is not None:
        A = A[:, :, :ic_use]

    Wr = Wm[:, :ic_use, :oc_use].astype(np.int64)
    acc = np.zeros((oh, ow, oc_use), dtype=np.int64)
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
    if not no_bias:
        acc += bias[None, None, :oc_use]
    m = np.where(acc >= 0, np.broadcast_to(mpos[None, None, :oc_use], acc.shape),
                 np.broadcast_to(mneg[None, None, :oc_use], acc.shape))
    y = (acc * m) >> shift
    out = np.clip(y + zp_out, -128, 127).astype(np.int8)
    if oc_use < oc:
        full = np.zeros((oh, ow, oc), dtype=np.int8)
        full[:, :, :oc_use] = out
        out = full
    return out, (zp_out, zp_in, leaky_en, shift)


def main():
    op_id = 3
    plan = json.load(open(os.path.join(PLAN_DIR, "plan.json"), "r", encoding="utf-8"))
    op = plan["ops"][op_id]
    wbytes = read_u32_hex(os.path.join(PLAN_DIR, "w.hex"))
    qbytes = read_u32_hex(os.path.join(PLAN_DIR, "q.hex"))
    inp = read_hex64(os.path.join(REPO, "results/bottlecap/proto/m6b_data/golden_op002.hex"))
    golden = np.frombuffer(read_u32_hex(os.path.join(
        PLAN_DIR, "opvec/pattern_v1/op003.hex")), dtype=np.uint8).astype(np.int8)
    eng = np.frombuffer(read_hex64(os.path.join(
        REPO, "results/bottlecap/proto/m6b_data/engine_op003_dump.hex")),
        dtype=np.uint8).astype(np.int8)
    oh, ow = int(op["oh"]), int(op["ow"])
    oc_pad = int(op["oc_pad"])
    oc = int(op["oc"])
    golden = golden[:oh * ow * oc_pad].reshape(oh, ow, oc_pad)[:, :, :oc]
    eng_n = eng[:oh * ow * oc_pad].reshape(oh, ow, oc_pad)[:, :, :oc]
    eng_bad = int(np.count_nonzero(eng_n != golden))
    print(f"[probe] engine dump total bytes {eng.size}, X->0; "
          f"vs golden mismatch {eng_bad}/{golden.size}")

    variants = [
        ("baseline(CONTRACT)", dict()),
        ("A = zeros (bias only)", dict(a_zero=True)),
        ("A 8B halves swapped in 16B", dict(a_halfswap=True)),
        ("W offset 0 (file start)", dict(w_off_override=0)),
        ("W offset woff+1024 (next layer)", dict(w_off_override=int(op["woff"]) + 1024)),
        ("only first 8 ic", dict(ic_limit=8)),
        ("only first 16 ic", dict(ic_limit=16)),
        ("only first 32 ic", dict(ic_limit=32)),
        ("only first 8 oc", dict(oc_limit=8)),
        ("Q offset 0", dict(q_off_override=0)),
        ("Q offset qoff+112 (next layer)", dict(q_off_override=int(op["qoff"]) + 112)),
        ("W transposed [tap][oc][ic]", dict(w_transpose=True)),
        ("relu-neg (M_neg=0)", dict(relu_neg=True)),
        ("leaky-neg", dict(leaky_neg=True)),
        ("q bias int16", dict(q_bias16=True)),
        ("no bias", dict(no_bias=True)),
        ("shift=0", dict(shift_override=0)),
        ("shift=15", dict(shift_override=15)),
    ]
    for name, kw in variants:
        try:
            out, qinfo = compute(op, wbytes, qbytes, inp, **kw)
        except SystemExit as e:
            print(f"[probe] {name}: skipped ({e})")
            continue
        gbad = int(np.count_nonzero(out != golden))
        ebad = int(np.count_nonzero(out != eng_n))
        print(f"[probe] {name:32s}: vs golden {gbad:6d}/{golden.size}  "
              f"vs engine {ebad:6d}/{golden.size}  (Q {qinfo})")


if __name__ == "__main__":
    sys.exit(main())
