#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""YOLO-Fastest v1.1 int8 PTQ (CONTRACT v0.3.1 §5).

Steps:
  1. parse cfg / load official .weights / fold BN
  2. build primitive execution plan + A/B allocation + W/Q offsets
  3. calibrate activation ranges on real images (letterboxed)
  4. per-group (s_a, zp_a), per-OC weight scales, bias_adj, per-layer SHIFT,
     int16 M_pos  ->  model_int8.npz  (+ meta json inside the npz)
  5. self-checks printed with machine-checkable numbers:
       - int8 weight round-trip error
       - per-layer int8(dequant) vs float reference cosine / max abs error
       - end-to-end int8-vs-float on the calibration images is in evaluate.py

Run:  python tools/yolo/quantize.py [--hw 128] [--images tools/yolo/data/images]
"""
import argparse
import glob
import json
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import darknet_lib as dl          # noqa: E402
import detect_lib as de           # noqa: E402
import quant_lib as ql            # noqa: E402

CFG = os.path.join(HERE, "data", "yolo-fastest-1.1.cfg")
WEIGHTS = os.path.join(HERE, "data", "yolo-fastest-1.1.weights")
IMGDIR = os.path.join(HERE, "data", "images")


def load_net(hw, strict_alloc=False):
    net = dl.build_net(CFG, hw, hw)
    raw = dl.load_weights(net, WEIGHTS)
    folded = dl.fold_bn(net, raw)
    plan = dl.assign_wq_offsets(dl.plan_ops(net))
    alloc = dl.allocate(plan)
    if not alloc["ok"]:
        msg = "A/B allocation FAILED: %s (peak_A=%d peak_B=%d)" % (
            alloc["fail"], alloc["peak_A"], alloc["peak_B"])
        if strict_alloc:
            raise SystemExit(msg)
        print("WARNING: " + msg)
        print("  -> accuracy-only model (no deployable buffer plan) for hw=%d" % hw)
    return net, folded, plan, alloc


def image_files(limit=None):
    files = sorted(glob.glob(os.path.join(IMGDIR, "*.jpg")) +
                   glob.glob(os.path.join(IMGDIR, "*.png")))
    if not files:
        raise SystemExit("no calibration images in %s (run download_assets.py)" % IMGDIR)
    return files[:limit] if limit else files


def per_op_float(outs, plan):
    """Map each plan op id -> float NHWC output (real channels).

    For plan v0.6 copy ops the op output is the written channel slice of the
    concat layer output, so the float reference is sliced the same way.
    """
    m = {}
    for op_id, op in enumerate(plan["ops"]):
        o = outs[op["layer_idx"]]           # (C,H,W)
        o = np.ascontiguousarray(np.transpose(o, (1, 2, 0)))
        if op["kind"] == "copy":
            cd = int(op.get("c_dst", 0))
            c = int(op["ic"])
            m[op_id] = o[:, :, cd:cd + c]
        else:
            m[op_id] = o
    return m


def int8_forward_image(net, plan, q, img_float):
    """Quantise a [0,1] RGB image with the input group params and run int8."""
    roots = q["groups"]["roots"]
    gq = q["gq"]
    itid = plan["input_tensor"]
    s_in, zp_in = gq[roots[itid]]
    a_q = np.clip(np.floor(img_float / s_in + 0.5) + zp_in, -128, 127).astype(np.int8)
    return ql.int8_forward(plan, q, a_q)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hw", type=int, default=128)
    ap.add_argument("--images", default=None)
    ap.add_argument("--calib-limit", type=int, default=0)
    ap.add_argument("--augment-calib", type=int, default=0,
                    help="add N deterministic augmentations of the first image to the calibration set")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()
    hw = args.hw
    out = args.out or os.path.join(HERE, "data", "model_int8_%d.npz" % hw)
    t0 = time.time()
    net, folded, plan, alloc = load_net(hw, strict_alloc=False)
    print("HW=%d  layers=%d  conv_ops=%d  W=%d B  Q_payload=%d B  "
          "alloc peak A=%d B=%d" % (hw, len(net["layers"]), plan["n_conv"],
                                    plan["w_total"], plan["q_total_payload"],
                                    alloc["peak_A"], alloc["peak_B"]))
    files = image_files(args.calib_limit or None)
    if args.images:
        files = sorted(glob.glob(os.path.join(args.images, "*.jpg")))
    imgs = []
    metas = []
    for f in files:
        img, meta = de.load_image(f, hw, hw)
        img = img.astype(np.float32)
        imgs.append(img)
        metas.append((f, meta))
    if args.augment_calib:
        from evaluate import augment
        base = imgs[0]
        for k in range(1, args.augment_calib + 1):
            aug = augment(base, k)
            imgs.append(de.letterbox(aug, hw, hw)[0].astype(np.float32))
    print("calibration images: %d (%s ... %s)" % (len(files),
          os.path.basename(files[0]), os.path.basename(files[-1])))

    cal = ql.calibrate_groups(net, folded, plan, imgs)
    gq = ql.choose_group_quants(cal)
    q = ql.quantize_model(net, folded, plan, cal, gq)
    print("quantization done in %.1fs" % (time.time() - t0))

    # ---------------- self-check 1: weight round-trip --------------------
    w_err = 0.0
    for op_id, p in q["ops"].items():
        W = folded[plan["ops"][op_id]["layer_idx"]]["W"].astype(np.float64)
        rec = p["wq_real"].astype(np.float64) * p["s_w"][:, None, None, None]
        e = float(np.abs(W - rec).max())
        w_err = max(w_err, e)
    print("SELF-CHECK weight: max |W - s_w*w_q| = %.6g" % w_err)

    # ---------------- self-check 2: per-layer int8 vs float --------------
    roots = q["groups"]["roots"]
    rows = []
    worst_cos = 1.0
    worst_maxerr = 0.0
    for f, img in zip(files, imgs):
        outs = dl.forward_float_torch(net, folded, img)
        fmap = per_op_float(outs, plan)
        store, op_out = int8_forward_image(net, plan, q, img)
        for op_id, op in enumerate(plan["ops"]):
            s_out, zp_out = gq[roots[op["dst"]]]
            dq = ql.dequantize(op_out[op_id], s_out, zp_out)
            ref = fmap[op_id].astype(np.float64)
            c = dl.cos_sim(dq.ravel(), ref.ravel())
            me = float(np.abs(dq - ref).max())
            rows.append((op_id, op["kind"], op["layer_idx"], c, me))
            worst_cos = min(worst_cos, c)
            worst_maxerr = max(worst_maxerr, me)
    arr = np.array([(r[0], r[3], r[4]) for r in rows], dtype=np.float64)
    n_ops = len(plan["ops"])
    # per-op statistics across images (mean cos)
    per_op = []
    for op_id in range(n_ops):
        m = arr[arr[:, 0] == op_id]
        per_op.append((op_id, plan["ops"][op_id]["kind"],
                       int(plan["ops"][op_id]["layer_idx"]),
                       float(m[:, 1].mean()), float(m[:, 2].max())))
    print("SELF-CHECK int8 vs float: min per-op cos (over %d imgs x %d ops) = %.6f, "
          "max |err| = %.4g" % (len(files), n_ops, worst_cos, worst_maxerr))
    bad = [r for r in per_op if r[3] < 0.99]
    print("  ops with cos < 0.99: %d" % len(bad))
    for r in sorted(per_op, key=lambda x: x[3])[:8]:
        print("  worst: op%-3d %-10s L%-3d cos %.6f maxerr %.4g" % (r[0], r[1], r[2], r[3], r[4]))

    # ---------------- save model_int8.npz --------------------------------
    meta = {
        "hw": hw,
        "w_total": int(plan["w_total"]),
        "q_total": int(plan["q_total_payload"]),
        "q_base": int(plan["q_base"]),
        "n_ops": n_ops,
        "n_conv": int(plan["n_conv"]),
        "wq_bytes": int(0x50000 + 48 * 1024),
        "ops": [],
        "tensors": [],
        "gq": [[int(r), float(s), int(z)] for r, (s, z) in gq.items()],
        "roots": [int(r) for r in roots],
        "add_roots": sorted(int(r) for r in q["groups"]["add_roots"]),
        "worst_cos": float(worst_cos),
        "weight_roundtrip_maxerr": float(w_err),
    }
    for op_id, op in enumerate(plan["ops"]):
        d = {"id": op_id, "kind": op["kind"], "layer_idx": op["layer_idx"],
             "flags": int(op.get("flags", 0)),
             "k": op["k"], "stride": op["stride"], "pad": op["pad"],
             "leaky": int(op["leaky"]), "ic": op["ic"], "oc": op["oc"],
             "ih": op["ih"], "iw": op["iw"], "oh": op["oh"], "ow": op["ow"],
             "w_off": int(op["w_off"]), "q_off": int(op["q_off"]),
             "src": int(op["src"]) if op["src"] is not None else -1,
             "dst": int(op["dst"])}
        if op["kind"] == "cpu_concat":
            d["sources"] = [{"t": int(s["t"]), "c": int(s["c"])} for s in op["sources"]]
            d["oc_tensor"] = int(op["oc_tensor"])
        if op["kind"] in ("add", "cpu_add"):
            a = q["adds"][op_id]
            d.update({"r_scale": int(a["r_scale"]), "k_add": int(a["k_add"]),
                      "zp_s": int(a["zp_s"]), "zp_d": int(a["zp_d"])})
        if op["kind"] == "copy":
            d.update({"c_src": int(op.get("c_src", 0)),
                      "c_dst": int(op.get("c_dst", 0))})
        if op["kind"] in ("conv", "dwconv", "cpu_conv0"):
            p = q["ops"][op_id]
            d.update({"shift": int(p["shift"]), "zp_in": int(p["zp_in"]),
                      "zp_out": int(p["zp_out"]), "s_in": float(p["s_in"]),
                      "s_out": float(p["s_out"]), "q_payload": int(op["q_payload"]),
                      "q_index": int(op["q_index"])})
        meta["ops"].append(d)
    for t in plan["tensors"]:
        meta["tensors"].append({"id": t.id, "H": t.H, "W": t.W, "C": t.C,
                                "C8": t.C8, "nbytes": int(t.nbytes),
                                "packed": bool(t.packed),
                                "region": t.region, "off": t.off})
    arrays = {"meta": np.frombuffer(json.dumps(meta).encode("utf-8"), dtype=np.uint8)}
    for op_id, p in q["ops"].items():
        arrays["op%d_wq" % op_id] = p["wq"]
        arrays["op%d_bias" % op_id] = p["bias_adj"].astype("<i4")
        arrays["op%d_mpos" % op_id] = p["mpos"].astype("<i2")
        arrays["op%d_sw" % op_id] = p["s_w"].astype("<f4")
        arrays["op%d_payload" % op_id] = p["payload"]
    for op_id, a in q["adds"].items():
        arrays["op%d_payload" % op_id] = a["payload"]
    np.savez_compressed(out, **arrays)
    print("saved %s (%.1f KB)" % (out, os.path.getsize(out) / 1024.0))

    # summary json for report generation
    summary = {
        "hw": hw,
        "w_total": int(plan["w_total"]),
        "q_total": int(plan["q_total_payload"]),
        "n_conv": int(plan["n_conv"]),
        "n_ops": n_ops,
        "alloc_peak_A": int(alloc["peak_A"]),
        "alloc_peak_B": int(alloc["peak_B"]),
        "alloc_peak_total": int(alloc["peak_total"]),
        "weight_roundtrip_maxerr": float(w_err),
        "worst_cos": float(worst_cos),
        "worst_maxerr": float(worst_maxerr),
        "shifts": {str(k): v for k, v in sorted(q["stats"]["shifts"].items())},
        "mpos_max": int(q["stats"]["mpos_max"]),
        "mpos_min_nonzero": int(q["stats"]["mpos_min_nonzero"]),
        "bias_absmax": int(q["stats"]["bias_max"]),
        "per_op": [{"op": int(r[0]), "kind": r[1], "layer": int(r[2]),
                    "cos": float(r[3]), "maxerr": float(r[4])} for r in per_op],
        "calib_images": [os.path.basename(f) for f in files],
        "num_groups": len(gq),
        "kinds": {k: sum(1 for x in plan["ops"] if x["kind"] == k)
                  for k in sorted(set(x["kind"] for x in plan["ops"]))},
        "q_conv_end": int(plan["q_conv_end"]),
        "q_region_bytes": int(plan.get("q_region_bytes", 48 * 1024)),
        "adds": [{"op": int(k), "r_scale": int(v["r_scale"]),
                      "k_add": int(v["k_add"]), "zp_s": int(v["zp_s"]),
                      "ratio": float(v["ratio"])} for k, v in q["adds"].items()],
    }
    sj = os.path.join(HERE, "data", "quant_summary_%d.json" % hw)
    with open(sj, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=1)
    print("saved %s" % sj)
    print("TOTAL %.1fs" % (time.time() - t0))


if __name__ == "__main__":
    main()
