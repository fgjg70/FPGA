#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Bit-exact numpy integer golden forward + self-check vs quantize.py's model.

The golden path (`quant_lib.golden_forward`) is coded independently from the
reference path (`quant_lib.int8_forward`): per-ic / per-oc loops instead of
im2col matmul, `np.floor_divide` instead of arithmetic shift.  Integer
arithmetic is exact, so both must agree **bit for bit** on every op.

Input is the deterministic input image (CONTRACT v0.3.2 "pattern_v1", seed
12345), packed 3 bytes/pixel.

Run:  python tools/yolo/golden.py [--hw 128] [--npz tools/yolo/data/model_int8_128.npz]
Prints `GOLDEN: PASS mismatch=0 ...` / `GOLDEN: FAIL ...`.
"""
import argparse
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import darknet_lib as dl       # noqa: E402
import detect_lib as de        # noqa: E402
import quant_lib as ql         # noqa: E402
import vec_io as vio           # noqa: E402

CFG = os.path.join(HERE, "data", "yolo-fastest-1.1.cfg")


def load_model(npz_path):
    z = np.load(npz_path, allow_pickle=False)
    meta = json.loads(bytes(z["meta"]).decode("utf-8"))
    hw = meta["hw"]
    net = dl.build_net(CFG, hw, hw)
    plan = dl.assign_wq_offsets(dl.plan_ops(net))
    if len(plan["ops"]) != meta["n_ops"]:
        raise SystemExit("plan/meta op count mismatch")
    q = {"ops": {}, "gq": {int(r): (float(s), int(zp)) for (r, s, zp) in meta["gq"]},
         "roots": meta["roots"], "groups": {"roots": meta["roots"],
                                            "add_roots": set(meta["add_roots"])}}
    q["adds"] = {}
    for op_id, op in enumerate(plan["ops"]):
        if op["kind"] == "cpu_add":
            m = meta["ops"][op_id]
            q["adds"][op_id] = {"r_scale": int(m["r_scale"]),
                                "k_add": int(m["k_add"]),
                                "zp_s": int(m["zp_s"])}
        if op["kind"] in ("conv", "dwconv", "cpu_conv0"):
            q["ops"][op_id] = {
                "wq": z["op%d_wq" % op_id].astype(np.int8),
                "bias_adj": z["op%d_bias" % op_id].astype(np.int64),
                "mpos": z["op%d_mpos" % op_id].astype(np.int64),
                "shift": int(meta["ops"][op_id]["shift"]),
                "leaky": int(meta["ops"][op_id]["leaky"]),
                "zp_in": int(meta["ops"][op_id]["zp_in"]),
                "zp_out": int(meta["ops"][op_id]["zp_out"]),
                "s_in": float(meta["ops"][op_id]["s_in"]),
                "s_out": float(meta["ops"][op_id]["s_out"]),
                "oc": int(meta["ops"][op_id]["oc"]),
                "oc_pad": int(z["op%d_wq" % op_id].shape[-1 if op["kind"] == "dwconv" else 2]),
                "ic": int(meta["ops"][op_id]["ic"]),
                "k": int(meta["ops"][op_id]["k"]),
                "stride": int(meta["ops"][op_id]["stride"]),
                "pad": int(meta["ops"][op_id]["pad"]),
                "depthwise": op["kind"] == "dwconv",
            }
    return meta, net, plan, q


def run(hw=None, npz=None):
    npz = npz or os.path.join(HERE, "data", "model_int8_128.npz")
    meta, net, plan, q = load_model(npz)
    if hw is not None and hw != meta["hw"]:
        raise SystemExit("npz hw %d != requested %d" % (meta["hw"], hw))
    hw = meta["hw"]
    x = de.pattern_v1(hw, hw, c=3, seed=12345)          # (H,W,3) int8, packed
    t_store, t_out = ql.int8_forward(plan, q, x)
    g_store, g_out = ql.golden_forward(plan, q, x)
    mismatch = 0
    maxdiff = 0
    bad_ops = []
    for op_id in range(len(plan["ops"])):
        a = t_out[op_id].astype(np.int16)
        b = g_out[op_id].astype(np.int16)
        if a.shape != b.shape:
            bad_ops.append((op_id, "shape", a.shape, b.shape))
            mismatch += 1
            continue
        d = np.abs(a - b)
        n = int((d != 0).sum())
        maxdiff = max(maxdiff, int(d.max()) if d.size else 0)
        if n:
            mismatch += n
            bad_ops.append((op_id, plan["ops"][op_id]["kind"], n, int(d.max())))
    # also compare padding-channel bytes of every stored tensor
    pad_mismatch = 0
    for tid, arr in g_store.items():
        if tid == plan["input_tensor"]:
            continue
        ta = t_store[tid]
        pad_mismatch += int((ta.astype(np.int16) != arr.astype(np.int16)).sum())
    in_csum = vio.fnv1a_int8(x)
    print("GOLDEN: hw=%d ops=%d" % (hw, len(plan["ops"])))
    print("  input pattern_v1 checksum = 0x%08x" % in_csum)
    if mismatch == 0 and pad_mismatch == 0:
        print("GOLDEN: PASS mismatch=0 maxdiff=0 pad_mismatch=0")
        ok = True
    else:
        print("GOLDEN: FAIL mismatch=%d pad_mismatch=%d" % (mismatch, pad_mismatch))
        for b in bad_ops[:10]:
            print("   bad op:", b)
        ok = False
    return ok, plan, q, t_out, in_csum


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hw", type=int, default=0)
    ap.add_argument("--npz", default=None)
    a = ap.parse_args()
    ok, *_ = run(a.hw or None, a.npz)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
