#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Diagnostic: what is the accuracy ceiling of the per-tensor int8 scheme?

Answers (for CONTRACT v0.5 model_int8_<hw>.npz):
  * actual per-layer cos of the integer model (floor requant, as built);
  * per-layer cos if requant rounded instead of floored (quantifies the
    CONTRACT-mandated floor bias);
  * per-layer cos of an ideal float-accumulation QDQ model (activations and
    weights quantised/dequantised, float accumulation, round grid): this is the
    **scheme ceiling** of per-tensor activation quantisation independent of any
    integer/requant implementation detail.

Writes tools/yolo/data/ceiling_<hw>.json (read by gen_report.py).

Run: python tools/yolo/analyze_ceiling.py --hw 128
"""
import argparse
import glob
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)

import darknet_lib as dl       # noqa: E402
import detect_lib as de        # noqa: E402
import golden as G             # noqa: E402
import quant_lib as ql         # noqa: E402

CFG = os.path.join(HERE, "data", "yolo-fastest-1.1.cfg")
WEIGHTS = os.path.join(HERE, "data", "yolo-fastest-1.1.weights")
IMGDIR = os.path.join(HERE, "data", "images")


def requant_round(acc, mpos, mneg, shift, leaky, zp_out):
    off = 1 << (shift - 1)
    pos = np.right_shift(acc * mpos[None, None, :] + off, shift)
    if leaky:
        neg = np.right_shift(acc * mneg[None, None, :] + off, shift)
        y = np.where(acc >= 0, pos, neg)
    else:
        y = pos
    return np.clip(y + zp_out, -128, 127).astype(np.int8)


def stats(cs, total=None):
    cs = np.asarray(cs, dtype=np.float64)
    return {"mean": float(cs.mean()), "min": float(cs.min()),
            "n_below_0.99": int((cs < 0.99).sum()), "n": int(cs.size),
            "total": int(total if total else cs.size)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hw", type=int, default=128)
    args = ap.parse_args()
    hw = args.hw
    npz = os.path.join(HERE, "data", "model_int8_%d.npz" % hw)
    meta, net, plan, q = G.load_model(npz)
    gq = {int(r): (float(s), int(zp)) for (r, s, zp) in meta["gq"]}
    roots = meta["roots"]
    folded = dl.fold_bn(net, dl.load_weights(net, WEIGHTS))
    files = sorted(glob.glob(os.path.join(IMGDIR, "*.jpg")) +
                   glob.glob(os.path.join(IMGDIR, "*.png")))
    imgs = [de.load_image(f, hw, hw)[0] for f in files]
    fouts = [dl.forward_float_torch(net, folded, img) for img in imgs]

    def layer_group(i):
        for op in plan["ops"]:
            if op["layer_idx"] == i:
                return roots[op["dst"]]
        return None

    out = {"hw": hw, "num_images": len(files), "images": [os.path.basename(f) for f in files],
           "per_layer_cos": {}}

    # ---- (a) actual integer model (floor requant) ----
    def int8_cos(round_mode):
        old = ql._requant_vec
        if round_mode:
            ql._requant_vec = requant_round
        cs = []
        try:
            for img, fo in zip(imgs, fouts):
                s_in, zp_in = gq[roots[plan["input_tensor"]]]
                aq = np.clip(np.floor(img / s_in + 0.5) + zp_in, -128, 127).astype(np.int8)
                store, outs = ql.int8_forward(plan, q, aq)
                for op_id, op in enumerate(plan["ops"]):
                    s, zp = gq[roots[op["dst"]]]
                    dq = ql.dequantize(outs[op_id], s, zp)
                    ref = np.transpose(fo[op["layer_idx"]], (1, 2, 0))
                    cs.append(dl.cos_sim(dq, ref))
        finally:
            ql._requant_vec = old
        return np.asarray(cs).reshape(len(imgs), -1).mean(axis=0)

    cs_floor = int8_cos(False)
    cs_round = int8_cos(True)
    out["int8_floor"] = stats(cs_floor)
    out["int8_round_requant"] = stats(cs_round)
    out["int8_floor_per_op"] = [float(v) for v in cs_floor]

    # ---- (b) ideal QDQ float accumulation (scheme ceiling) ----
    import torch
    import torch.nn.functional as F

    def qdq(x, s, zp):
        qq = np.clip(np.floor(x / s + 0.5) + zp, -128, 127)
        return s * (qq - zp)

    def qdq_forward(img):
        x = torch.from_numpy(np.ascontiguousarray(img.transpose(2, 0, 1)[None])).float()
        outs = {}
        for L in net["layers"]:
            i = L["idx"]
            typ = L["type"]
            if typ == "convolutional":
                f = folded[i]
                s_w = np.maximum(np.abs(f["W"].reshape(len(f["W"]), -1)).max(axis=1) / 127.0, 1e-12)
                wq = np.clip(np.floor(f["W"] / s_w[:, None, None, None] + 0.5),
                             -127, 127).astype(np.float32)
                w = torch.from_numpy(wq * s_w[:, None, None, None].astype(np.float32))
                y = F.conv2d(x, w, torch.from_numpy(f["b"]), stride=L["stride"],
                             padding=L["pad"], groups=L["groups"])
                if L["activation"] == "leaky":
                    y = F.leaky_relu(y, 0.1)
                x = y
            elif typ == "maxpool":
                x = F.max_pool2d(x, L["k"], L["stride"], L["pad"])
            elif typ == "upsample":
                x = F.interpolate(x, scale_factor=L["stride"], mode="nearest")
            elif typ == "route":
                x = torch.cat([outs[j] for j in L["input_layers"]], dim=1)
            elif typ == "shortcut":
                x = x + outs[L["from_layer"]]
                if L["activation"] == "leaky":
                    x = F.leaky_relu(x, 0.1)
            outs[i] = x.clone()
            if typ in ("convolutional", "maxpool", "upsample", "route", "shortcut"):
                g = layer_group(i)
                if g is not None:
                    s, zp = gq[g]
                    x = torch.from_numpy(qdq(x.numpy(), s, zp).astype(np.float32))
        return outs

    cs_qdq = []
    for img, fo in zip(imgs, fouts):
        qo = qdq_forward(img)
        for L in net["layers"]:
            i = L["idx"]
            if i in qo:
                cs_qdq.append(dl.cos_sim(qo[i].numpy(), fo[i]))
    cs_qdq = np.asarray(cs_qdq).reshape(len(imgs), -1).mean(axis=0)
    out["qdq_float_ceiling"] = stats(cs_qdq, total=len(net["layers"]))
    out["qdq_per_layer"] = [float(v) for v in cs_qdq]

    # conv-only view for both (the acceptance criterion is usually quoted for convs)
    conv_ops = [k for k, op in enumerate(plan["ops"])
                if op["kind"] in ("conv", "dwconv", "cpu_conv0")]
    out["int8_floor_conv_only"] = stats(cs_floor[conv_ops])
    out["int8_round_conv_only"] = stats(cs_round[conv_ops])
    out["qdq_conv_only"] = stats([cs_qdq[i] for i, L in enumerate(net["layers"])
                                  if L["type"] == "convolutional"])

    dst = os.path.join(HERE, "data", "ceiling_%d.json" % hw)
    with open(dst, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=1)
    print("CEILING hw=%d images=%d" % (hw, len(files)))
    for k in ("int8_floor", "int8_round_requant", "qdq_float_ceiling",
              "int8_floor_conv_only", "int8_round_conv_only", "qdq_conv_only"):
        v = out[k]
        print("  %-22s mean %.6f  min %.6f  <0.99: %d/%d"
              % (k, v["mean"], v["min"], v["n_below_0.99"], v["total"]))
    print("saved %s" % dst)


if __name__ == "__main__":
    main()
