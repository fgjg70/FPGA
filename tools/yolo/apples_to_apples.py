#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Apples-to-apples Round-1 vs Round-2 accuracy on the SAME eval cases.

Round-1 model_int8 npz was not archived (only its JSON summaries were), so the
Round-1 scheme is faithfully re-implemented here:
  * shortcut residual add = engine raw int8 add (`kind: add`), branch + identity
    + sum share ONE quant group, forced SYMMETRIC (zp=0) — the Round-1 contract;
  * same calibration images as Round-1 (bus/dog/horses + 9 deterministic
    augmentations of the first) and the same per-layer-SHIFT quantiser;
  * validated against `data/round1_before/quant_summary_<hw>.json` per-op cos.

Both models are then run over the SAME `evaluate.load_eval_set(hw, imgs, 9)`
case list (5 real photos + 9 deterministic augmentations) and compared
per-case against the float reference.

Writes tools/yolo/data/apples_<hw>.json and prints a per-case table.
Run: python tools/yolo/apples_to_apples.py --hw 320
"""
import argparse
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)

import darknet_lib as dl       # noqa: E402
import detect_lib as de        # noqa: E402
import evaluate as ev          # noqa: E402
import quant_lib as ql         # noqa: E402

CFG = os.path.join(HERE, "data", "yolo-fastest-1.1.cfg")
WEIGHTS = os.path.join(HERE, "data", "yolo-fastest-1.1.weights")
IMGDIR = os.path.join(HERE, "data", "images")
ROUND1_IMAGES = ["bus.jpg", "dog.jpg", "horses.jpg"]     # Round-1 calibration set


# ---------------------------------------------------------------- Round-1 model
def build_groups_round1(plan):
    n = len(plan["tensors"])
    parent = list(range(n))

    def find(a):
        while parent[a] != a:
            parent[a] = parent[parent[a]]
            a = parent[a]
        return a

    def union(a, b):
        ra, rb = find(a), find(b)
        if ra != rb:
            parent[rb] = ra

    add_pairs = []
    for op in plan["ops"]:
        k = op["kind"]
        if k in ("pool", "upsample"):
            union(op["src"], op["dst"])
        elif k == "add":
            union(op["src"], op["dst"])
            add_pairs.append((op["src"], op["dst"]))
        elif k == "cpu_concat":
            for s in op["sources"]:
                union(s["t"], op["dst"])
    roots = [find(t) for t in range(n)]
    add_roots = set(find(a) for (a, b) in add_pairs)
    groups = {}
    for t in range(n):
        groups.setdefault(roots[t], []).append(t)
    return {"roots": roots, "groups": groups, "add_roots": add_roots}


def calibrate_round1(net, folded, plan, images, groups):
    from darknet_lib import forward_float_torch
    rmin, rmax = {}, {}

    def upd(root, o):
        lo, hi = float(np.min(o)), float(np.max(o))
        rmin[root] = min(rmin.get(root, np.inf), lo)
        rmax[root] = max(rmax.get(root, -np.inf), hi)

    input_tid = plan["input_tensor"]
    for img in images:
        upd(groups["roots"][input_tid], img)
        outs = forward_float_torch(net, folded, img)
        for op in plan["ops"]:
            upd(groups["roots"][op["dst"]], outs[op["layer_idx"]])
    return {"groups": groups, "min": rmin, "max": rmax}


def build_round1_model(hw):
    net = dl.build_net(CFG, hw, hw)
    folded = dl.fold_bn(net, dl.load_weights(net, WEIGHTS))
    plan = dl.assign_wq_offsets(dl.plan_ops(net))
    for op in plan["ops"]:
        if op["kind"] == "cpu_add":
            op["kind"] = "add"          # Round-1 primitive
    groups = build_groups_round1(plan)
    imgs = []
    for n in ROUND1_IMAGES:
        imgs.append(de.load_image(os.path.join(IMGDIR, n), hw, hw)[0])
    base = imgs[0]
    for k in range(1, 10):
        aug = ev.augment(base, k)
        imgs.append(de.letterbox(aug, hw, hw)[0].astype(np.float32))
    cal = calibrate_round1(net, folded, plan, imgs, groups)
    gq = ql.choose_group_quants(cal, verbose=False)
    q = ql.quantize_model(net, folded, plan, cal, gq, verbose=False)
    q["groups"] = {"roots": groups["roots"], "add_roots": groups["add_roots"]}
    q["gq"] = gq
    return net, folded, plan, q


def load_round2_model(hw):
    net = dl.build_net(CFG, hw, hw)
    folded = dl.fold_bn(net, dl.load_weights(net, WEIGHTS))
    plan = dl.assign_wq_offsets(dl.plan_ops(net))
    npz = os.path.join(HERE, "data", "model_int8_%d.npz" % hw)
    z = np.load(npz, allow_pickle=False)
    meta = json.loads(bytes(z["meta"]).decode("utf-8"))
    q = {"ops": {}, "adds": {},
         "gq": {int(r): (float(s), int(zp)) for (r, s, zp) in meta["gq"]},
         "roots": meta["roots"],
         "groups": {"roots": meta["roots"], "add_roots": set(meta["add_roots"])}}
    for op_id, op in enumerate(plan["ops"]):
        if op["kind"] == "cpu_add":
            m = meta["ops"][op_id]
            q["adds"][op_id] = {"r_scale": int(m["r_scale"]),
                                "k_add": int(m["k_add"]), "zp_s": int(m["zp_s"])}
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
                "pad": int(m["pad"]), "depthwise": op["kind"] == "dwconv"}
    return net, folded, plan, q


def eval_cases(hw, model, cases):
    net, folded, plan, q = model
    rows = []
    for img, im in cases:
        df = ev.float_dets(net, folded, img, hw)
        di = ev.int8_dets(net, plan, q, img, hw)
        n, mi = de.match_dets(df, di, 0.5)
        rows.append({"case": im["case"], "float": len(df), "int8": len(di),
                     "matched": n, "mean_iou": round(float(mi), 4)})
    tot_f = sum(r["float"] for r in rows)
    tot_m = sum(r["matched"] for r in rows)
    return rows, tot_f, tot_m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hw", type=int, default=320)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()
    hw = args.hw
    out = args.out or os.path.join(HERE, "data", "apples_%d.json" % hw)

    r1net = build_round1_model(hw)
    r2net = load_round2_model(hw)

    # validate the Round-1 reconstruction against the archived Round-1 summaries
    qsum1 = json.load(open(os.path.join(HERE, "data", "round1_before",
                                        "quant_summary_%d.json" % hw), encoding="utf-8"))
    net, folded, plan, q1 = r1net
    files = [os.path.join(IMGDIR, n) for n in ROUND1_IMAGES]
    imgs = [de.load_image(f, hw, hw)[0] for f in files]
    gq1 = q1["gq"]
    roots1 = q1["groups"]["roots"]
    cs = []
    for img in imgs:
        fo = dl.forward_float_torch(net, folded, img)
        s_in, zp_in = gq1[roots1[plan["input_tensor"]]]
        aq = np.clip(np.floor(img / s_in + 0.5) + zp_in, -128, 127).astype(np.int8)
        store, outs = ql.int8_forward(plan, q1, aq)
        for op_id, op in enumerate(plan["ops"]):
            s, zp = gq1[roots1[op["dst"]]]
            dq = ql.dequantize(outs[op_id], s, zp)
            ref = np.transpose(fo[op["layer_idx"]], (1, 2, 0))
            cs.append(dl.cos_sim(dq, ref))
    cs = np.asarray(cs).reshape(len(imgs), -1).mean(axis=0)
    saved = {r["op"]: r["cos"] for r in qsum1["per_op"]}
    diffs = [abs(cs[i] - saved[i]) for i in range(len(cs)) if i in saved]
    print("Round-1 reconstruction validation @hw%d: mean|cos diff| vs archived = %.2e "
          "(max %.2e, n=%d)" % (hw, np.mean(diffs), np.max(diffs), len(diffs)))
    print("  reconstructed: mean %.6f min %.6f ; archived: mean %.6f min %.6f"
          % (cs.mean(), cs.min(),
             np.mean([saved[i] for i in range(len(cs))]),
             np.min([saved[i] for i in range(len(cs))])))

    cases = ev.load_eval_set(hw, IMGDIR, 9)
    r1rows, r1f, r1m = eval_cases(hw, r1net, cases)
    r2rows, r2f, r2m = eval_cases(hw, r2net, cases)

    # ---- scheme isolation: same calibration data for both schemes ----
    def quant_r2_with(calimg):
        plan = dl.assign_wq_offsets(dl.plan_ops(net))
        cal = ql.calibrate_groups(net, folded, plan, calimg)
        gq = ql.choose_group_quants(cal, verbose=False)
        q = ql.quantize_model(net, folded, plan, cal, gq, verbose=False)
        q["groups"] = {"roots": q["groups"]["roots"], "add_roots": set()}
        q["gq"] = gq
        return (net, folded, plan, q)

    def quant_r1_with(calimg):
        plan = dl.assign_wq_offsets(dl.plan_ops(net))
        for op in plan["ops"]:
            if op["kind"] == "cpu_add":
                op["kind"] = "add"
        groups = build_groups_round1(plan)
        cal = calibrate_round1(net, folded, plan, calimg, groups)
        gq = ql.choose_group_quants(cal, verbose=False)
        q = ql.quantize_model(net, folded, plan, cal, gq, verbose=False)
        q["groups"] = {"roots": groups["roots"], "add_roots": groups["add_roots"]}
        q["gq"] = gq
        nn_ = dl.build_net(CFG, hw, hw)
        return (nn_, dl.fold_bn(nn_, dl.load_weights(nn_, WEIGHTS)), plan, q)

    def calimg_set(files, aug_n):
        imgs = [de.load_image(os.path.join(IMGDIR, n), hw, hw)[0] for n in files]
        base = imgs[0]
        for k in range(1, aug_n + 1):
            imgs.append(de.letterbox(ev.augment(base, k), hw, hw)[0].astype(np.float32))
        return imgs

    iso = {}
    try:
        r1_imgs = calimg_set(ROUND1_IMAGES, 9)
        iso["R1_rawadd_calib3"] = eval_cases(hw, quant_r1_with(r1_imgs), cases)
        iso["R2_cpuadd_calib3"] = eval_cases(hw, quant_r2_with(r1_imgs), cases)
        r2_imgs = calimg_set(["bus.jpg", "dog.jpg", "fruits.jpg", "home.jpg", "horses.jpg"], 7)
        iso["R1_rawadd_calib5"] = eval_cases(hw, quant_r1_with(r2_imgs), cases)
        print("\nscheme isolation (same calibration, same cases):")
        for k in iso:
            rows, f, m = iso[k]
            print("  %-22s matched %d/%d = %.2f%%  meanIoU %.3f"
                  % (k, m, f, 100 * m / max(1, f),
                     np.mean([r["mean_iou"] for r in rows])))
    except Exception as e:  # noqa: BLE001 - isolation is diagnostic only
        print("scheme isolation skipped: %s" % e)

    # verify the cpu_add integer formula against an fp32 reference (pre-add store)
    gq_r2 = r2net[3]["gq"]
    roots_r2 = r2net[3]["roots"]
    plan_r2 = r2net[2]
    img = de.load_image(os.path.join(IMGDIR, "dog.jpg"), hw, hw)[0]
    s_in, zp_in = gq_r2[roots_r2[plan_r2["input_tensor"]]]
    aq = np.clip(np.floor(img / s_in + 0.5) + zp_in, -128, 127).astype(np.int8)
    store, outs = ql.int8_forward(plan_r2, r2net[3], aq)
    fchk = []
    for op_id, op in enumerate(plan_r2["ops"]):
        if op["kind"] != "cpu_add":
            continue
        a = r2net[3]["adds"][op_id]
        s_s, zp_s = gq_r2[roots_r2[op["src"]]]
        s_d, zp_d = gq_r2[roots_r2[op["dst"]]]
        c = op["ic"]
        p2 = {"tensors": plan_r2["tensors"], "input_tensor": plan_r2["input_tensor"],
              "ops": plan_r2["ops"][:op_id]}
        sp, _ = ql.int8_forward(p2, r2net[3], aq)
        qs = sp[op["src"]][:, :, :c].astype(np.int64)
        qd = sp[op["dst"]][:, :, :c].astype(np.int64)
        ideal = np.clip(np.floor((s_s * (qs - zp_s) + s_d * (qd - zp_d)) / s_d + 0.5)
                        + zp_d, -128, 127).astype(np.int64)
        d = np.abs(outs[op_id].astype(np.int64) - ideal)
        fchk.append({"op": op_id, "R": a["r_scale"], "K": a["k_add"],
                     "zp_s": a["zp_s"], "max_lsb_diff": int(d.max()),
                     "mean_lsb_diff": float(d.mean())})
    print("cpu_add formula vs fp32 reference @hw%d: %d ops, max|diff| = %d LSB -> %s"
          % (hw, len(fchk), max(x["max_lsb_diff"] for x in fchk),
             "OK" if max(x["max_lsb_diff"] for x in fchk) <= 2 else "SUSPECT"))
    print("\napples-to-apples @hw%d  (%d cases: 5 real + 9 deterministic augmentations)" % (hw, len(cases)))
    print("%-24s | %5s | %5s %5s %6s | %5s %5s %6s" %
          ("case", "float", "R1_i", "R1_m", "R1_rate", "R2_i", "R2_m", "R2_rate"))
    n_r1_worse = n_r1_better = 0
    for a, b in zip(r1rows, r2rows):
        r1r = a["matched"] / max(1, a["float"]) * 100
        r2r = b["matched"] / max(1, b["float"]) * 100
        if r2r < r1r - 1e-9:
            n_r1_worse += 1
        elif r2r > r1r + 1e-9:
            n_r1_better += 1
        print("%-24s | %5d | %5d %5d %5.0f%% | %5d %5d %5.0f%%"
              % (a["case"], a["float"], a["int8"], a["matched"], r1r,
                 b["int8"], b["matched"], r2r))
    print("\nR1: matched %d/%d = %.2f%%  meanIoU %.3f"
          % (r1m, r1f, 100 * r1m / max(1, r1f),
             np.mean([r["mean_iou"] for r in r1rows])))
    print("R2: matched %d/%d = %.2f%%  meanIoU %.3f"
          % (r2m, r2f, 100 * r2m / max(1, r2f),
             np.mean([r["mean_iou"] for r in r2rows])))
    print("per-case: R2 better %d / equal %d / worse %d"
          % (n_r1_better, len(cases) - n_r1_better - n_r1_worse, n_r1_worse))

    rep = {"hw": hw, "num_cases": len(cases),
           "cases": [r["case"] for r in r1rows],
           "round1": {"rows": r1rows, "matched": r1m, "float": r1f,
                      "match_rate": r1m / max(1, r1f),
                      "per_op_cos_mean": float(cs.mean()),
                      "archived_cos_mean": float(np.mean([saved[i] for i in range(len(cs))])),
                      "reconstruction_max_abs_cos_diff": float(np.max(diffs))},
           "round2": {"rows": r2rows, "matched": r2m, "float": r2f,
                      "match_rate": r2m / max(1, r2f)},
           "r2_better": n_r1_better, "r2_equal": len(cases) - n_r1_better - n_r1_worse,
           "r2_worse": n_r1_worse,
           "scheme_isolation": {k: {"matched": v[2], "float": v[1],
                                     "match_rate": v[2] / max(1, v[1]),
                                     "mean_iou": float(np.mean([r["mean_iou"] for r in v[0]]))}
                                 for k, v in iso.items()},
           "cpu_add_formula": {"max_lsb_diff": max(x["max_lsb_diff"] for x in fchk),
                                "ops": fchk}}
    with open(out, "w", encoding="utf-8") as f:
        json.dump(rep, f, indent=1)
    print("saved %s" % out)


if __name__ == "__main__":
    main()
