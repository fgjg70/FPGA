#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generate the CONTRACT v0.3.1 integration artifacts in sim/prog/yolo/:

  * plan.json      -- primitive execution plan (§10.1): ops in order, src/dst
                      buffer+offset, W/Q offsets, expected FNV-1a checksums,
                      deterministic pattern_v1 input descriptor
  * model.json     -- layer table (§10) with absolute NN-window offsets
  * yolo_wq.hex    -- 368 KB WQ init image, 94,208 lines of 32-bit little-endian
                      words (W 320 KB @0x00000 + Q 48 KB @0x50000)
  * l<op>_in.hex / l<op>_w.hex / l<op>_q.hex / l<op>_out.hex
                   -- representative layers (conv1x1 / dw3x3 / dw5x5 / pool /
                      add / head conv + cpu_conv0), golden int8 values
  * checksums.txt  -- per-op output FNV-1a over real channels x H x W, logical
                      (y, x, c) byte order (NO channel padding bytes)

Bit-exactness: the generator runs BOTH `quant_lib.int8_forward` (vectorised
reference) and `quant_lib.golden_forward` (independent integer golden) on the
deterministic input image and hard-fails unless every op matches bit for bit.

Run:  python tools/yolo/make_vectors.py [--hw 128] [--outdir sim/prog/yolo]
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
import vec_io as vio           # noqa: E402

Q_BYTES = 48 * 1024
W_BYTES = 0x50000
WQ_BYTES = W_BYTES + Q_BYTES          # 368 KB
NN_W_BASE = 0
NN_A_BASE = dl.A_BASE                 # 0x60000
NN_B_BASE = dl.B_BASE                 # 0x78000

# op numeric codes for model.json (engine op + CPU ops)
OP_CONV, OP_DWCONV, OP_POOL, OP_COPY, OP_ADD = 0, 1, 2, 3, 4
OP_CPU_CONCAT, OP_CPU_COPY, OP_CPU_CONV0, OP_CPU_ADD = 5, 6, 7, 8
KIND_TO_CODE = {"conv": OP_CONV, "dwconv": OP_DWCONV, "pool": OP_POOL,
                "upsample": OP_COPY, "add": OP_ADD, "cpu_concat": OP_CPU_CONCAT,
                "cpu_copy": OP_CPU_COPY, "cpu_conv0": OP_CPU_CONV0,
                "cpu_add": OP_CPU_ADD}


def load_int8_model(hw):
    npz = os.path.join(HERE, "data", "model_int8_%d.npz" % hw)
    if not os.path.exists(npz):
        raise SystemExit("missing %s (run quantize.py --hw %d first)" % (npz, hw))
    z = np.load(npz, allow_pickle=False)
    meta = json.loads(bytes(z["meta"]).decode("utf-8"))
    net = dl.build_net(os.path.join(HERE, "data", "yolo-fastest-1.1.cfg"), hw, hw)
    plan = dl.assign_wq_offsets(dl.plan_ops(net))
    alloc = dl.allocate(plan)
    assert alloc["ok"], "A/B allocation failed: %s" % alloc["fail"]
    assert len(plan["ops"]) == meta["n_ops"], "plan/meta op count mismatch"
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
                "payload": z["op%d_payload" % op_id].astype(np.uint8),
            }
    return meta, net, plan, q


def op_abs_addr(tensor, base_a, base_b):
    region = tensor["region"] if isinstance(tensor, dict) else tensor.region
    off = tensor["off"] if isinstance(tensor, dict) else tensor.off
    return (base_a if region == "A" else base_b) + off


def tensor_buf(t):
    return t["region"] if isinstance(t, dict) else t.region


def tensor_off(t):
    return t["off"] if isinstance(t, dict) else t.off


def build_plan_json(meta, net, plan, q, op_csum, input_csum):
    ops = []
    for op_id, op in enumerate(plan["ops"]):
        d = {"id": op_id, "kind": op["kind"], "k": int(op["k"]),
             "stride": int(op["stride"]), "pad": int(op["pad"]),
             "leaky": int(op["leaky"]), "ih": int(op["ih"]), "iw": int(op["iw"]),
             "ic": int(op["ic"]), "oc": int(op["oc"]),
             "woff": int(op["w_off"]), "qoff": int(op["q_off"]),
             "csum": int(op_csum[op_id])}
        if op["kind"] == "cpu_add":
            a = q["adds"][op_id]
            d["r_scale"] = int(a["r_scale"])
            d["k_add"] = int(a["k_add"])
            d["zp_s"] = int(a["zp_s"])
        if op["kind"] == "cpu_concat":
            srcs = []
            for s in op["sources"]:
                t = plan["tensors"][s["t"]]
                srcs.append({"buf": tensor_buf(t), "off": int(tensor_off(t)),
                             "c": int(s["c"])})
            d["sources"] = srcs
            d["dst"] = {"buf": tensor_buf(plan["tensors"][op["dst"]]),
                        "off": int(tensor_off(plan["tensors"][op["dst"]]))}
            d["oc_tensor"] = int(op["oc_tensor"])
        else:
            st = plan["tensors"][op["src"]]
            dt = plan["tensors"][op["dst"]]
            d["src"] = {"buf": tensor_buf(st), "off": int(tensor_off(st))}
            d["dst"] = {"buf": tensor_buf(dt), "off": int(tensor_off(dt))}
        ops.append(d)
    return {
        "input": {"ih": int(net["input"][0]), "iw": int(net["input"][1]),
                  "ic": 3, "act_off": 0, "packed": True,
                  "gen": {"kind": "pattern_v1", "seed": 12345},
                  "csum": int(input_csum)},
        "wq_bytes": WQ_BYTES, "w_bytes": int(plan["w_total"]),
        "q_base": int(dl.Q_BASE), "q_bytes": Q_BYTES,
        "a_base": NN_A_BASE, "b_base": NN_B_BASE,
        "ops": ops,
        "final_ops": [int(x) for x in plan["final_ops"]],
    }


def build_model_json(meta, net, plan, q, op_csum, input_csum):
    layers = []
    for op_id, op in enumerate(plan["ops"]):
        flags = 0
        if op["kind"] == "dwconv":
            flags |= 1
        if op["leaky"]:
            flags |= 2
        if op["kind"] == "upsample":
            flags |= 8
        if op["kind"] == "pool":
            flags |= 16
        if op["kind"] == "cpu_concat":
            st = plan["tensors"][op["sources"][0]["t"]]
            src_abs = op_abs_addr(st, NN_A_BASE, NN_B_BASE)
        else:
            st = plan["tensors"][op["src"]]
            src_abs = op_abs_addr(st, NN_A_BASE, NN_B_BASE)
        dt = plan["tensors"][op["dst"]]
        layers.append({
            "idx": op_id, "op": KIND_TO_CODE[op["kind"]],
            "k": int(op["k"]), "stride": int(op["stride"]), "pad": int(op["pad"]),
            "ic": int(op["ic"]), "oc": int(op["oc"]),
            "ih": int(op["ih"]), "iw": int(op["iw"]),
            "oh": int(op["oh"]), "ow": int(op["ow"]),
            "flags": flags,
            "w_off": int(op["w_off"]), "q_off": int(op["q_off"]),
            "src": int(src_abs), "dst": int(op_abs_addr(dt, NN_A_BASE, NN_B_BASE)),
        })
    return {
        "input_h": int(net["input"][0]), "input_w": int(net["input"][1]),
        "wq_bytes": WQ_BYTES,
        "layers": layers,
        "checksums": {"input": int(input_csum),
                      "per_op": {str(k): int(v) for k, v in op_csum.items()}},
    }


def build_wq_plane(plan, q):
    plane = np.zeros(WQ_BYTES, dtype=np.uint8)
    for op_id, op in enumerate(plan["ops"]):
        if not op.get("w_bytes"):
            continue
        p = q["ops"][op_id]
        wb = np.ascontiguousarray(p["wq"], dtype=np.int8).view(np.uint8).ravel()
        off = op["w_off"]
        assert off + wb.size <= W_BYTES, "W region overflow at op %d" % op_id
        plane[off:off + wb.size] = wb
        payload = np.ascontiguousarray(p["payload"], dtype=np.uint8)
        qo = op["q_off"]
        assert qo + payload.size <= W_BYTES + Q_BYTES, "Q region overflow at op %d" % op_id
        plane[qo:qo + payload.size] = payload
    assert plan["w_total"] <= W_BYTES, "W %d > %d" % (plan["w_total"], W_BYTES)
    assert plan["q_total_payload"] <= Q_BYTES, \
        "Q %d > %d" % (plan["q_total_payload"], Q_BYTES)
    return plane


def select_representatives(plan):
    reps = []
    used = set()

    def first(pred, label):
        for op_id, op in enumerate(plan["ops"]):
            if op_id in used:
                continue
            if pred(op):
                used.add(op_id)
                reps.append((op_id, label))
                return op_id
        return None

    first(lambda o: o["kind"] == "cpu_conv0", "cpu_conv0")
    first(lambda o: o["kind"] == "conv" and o["k"] == 1 and not o["depthwise"]
          and o["ic"] >= 48 and o["oc"] >= 48, "conv1x1")
    first(lambda o: o["kind"] == "dwconv" and o["k"] == 3, "dwconv3x3")
    first(lambda o: o["kind"] == "dwconv" and o["k"] == 5, "dwconv5x5")
    first(lambda o: o["kind"] == "pool" and o["k"] == 9, "pool9")
    first(lambda o: o["kind"] == "cpu_add", "cpu_add")
    first(lambda o: o["kind"] == "conv" and o["oc"] == 255, "head_conv255")
    first(lambda o: o["kind"] == "upsample", "upsample")
    return reps


def write_vectors(plan, q, golden_store, golden_out, reps, outdir, input_pattern):
    files = []
    for op_id, label in reps:
        op = plan["ops"][op_id]
        st = plan["tensors"][op["src"]]
        dt = plan["tensors"][op["dst"]]
        if op["kind"] == "cpu_conv0":
            in_arr = input_pattern           # packed (H,W,3)
        else:
            in_arr = golden_store[op["src"]][:, :, :st.C]
        out_arr = golden_out[op_id]
        base = os.path.join(outdir, "l%d" % op_id)
        vio.write_i8_hex(in_arr, base + "_in.hex")
        vio.write_i8_hex(out_arr, base + "_out.hex")
        files.append((base + "_in.hex", in_arr.size, label + " input"))
        files.append((base + "_out.hex", out_arr.size, label + " golden output"))
        if op["kind"] in ("conv", "dwconv", "cpu_conv0"):
            p = q["ops"][op_id]
            wb = np.ascontiguousarray(p["wq"], dtype=np.int8)
            vio.write_i8_hex(wb, base + "_w.hex")
            qw = vio.bytes_to_u32_le(p["payload"])
            vio.write_u32_hex(qw, base + "_q.hex")
            files.append((base + "_w.hex", wb.size, label + " weights (§6 padding)"))
            files.append((base + "_q.hex", qw.size, label + " Q payload (32-bit words)"))
    return files


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hw", type=int, default=128)
    ap.add_argument("--outdir", default=os.path.join(ROOT, "sim", "prog", "yolo"))
    args = ap.parse_args()
    hw = args.hw
    outdir = args.outdir
    os.makedirs(outdir, exist_ok=True)
    t0 = time.time()

    meta, net, plan, q = load_int8_model(hw)
    # deterministic input image (CONTRACT v0.3.2 pattern_v1)
    x = de.pattern_v1(hw, hw, c=3, seed=12345)
    input_csum = vio.fnv1a_int8(x)

    store_ref, out_ref = ql.int8_forward(plan, q, x)
    store_g, out_g = ql.golden_forward(plan, q, x)
    mismatch = 0
    bad = []
    for op_id in range(len(plan["ops"])):
        d = np.abs(out_ref[op_id].astype(np.int16) - out_g[op_id].astype(np.int16))
        n = int((d != 0).sum())
        if n:
            mismatch += n
            bad.append((op_id, plan["ops"][op_id]["kind"], n, int(d.max())))
    for tid in store_g:
        if tid == plan["input_tensor"]:
            continue
        n = int((store_ref[tid].astype(np.int16) != store_g[tid].astype(np.int16)).sum())
        mismatch += n
    assert mismatch == 0, "golden/reference mismatch=%d %s" % (mismatch, bad[:5])
    print("BIT-EXACT: golden vs reference mismatch=0 over %d ops" % len(plan["ops"]))

    op_csum = {}
    for op_id in range(len(plan["ops"])):
        op_csum[op_id] = vio.fnv1a_int8(out_g[op_id])

    # ---- plan.json / model.json / yolo_wq.hex ---------------------------
    plan_json = build_plan_json(meta, net, plan, q, op_csum, input_csum)
    with open(os.path.join(outdir, "plan.json"), "w", encoding="utf-8") as f:
        json.dump(plan_json, f, indent=1)
    model_json = build_model_json(meta, net, plan, q, op_csum, input_csum)
    with open(os.path.join(outdir, "model.json"), "w", encoding="utf-8") as f:
        json.dump(model_json, f, indent=1)
    plane = build_wq_plane(plan, q)
    words = vio.bytes_to_u32_le(plane)
    assert words.size == WQ_BYTES // 4 == 94208, \
        "yolo_wq.hex line count %d != 94208" % words.size
    vio.write_u64_hex  # keep import used
    vio.write_u32_hex(words, os.path.join(outdir, "yolo_wq.hex"))
    with open(os.path.join(outdir, "yolo_wq.hex"), "r", encoding="ascii") as f:
        n_lines = sum(1 for _ in f)
    assert n_lines == 94208, "yolo_wq.hex has %d lines != 94208" % n_lines
    print("yolo_wq.hex: 94,208 lines / %d B plane (W %d B + Q %d B)"
          % (WQ_BYTES, plan["w_total"], plan["q_total_payload"]))

    # ---- representative vectors ---------------------------------------
    reps = select_representatives(plan)
    files = write_vectors(plan, q, store_g, out_g, reps, outdir, x)

    # ---- checksums.txt --------------------------------------------------
    lines = []
    lines.append("# YOLO-Fastest v1.1 int8 golden checksums (CONTRACT v0.3.1 §10)")
    lines.append("# FNV-1a 32: h=2166136261; for b: h^=b; h=(h*16777619)&0xFFFFFFFF")
    lines.append("# scope: real channels x H x W, compact NHWC logical order (y,x,c);")
    lines.append("#        channel padding bytes are NOT included.")
    lines.append("# hw=%d wq_bytes=%d w_bytes=%d q_base=0x%05x q_bytes=%d"
                 % (hw, WQ_BYTES, plan["w_total"], dl.Q_BASE, Q_BYTES))
    lines.append("input 0x%08x  # pattern_v1 seed=12345 packed 3B/pixel" % input_csum)
    lines.append("filter 0x%08x  # FNV of b'YOLO-FASTEST-V1.1-INT8-128'" %
                 vio.fnv1a_bytes(b"YOLO-FASTEST-V1.1-INT8-" + str(hw).encode()))
    for op_id, op in enumerate(plan["ops"]):
        lines.append("op %3d kind=%-9s layer=%-3d 0x%08x"
                     % (op_id, op["kind"], op["layer_idx"], op_csum[op_id]))
    with open(os.path.join(outdir, "checksums.txt"), "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")

    with open(os.path.join(outdir, "representative_layers.json"), "w", encoding="utf-8") as f:
        json.dump([{"op": int(i), "label": lab} for i, lab in reps], f, indent=1)

    print("representative ops:", [(i, lab) for i, lab in reps])
    for path, n, what in files:
        print("  %-32s %8d B  %s" % (os.path.basename(path), n, what))
    print("plan.json: %d ops, final_ops=%s, input csum=0x%08x"
          % (len(plan["ops"]), plan["final_ops"], input_csum))
    print("TOTAL %.1fs" % (time.time() - t0))


if __name__ == "__main__":
    main()
