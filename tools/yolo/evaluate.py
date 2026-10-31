#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""End-to-end float-vs-int8 detection comparison (CONTRACT acceptance).

For every evaluation image:
  * float reference: torch float32 forward -> darknet yolo decode + NMS
  * int8 model: input quantised with the calibrated input-group params,
    integer forward -> dequantised head tensors -> same decode + NMS
  * match boxes class-wise with IoU >= 0.5, report match rate / mean IoU

Also supports deterministic augmentations of the sample image when only a few
real photos are available (network-restricted environment) -- those cases are
labelled `aug<k>` in the output and in the report.

Run:
  python tools/yolo/evaluate.py --hw 128 --npz tools/yolo/data/model_int8_128.npz \
      --images tools/yolo/data/images --augment 9 --out tools/yolo/data/eval_128.json
"""
import argparse
import glob
import json
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)

import darknet_lib as dl       # noqa: E402
import detect_lib as de        # noqa: E402
import quant_lib as ql         # noqa: E402

CFG = os.path.join(HERE, "data", "yolo-fastest-1.1.cfg")
WEIGHTS = os.path.join(HERE, "data", "yolo-fastest-1.1.weights")


def augment(img01, k):
    """Deterministic augmentations of an RGB [0,1] HWC image (k=1..N)."""
    import cv2
    h, w = img01.shape[:2]
    if k % 5 == 1:      # horizontal flip
        return img01[:, ::-1].copy()
    if k % 5 == 2:      # centre crop 80%
        cy, cx = int(h * 0.1), int(w * 0.1)
        return img01[cy:h - cy, cx:w - cx].copy()
    if k % 5 == 3:      # brightness / contrast
        return np.clip(img01 * 1.15 + 0.05, 0, 1).astype(np.float32)
    if k % 5 == 4:      # zoom 70% + pad with 0.5
        nh, nw = int(h * 0.7), int(w * 0.7)
        cy, cx = (h - nh) // 2, (w - nw) // 2
        z = cv2.resize(img01[cy:cy + nh, cx:cx + nw], (w, h), interpolation=cv2.INTER_LINEAR)
        return z.astype(np.float32)
    return np.clip(img01 * 0.9 + 0.02, 0, 1).astype(np.float32)  # k%5==0 darker


def load_eval_set(hw, imgdir, augment_n):
    files = sorted(glob.glob(os.path.join(imgdir, "*.jpg")) +
                   glob.glob(os.path.join(imgdir, "*.png")))
    if not files:
        raise SystemExit("no images in %s" % imgdir)
    cases = []
    for f in files:
        img, meta = de.load_image(f, hw, hw)
        meta.update({"net_h": hw, "net_w": hw, "case": os.path.basename(f),
                     "aug": 0})
        cases.append((img, meta))
    if augment_n:
        # deterministic augmentations of the first real photo
        base = cases[0][0]
        for k in range(1, augment_n + 1):
            aug = augment(base, k)
            img, sc, dx, dy = de.letterbox(aug, hw, hw)
            meta = {"orig_h": aug.shape[0], "orig_w": aug.shape[1],
                    "scale": sc, "dx": dx, "dy": dy,
                    "net_h": hw, "net_w": hw,
                    "case": "%s#aug%d" % (os.path.basename(files[0]), k),
                    "aug": k}
            cases.append((img.astype(np.float32), meta))
    return cases


def float_dets(net, folded, img, hw):
    outs = dl.forward_float_torch(net, folded, img)
    heads = [(outs[L["idx"] - 1], L) for L in net["layers"] if L["type"] == "yolo"]
    dets = de.yolo_decode(heads, hw, hw, 0.25)
    return de.nms_boxes(dets, 0.45)


def int8_dets(net, plan, q, img, hw):
    roots = q["groups"]["roots"]
    gq = q["gq"]
    itid = plan["input_tensor"]
    s_in, zp_in = gq[roots[itid]]
    a_q = np.clip(np.floor(img / s_in + 0.5) + zp_in, -128, 127).astype(np.int8)
    store, outs = ql.int8_forward(plan, q, a_q)
    heads = []
    for L in net["layers"]:
        if L["type"] != "yolo":
            continue
        opid = None
        for oid, op in enumerate(plan["ops"]):
            if op["layer_idx"] == L["idx"] - 1:
                opid = oid
                break
        assert opid is not None
        tid = plan["tensors"][plan["ops"][opid]["dst"]].id
        s, zp = gq[roots[tid]]
        arr = ql.dequantize(outs[opid], s, zp)          # (h,w,C) float
        heads.append((np.transpose(arr, (2, 0, 1)), L))
    dets = de.yolo_decode(heads, hw, hw, 0.25)
    return de.nms_boxes(dets, 0.45)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hw", type=int, default=128)
    ap.add_argument("--npz", default=None)
    ap.add_argument("--images", default=os.path.join(HERE, "data", "images"))
    ap.add_argument("--augment", type=int, default=9,
                    help="number of deterministic augmentations of the first photo")
    ap.add_argument("--out", default=None)
    ap.add_argument("--iou", type=float, default=0.5)
    args = ap.parse_args()
    hw = args.hw
    npz = args.npz or os.path.join(HERE, "data", "model_int8_%d.npz" % hw)
    out = args.out or os.path.join(HERE, "data", "eval_%d.json" % hw)
    t0 = time.time()
    net = dl.build_net(CFG, hw, hw)
    folded = dl.fold_bn(net, dl.load_weights(net, WEIGHTS))
    plan = dl.assign_wq_offsets(dl.plan_ops(net))
    z = np.load(npz, allow_pickle=False)
    meta = json.loads(bytes(z["meta"]).decode("utf-8"))
    assert meta["hw"] == hw
    q = {"ops": {}, "gq": {int(r): (float(s), int(zp)) for (r, s, zp) in meta["gq"]},
         "roots": meta["roots"], "groups": {"roots": meta["roots"],
                                            "add_roots": set(meta["add_roots"])}}
    for op_id, op in enumerate(plan["ops"]):
        if op["kind"] in ("conv", "dwconv", "cpu_conv0"):
            wq = z["op%d_wq" % op_id].astype(np.int8)
            m = meta["ops"][op_id]
            q["ops"][op_id] = {
                "wq": wq, "bias_adj": z["op%d_bias" % op_id].astype(np.int64),
                "mpos": z["op%d_mpos" % op_id].astype(np.int64),
                "shift": int(m["shift"]), "leaky": int(m["leaky"]),
                "zp_in": int(m["zp_in"]), "zp_out": int(m["zp_out"]),
                "s_in": float(m["s_in"]), "s_out": float(m["s_out"]),
                "oc": int(m["oc"]),
                "oc_pad": int(wq.shape[-1 if op["kind"] == "dwconv" else 2]),
                "ic": int(m["ic"]), "k": int(m["k"]), "stride": int(m["stride"]),
                "pad": int(m["pad"]), "depthwise": op["kind"] == "dwconv",
            }
    cases = load_eval_set(hw, args.images, args.augment)
    rows = []
    tot_f = tot_i = tot_match = 0
    ious = []
    for img, im in cases:
        df = float_dets(net, folded, img, hw)
        di = int8_dets(net, plan, q, img, hw)
        n, mi = de.match_dets(df, di, args.iou)
        # reverse direction (count int8 dets without float partner)
        nr, _ = de.match_dets(di, df, args.iou)
        nf, ni = len(df), len(di)
        tot_f += nf
        tot_i += ni
        tot_match += n
        if mi:
            ious.append(mi)
        rows.append({"case": im["case"], "float_dets": nf, "int8_dets": ni,
                     "matched": n, "int8_matched": nr,
                     "mean_iou": round(mi, 4),
                     "float_classes": [int(x) for x in df[:, 5]] if nf else [],
                     "int8_classes": [int(x) for x in di[:, 5]] if ni else [],
                     "float_scores": [round(float(x), 3) for x in df[:, 4]] if nf else [],
                     "int8_scores": [round(float(x), 3) for x in di[:, 4]] if ni else []})
        print("%-24s float=%d int8=%d matched=%d meanIoU=%.3f"
              % (im["case"], nf, ni, n, mi))
    rate = tot_match / max(1, tot_f)
    summary = {"hw": hw, "npz": os.path.basename(npz), "iou_thresh": args.iou,
               "num_cases": len(cases), "augmented_cases": args.augment,
               "float_dets": tot_f, "int8_dets": tot_i, "matched": tot_match,
               "match_rate": round(rate, 4),
               "mean_iou": round(float(np.mean(ious)) if ious else 0.0, 4),
               "per_case": rows}
    with open(out, "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=1)
    print("== hw=%d cases=%d float_dets=%d int8_dets=%d matched=%d "
          "match_rate=%.1f%% meanIoU=%.3f (IoU>=%.2f)" %
          (hw, len(cases), tot_f, tot_i, tot_match, 100 * rate,
           summary["mean_iou"], args.iou))
    print("saved %s  (%.1fs)" % (out, time.time() - t0))
    return 0 if rate >= 0.9 else 1


if __name__ == "__main__":
    sys.exit(main())
