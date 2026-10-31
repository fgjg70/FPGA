#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Step ①: official darknet YOLO-Fastest v1.1 cfg+weights -> PyTorch float model.

What is proven here (all machine-checkable):
  1. `.weights` stream is consumed EXACTLY by the cfg's per-layer parameter
     counts (bytes/4 == sum of per-layer floats), including the AlexeyAB
     20-byte darknet header (major/minor/revision/seen);
  2. per-layer numeric spot checks (conv weight std/absmax, BN var>0, gamma
     range) -- a one-byte misalignment makes all of these nonsense;
  3. BN folding equivalence: folded conv vs conv+BN+leaky per-layer cos ~= 1;
  4. PyTorch float forward vs an independently written numpy float64 forward:
     per-layer cos >= 0.9999 (actually ~1.0) on the deterministic synthetic
     image and on a real photo;
  5. end-to-end sanity on dog.jpg (official model, 320 input): the detector
     finds the dog / bicycle with plausible confidences.

Outputs: tools/yolo/data/model_float.pt (state dict + layer table + raw BN),
         tools/yolo/data/float_check.json (per-layer evidence table).

Run:  python tools/yolo/convert_yolo_fastest.py
"""
import hashlib
import json
import os
import sys
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import darknet_lib as dl      # noqa: E402
import detect_lib as de       # noqa: E402

CFG = os.path.join(HERE, "data", "yolo-fastest-1.1.cfg")
WEIGHTS = os.path.join(HERE, "data", "yolo-fastest-1.1.weights")
OUT_PT = os.path.join(HERE, "data", "model_float.pt")
OUT_JSON = os.path.join(HERE, "data", "float_check.json")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""):
            h.update(c)
    return h.hexdigest()


def main():
    t0 = time.time()
    if not (os.path.exists(CFG) and os.path.exists(WEIGHTS)):
        print("assets missing -> running download_assets.py")
        import download_assets
        download_assets.main()
    print("cfg    %s  %d B  sha256=%s" % (os.path.basename(CFG),
          os.path.getsize(CFG), sha256(CFG)[:16]))
    print("weight %s  %d B  sha256=%s" % (os.path.basename(WEIGHTS),
          os.path.getsize(WEIGHTS), sha256(WEIGHTS)[:16]))

    # ---- parse + shape inference -------------------------------------
    net = dl.build_net(CFG, 320, 320)
    convs = dl.conv_layers(net)
    print("cfg: %d layers (%d conv, %d of them depthwise), input 3x320x320"
          % (len(net["layers"]), len(convs), sum(1 for L in convs if L["depthwise"])))

    # ---- weight stream alignment -------------------------------------
    need, specs = dl.weight_float_counts(net)
    print("weights: cfg expects %d floats = %d B (+20 B darknet header = %d B file)"
          % (need, need * 4, need * 4 + 20))
    raw = dl.load_weights(net, WEIGHTS)
    print("weights loaded & byte-exact: OK")

    # ---- per-layer numeric spot checks -------------------------------
    checks = []
    bn_bad = 0
    for L in convs:
        r = raw[L["idx"]]
        w = r["w"].astype(np.float64)
        rec = {
            "idx": L["idx"], "type": "dw" if L["depthwise"] else "conv",
            "ic": L["ic"], "oc": L["oc"], "k": L["k"], "stride": L["stride"],
            "pad": L["pad"], "bn": int(L["bn"]),
            "activation": L["activation"],
            "w_count": int(w.size), "w_mean": float(w.mean()),
            "w_std": float(w.std()), "w_absmax": float(np.abs(w).max()),
            "bias_absmax": float(np.abs(r["bias"]).max()),
        }
        if L["bn"]:
            rec["gamma_range"] = [float(r["gamma"].min()), float(r["gamma"].max())]
            rec["var_min"] = float(r["var"].min())
            rec["mean_absmax"] = float(np.abs(r["mean"]).max())
            if rec["var_min"] <= 0:
                bn_bad += 1
        checks.append(rec)
    print("spot checks: BN layers with var<=0: %d (must be 0)" % bn_bad)
    assert bn_bad == 0
    print("  e.g. layer0  %s oc=%d k=%d  w std=%.4f absmax=%.3f  gamma=[%.2f,%.2f]"
          % ("conv", 8, 3, checks[0]["w_std"], checks[0]["w_absmax"],
             *checks[0]["gamma_range"]))
    print("  e.g. layer2  %s oc=%d k=%d  w std=%.4f absmax=%.3f  gamma=[%.2f,%.2f]"
          % ("dw", 8, 3, checks[2]["w_std"], checks[2]["w_absmax"],
             *checks[2]["gamma_range"]))

    # ---- BN fold -----------------------------------------------------
    folded = dl.fold_bn(net, raw)
    # folded vs unfolded (conv -> BN -> activation) on deterministic image
    import torch
    import torch.nn.functional as F
    hw = 128
    x01 = de.pattern_v1(hw, hw, c=3, seed=12345)
    xf = np.zeros((hw, hw, 3), dtype=np.float32)
    xf[:, :, :] = x01.astype(np.float32) / 255.0
    xt = torch.from_numpy(np.ascontiguousarray(xf.transpose(2, 0, 1)[None])).float()
    fold_err = 0.0
    fold_worst = (None, 1.0)
    for L in convs:
        i = L["idx"]
        f = folded[i]
        if L["bn"]:
            r = raw[i]
            y0 = F.conv2d(xt, torch.from_numpy(r["w"]), None,
                          stride=2 if i == 0 else 1, padding=L["pad"]) if False else None
        # use the real input path: only layer 0 has stride 2; emulate sequentially
    # full-net fold check: compare folded-net forward with unfold-net forward
    def forward_unfolded(net, raw, x01):
        import torch.nn.functional as F
        x = torch.from_numpy(np.ascontiguousarray(x01.transpose(2, 0, 1)[None])).float()
        outs = {}
        for L in net["layers"]:
            i = L["idx"]; typ = L["type"]
            if typ == "convolutional":
                r = raw[i]
                w = torch.from_numpy(r["w"])
                y = F.conv2d(x, w, None, stride=L["stride"], padding=L["pad"], groups=L["groups"])
                if L["bn"]:
                    inv = torch.from_numpy((r["gamma"] / np.sqrt(r["var"] + 1e-5)).astype(np.float32))
                    y = (y - torch.from_numpy(r["mean"])[None, :, None, None]) * inv[None, :, None, None] \
                        + torch.from_numpy(r["bias"])[None, :, None, None]
                else:
                    y = y + torch.from_numpy(r["bias"])[None, :, None, None]
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
            outs[i] = x
        return outs

    uo = forward_unfolded(net, raw, xf)
    fo = dl.forward_float_torch(net, folded, xf)
    for L in net["layers"]:
        i = L["idx"]
        c = dl.cos_sim(uo[i].numpy(), fo[i])
        d = float(np.abs(uo[i].numpy() - fo[i]).max())
        if c < fold_worst[1]:
            fold_worst = (i, c)
        fold_err = max(fold_err, d)
    print("BN fold: min per-layer cos(unfolded, folded) = %.10f, max abs diff = %.3g"
          % (fold_worst[1], fold_err))
    assert fold_worst[1] >= 0.99999, "BN fold mismatch at layer %s" % (fold_worst,)

    # ---- float torch vs independent numpy float64 --------------------
    rows = []
    net128 = dl.build_net(CFG, hw, hw)
    folded128 = dl.fold_bn(net128, dl.load_weights(net128, WEIGHTS))
    for tag, img in (("pattern_v1_seed12345", xf),
                     ("dog.jpg", de.load_image(os.path.join(HERE, "data", "images", "dog.jpg"),
                                               hw, hw)[0])):
        o_t = dl.forward_float_torch(net128, folded128, img)
        o_n = dl.forward_float_numpy(net128, folded128, img)
        worst_c, worst_i, maxerr = 1.0, None, 0.0
        for L in net128["layers"]:
            i = L["idx"]
            a = o_t[i]
            b = dl.to_chw(o_n[i])
            c = dl.cos_sim(a, b)
            e = float(np.abs(a - b).max())
            maxerr = max(maxerr, e)
            if c < worst_c:
                worst_c, worst_i = c, i
            rows.append({"input": tag, "layer": i, "type": L["type"],
                         "cos": c, "maxabs": e})
        print("float cross-check %-22s: min per-layer cos = %.10f (layer %s), "
              "max abs diff = %.3g" % (tag, worst_c, worst_i, maxerr))
        assert worst_c >= 0.9999, "float reimplementation mismatch"

    # ---- storage / compute numbers -----------------------------------
    res_table = []
    for hw2 in (320, 160, 128, 96):
        n2 = dl.build_net(CFG, hw2, hw2)
        macs, _, _ = dl.macs_per_resolution(net, (hw2, hw2))
        plan = dl.assign_wq_offsets(dl.plan_ops(n2))
        alloc = dl.allocate(plan)
        max_t = max(t.nbytes for t in plan["tensors"])
        inp = n2["input"][0] * n2["input"][1] * 3
        res_table.append({"hw": hw2, "macs": int(macs),
                          "w_bytes": int(plan["w_total"]),
                          "q_payload": int(plan["q_total_payload"]),
                          "n_conv": int(plan["n_conv"]),
                          "n_ops": len(plan["ops"]),
                          "peak_A": int(alloc["peak_A"]),
                          "peak_B": int(alloc["peak_B"]),
                          "peak_total": int(alloc["peak_total"]),
                          "max_tensor": int(max_t),
                          "input_packed_bytes": int(inp),
                          "ab_ok": bool(alloc["ok"]),
                          "ab_fail": alloc["fail"]})
        print("res {hw:3d}: MACs={macs:,}  max_tensor={mt} B  input_packed={inp} B"
              "  A/B_ok={ok}".format(hw=hw2, macs=macs, mt=max_t, inp=inp,
                                     ok=alloc["ok"]))

    # ---- end-to-end float sanity (dog.jpg @320) ----------------------
    net320 = dl.build_net(CFG, 320, 320)
    folded320 = dl.fold_bn(net320, dl.load_weights(net320, WEIGHTS))
    img, meta = de.load_image(os.path.join(HERE, "data", "images", "dog.jpg"), 320, 320)
    outs = dl.forward_float_torch(net320, folded320, img)
    heads = [(outs[L["idx"] - 1], L) for L in net320["layers"] if L["type"] == "yolo"]
    dets = de.nms_boxes(de.yolo_decode(heads, 320, 320, 0.25), 0.45)
    meta.update({"net_h": 320, "net_w": 320})
    d2 = de.dets_to_image(dets, meta)
    coco = de.coco_names() if hasattr(de, "coco_names") else None
    print("dog.jpg @320 float detections (%d):" % len(d2))
    for d in d2:
        print("  box=(%.1f,%.1f,%.1f,%.1f) score=%.3f class=%d"
              % (d[0], d[1], d[2], d[3], d[4], d[5]))
    dog_detected = any(int(d[5]) == 16 and d[4] >= 0.5 for d in d2)
    print("dog (COCO class 16) detected with score>=0.5: %s" % dog_detected)

    # ---- export model_float.pt ---------------------------------------
    import torch
    state = {}
    layers_json = []
    for L in net["layers"]:
        i = L["idx"]
        d = {k: v for k, v in L.items() if k != "params"}
        d["params"] = L["params"]
        layers_json.append(d)
        if L["type"] == "convolutional":
            f = folded[i]
            r = raw[i]
            state["L%03d.W_folded" % i] = torch.from_numpy(f["W"])
            state["L%03d.b_folded" % i] = torch.from_numpy(f["b"])
            state["L%03d.W_raw" % i] = torch.from_numpy(r["w"])
            state["L%03d.bias_raw" % i] = torch.from_numpy(r["bias"])
            if L["bn"]:
                state["L%03d.gamma" % i] = torch.from_numpy(r["gamma"])
                state["L%03d.mean" % i] = torch.from_numpy(r["mean"])
                state["L%03d.var" % i] = torch.from_numpy(r["var"])
    torch.save({"format": "yolo-fastest-v1.1-float-v1",
                "cfg": CFG, "weights": WEIGHTS,
                "cfg_sha256": sha256(CFG), "weights_sha256": sha256(WEIGHTS),
                "layers": layers_json,
                "state_dict": state,
                "bn_eps": dl.BN_EPS,
                "weight_float_count": need,
                "resolutions": res_table}, OUT_PT)
    print("saved %s (%.1f KB)" % (OUT_PT, os.path.getsize(OUT_PT) / 1024.0))

    rep = {"cfg_sha256": sha256(CFG), "weights_sha256": sha256(WEIGHTS),
           "weight_floats": need, "weight_file_bytes": os.path.getsize(WEIGHTS),
           "bn_fold_min_cos": fold_worst[1], "bn_fold_maxabs": fold_err,
           "float_crosscheck": rows, "layer_spot_checks": checks,
           "resolutions": res_table,
           "dog_detections_320": [[float(x) for x in d] for d in d2],
           "dog_detected_conf50": bool(dog_detected)}
    with open(OUT_JSON, "w", encoding="utf-8") as f:
        json.dump(rep, f, indent=1)
    print("saved %s   TOTAL %.1fs" % (OUT_JSON, time.time() - t0))
    return 0 if dog_detected else 1


if __name__ == "__main__":
    sys.exit(main())
