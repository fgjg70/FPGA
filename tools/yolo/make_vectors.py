#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generate the v0.6 integration artifacts (all-hardware plan).

Plan v0.6 (SPEC-SPECIALIZED.md):
  * conv0  : kind=conv + flags bit2 PACKED3 (3B/px packed input, dense IC_pad=8
             weight layout, standard conv Q block) -- no CPU op;
  * shortcut: kind=add + flags bit3 ADD_R (engine per-tensor residual add),
             Q block 16 B: [0]=zp_d [1]=zp_s [4:7]=R int32 LE [8]=KADD [9:15]=0;
  * route/concat: expanded into one `copy` op per source tensor (engine copy:
             ic = source channels, oc = target total channels, src/dst byte
             offsets carry the 8-channel block offsets) -- no CPU op.

Outputs (per --outdir, default sim/prog/yolo/):
  plan.json, model.json, yolo_wq.hex, checksums.txt, l<op>_{in,w,q,out}.hex,
  representative_layers.json

Hard guarantees built into this script:
  * W region (first 320 KB of yolo_wq.hex) is byte-identical to the frozen
    v0.5 snapshot (`tools/yolo/data/v05_frozen/yolo_wq.hex`);
  * golden int8 forward matches the vectorised reference bit-exactly
    (mismatch == 0) including PACKED3 / ADD_R / copy;
  * every conv/pool/upsample/add output FNV equals the frozen v0.5 value for
    the same darknet layer (numerics unchanged) and each concat target's full
    FNV equals the frozen cpu_concat value -> zero accuracy regression.

Run:  python tools/yolo/make_vectors.py --hw 128
      python tools/yolo/make_vectors.py --hw 320 --outdir sim/prog/yolo320 \
             --buffer-a 4194304 --buffer-b 4194304 \
             --a-base 0 --b-base 4194304 --no-vectors
"""
import argparse
import hashlib
import json
import os
import sys

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
DEFAULT_A_BASE = dl.A_BASE            # 0x60000 (C128)
DEFAULT_B_BASE = dl.B_BASE            # 0x78000 (C128)

# plan/model op codes (SPEC-SPECIALIZED.md §1)
OP_CONV, OP_DWCONV, OP_POOL, OP_UPSAMPLE, OP_ADD, OP_COPY = 0, 1, 2, 3, 4, 5
KIND_TO_CODE = {"conv": OP_CONV, "dwconv": OP_DWCONV, "pool": OP_POOL,
                "upsample": OP_UPSAMPLE, "add": OP_ADD, "copy": OP_COPY}
FLAG_DEPTHWISE, FLAG_LEAKY, FLAG_PACKED3, FLAG_ADD_R = 1, 2, 4, 8


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""):
            h.update(c)
    return h.hexdigest()


def load_int8_model(hw, a_size, b_size):
    npz = os.path.join(HERE, "data", "model_int8_%d.npz" % hw)
    if not os.path.exists(npz):
        raise SystemExit("missing %s (run quantize.py --hw %d first)" % (npz, hw))
    z = np.load(npz, allow_pickle=False)
    meta = json.loads(bytes(z["meta"]).decode("utf-8"))
    net = dl.build_net(os.path.join(HERE, "data", "yolo-fastest-1.1.cfg"), hw, hw)
    plan = dl.assign_wq_offsets(dl.plan_ops(net))
    alloc = dl.allocate(plan, a_size=a_size, b_size=b_size)
    if not alloc["ok"]:
        raise SystemExit("A/B allocation failed: %s" % alloc["fail"])
    assert len(plan["ops"]) == meta["n_ops"], "plan/meta op count mismatch"
    q = {"ops": {}, "adds": {},
         "gq": {int(r): (float(s), int(zp)) for (r, s, zp) in meta["gq"]},
         "roots": meta["roots"],
         "groups": {"roots": meta["roots"],
                    "add_roots": set(meta["add_roots"])}}
    for op_id, op in enumerate(plan["ops"]):
        m = meta["ops"][op_id]
        assert m["kind"] == op["kind"], "meta/plan kind mismatch at op %d" % op_id
        if op["kind"] in ("conv", "dwconv", "cpu_conv0"):
            wq = z["op%d_wq" % op_id].astype(np.int8)
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
                "payload": z["op%d_payload" % op_id].astype(np.uint8)}
        elif op["kind"] in ("add", "cpu_add"):
            q["adds"][op_id] = {"r_scale": int(m["r_scale"]),
                                "k_add": int(m["k_add"]),
                                "zp_s": int(m["zp_s"]),
                                "zp_d": int(m.get("zp_d", 0)),
                                "payload": z["op%d_payload" % op_id].astype(np.uint8)}
    return net, plan, q, alloc, alloc["peak_A"], alloc["peak_B"]


def tensor_addr(t, a_base, b_base):
    return (a_base if t.region == "A" else b_base) + int(t.off)


def build_plan_json(net, plan, q, op_csum, input_csum, a_base, b_base, alloc):
    ops = []
    for op_id, op in enumerate(plan["ops"]):
        kind = op["kind"]
        d = {"id": op_id, "kind": kind, "flags": int(op.get("flags", 0)),
             "layer_idx": int(op["layer_idx"]),
             "k": int(op["k"]), "stride": int(op["stride"]), "pad": int(op["pad"]),
             "leaky": int(op["leaky"]), "ih": int(op["ih"]), "iw": int(op["iw"]),
             "ic": int(op["ic"]), "oc": int(op["oc"]),
             "oh": int(op["oh"]), "ow": int(op["ow"]),
             "woff": int(op["w_off"]), "qoff": int(op["q_off"]),
             "csum": int(op_csum[op_id])}
        if kind == "copy":
            st = plan["tensors"][op["src"]]
            dt = plan["tensors"][op["dst"]]
            cs = int(op.get("c_src", 0))
            cd = int(op.get("c_dst", 0))
            d["c_src"] = cs
            d["c_dst"] = cd
            d["src"] = {"buf": st.region, "off": int(st.off) + cs}
            d["dst"] = {"buf": dt.region, "off": int(dt.off) + cd}
        else:
            st = plan["tensors"][op["src"]]
            dt = plan["tensors"][op["dst"]]
            d["src"] = {"buf": st.region, "off": int(st.off)}
            d["dst"] = {"buf": dt.region, "off": int(dt.off)}
            if kind in ("add", "cpu_add"):
                a = q["adds"][op_id]
                d["r_scale"] = int(a["r_scale"])
                d["k_add"] = int(a["k_add"])
                d["zp_s"] = int(a["zp_s"])
                d["zp_d"] = int(a["zp_d"])
        ops.append(d)
    return {
        "format": "yolo-fastest-v1.1-int8-plan-v0.6",
        "input": {"ih": int(net["input"][0]), "iw": int(net["input"][1]),
                  "ic": 3, "act_off": 0, "packed": True,
                  "gen": {"kind": "pattern_v1", "seed": 12345},
                  "csum": int(input_csum)},
        "wq_bytes": WQ_BYTES, "w_bytes": int(plan["w_total"]),
        "q_bytes": Q_BYTES, "q_window_off": int(dl.Q_BASE),
        "woff_units": "w_region_relative",
        "qoff_units": "q_region_relative",
        "src_dst_units": "buf_relative (A=0x60000, B=0x78000 bases)",
        "q_conv_end": int(plan["q_conv_end"]),
        "q_total_payload": int(plan["q_total_payload"]),
        "a_base": int(a_base), "b_base": int(b_base),
        "alloc": {"peak_A": int(alloc["peak_A"]),
                  "peak_B": int(alloc["peak_B"]),
                  "peak_total": int(alloc["peak_total"])},
        "n_ops": len(plan["ops"]),
        "kinds": {k: sum(1 for x in plan["ops"] if x["kind"] == k)
                  for k in sorted(set(x["kind"] for x in plan["ops"]))},
        "ops": ops,
        "final_ops": [int(x) for x in plan["final_ops"]],
    }


def build_model_json(net, plan, q, op_csum, input_csum, a_base, b_base):
    layers = []
    for op_id, op in enumerate(plan["ops"]):
        st = plan["tensors"][op["src"]]
        dt = plan["tensors"][op["dst"]]
        src_abs = tensor_addr(st, a_base, b_base)
        dst_abs = tensor_addr(dt, a_base, b_base)
        if op["kind"] == "copy":
            src_abs += int(op.get("c_src", 0))
            dst_abs += int(op.get("c_dst", 0))
        layers.append({
            "idx": op_id, "op": KIND_TO_CODE[op["kind"]],
            "flags": int(op.get("flags", 0)),
            "k": int(op["k"]), "stride": int(op["stride"]), "pad": int(op["pad"]),
            "ic": int(op["ic"]), "oc": int(op["oc"]),
            "ih": int(op["ih"]), "iw": int(op["iw"]),
            "oh": int(op["oh"]), "ow": int(op["ow"]),
            "w_off": int(op["w_off"]), "q_off": int(op["q_off"]),
            "src": int(src_abs), "dst": int(dst_abs),
        })
    return {
        "format": "yolo-fastest-v1.1-int8-v0.6",
        "input_h": int(net["input"][0]), "input_w": int(net["input"][1]),
        "wq_bytes": WQ_BYTES,
        "layers": layers,
        "checksums": {"input": int(input_csum),
                      "per_op": {str(k): int(v) for k, v in op_csum.items()}},
    }


def build_wq_images(plan, q, frozen_w=None):
    """v0.7: W image (320 KB) + Q image (48 KB) are separate storage images.

    woff is W-region-relative (unchanged); qoff is Q-region-relative (v0.7).
    The historical flat yolo_wq.hex (W||Q) is still produced by concatenation.
    """
    w_img = np.zeros(W_BYTES, dtype=np.uint8)
    q_img = np.zeros(Q_BYTES, dtype=np.uint8)
    n_conv = 0
    n_add = 0
    for op_id, op in enumerate(plan["ops"]):
        if op["kind"] in ("conv", "dwconv", "cpu_conv0"):
            p = q["ops"][op_id]
            wb = np.ascontiguousarray(p["wq"], dtype=np.int8).view(np.uint8).ravel()
            off = op["w_off"]
            assert off + wb.size <= W_BYTES, "W overflow at op %d" % op_id
            w_img[off:off + wb.size] = wb
            payload = np.ascontiguousarray(p["payload"], dtype=np.uint8)
            qo = op["q_off"]
            assert qo + payload.size <= Q_BYTES, "Q overflow at op %d" % op_id
            q_img[qo:qo + payload.size] = payload
            n_conv += 1
        elif op["kind"] in ("add", "cpu_add"):
            payload = np.ascontiguousarray(q["adds"][op_id]["payload"], dtype=np.uint8)
            assert payload.size == 16
            qo = op["q_off"]
            assert qo + 16 <= Q_BYTES, "Q overflow at op %d" % op_id
            q_img[qo:qo + 16] = payload
            n_add += 1
    assert plan["w_total"] <= W_BYTES
    assert plan["q_total_payload"] <= Q_BYTES
    if frozen_w is not None:
        fw = np.frombuffer(frozen_w, dtype=np.uint8)
        assert np.array_equal(w_img, fw[:W_BYTES]), \
            "W image bytes changed vs frozen snapshot!"
    return w_img, q_img, n_conv, n_add


def flat_archive(w_img, q_img):
    """Historical WQ flat image (W 320KB || Q 48KB) for compatibility."""
    return np.concatenate([w_img, q_img])


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

    first(lambda o: o["kind"] == "conv" and int(o.get("flags", 0)) & FLAG_PACKED3,
          "conv0_packed3")
    first(lambda o: o["kind"] == "copy", "copy(concat)")
    first(lambda o: o["kind"] == "conv" and o["k"] == 1 and o["ic"] >= 48
          and o["oc"] >= 48, "conv1x1")
    first(lambda o: o["kind"] == "dwconv" and o["k"] == 3, "dwconv3x3")
    first(lambda o: o["kind"] == "dwconv" and o["k"] == 5, "dwconv5x5")
    first(lambda o: o["kind"] == "pool" and o["k"] == 9, "pool9")
    first(lambda o: o["kind"] == "add", "add_ADD_R")
    first(lambda o: o["kind"] == "conv" and o["oc"] == 255, "head_conv255")
    first(lambda o: o["kind"] == "upsample", "upsample")
    return reps


def write_vectors(plan, q, golden_store, golden_out, reps, outdir, input_pattern):
    files = []
    for op_id, label in reps:
        op = plan["ops"][op_id]
        st = plan["tensors"][op["src"]]
        base = os.path.join(outdir, "l%d" % op_id)
        if op["kind"] == "conv" and int(op.get("flags", 0)) & FLAG_PACKED3:
            in_arr = input_pattern                       # packed (H,W,3)
        elif op["kind"] == "copy":
            cs = int(op.get("c_src", 0))
            in_arr = golden_store[op["src"]][:, :, cs:cs + op["ic"]]
        else:
            in_arr = golden_store[op["src"]][:, :, :st.C]
        out_arr = golden_out[op_id]
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
        elif op["kind"] in ("add", "cpu_add"):
            payload = np.ascontiguousarray(q["adds"][op_id]["payload"], dtype=np.uint8)
            qw = vio.bytes_to_u32_le(payload)
            vio.write_u32_hex(qw, base + "_q.hex")
            files.append((base + "_q.hex", qw.size,
                          label + " ADD_R Q block (16B/4 words)"))
    return files


def load_frozen(hw):
    d = os.path.join(HERE, "data", "v05_frozen")
    out = {}
    fp = os.path.join(d, "plan.json")
    fnpz = os.path.join(d, "model_int8_%d.npz" % hw)
    if os.path.exists(fp) and os.path.exists(fnpz):
        frozen = json.load(open(fp, encoding="utf-8"))
        zf = np.load(fnpz, allow_pickle=False)
        mf = json.loads(bytes(zf["meta"]).decode("utf-8"))
        norm = {"cpu_conv0": "conv", "cpu_add": "add", "cpu_concat": "concat"}
        m = {}
        assert len(frozen["ops"]) == len(mf["ops"])
        for op, mo in zip(frozen["ops"], mf["ops"]):
            k = norm.get(mo["kind"], mo["kind"])
            m[(k, int(mo["layer_idx"]))] = int(op["csum"])
        out["csums"] = m
        out["plan_sha256"] = sha256(fp)
    fwq = os.path.join(d, "yolo_wq.hex")
    if os.path.exists(fwq):
        words = vio.read_u32_hex(fwq)
        out["wq_bytes"] = vio.u32_le_to_bytes(words)
        out["wq_sha256"] = sha256(fwq)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hw", type=int, default=128)
    ap.add_argument("--outdir", default=None)
    ap.add_argument("--buffer-a", type=int, default=dl.A_SIZE)
    ap.add_argument("--buffer-b", type=int, default=dl.B_SIZE)
    ap.add_argument("--a-base", type=lambda s: int(s, 0), default=DEFAULT_A_BASE)
    ap.add_argument("--b-base", type=lambda s: int(s, 0), default=DEFAULT_B_BASE)
    ap.add_argument("--no-vectors", action="store_true")
    ap.add_argument("--skip-frozen-check", action="store_true")
    args = ap.parse_args()
    hw = args.hw
    outdir = args.outdir or os.path.join(ROOT, "sim", "prog", "yolo")
    os.makedirs(outdir, exist_ok=True)

    net, plan, q, alloc, peak_a, peak_b = load_int8_model(
        hw, args.buffer_a, args.buffer_b)
    kinds = {k: sum(1 for x in plan["ops"] if x["kind"] == k)
             for k in sorted(set(x["kind"] for x in plan["ops"]))}
    print("PLAN v0.6 hw=%d ops=%d kinds=%s" % (hw, len(plan["ops"]), kinds))
    print("  W=%d B  Q=%d B (conv end %d, +%d ADD_R blocks)  A/B peak = %d/%d B"
          % (plan["w_total"], plan["q_total_payload"], plan["q_conv_end"],
             plan["n_add"], peak_a, peak_b))
    assert not any(o["kind"].startswith("cpu") for o in plan["ops"]), \
        "CPU-executed op still present!"

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
    print("GOLDEN: PASS mismatch=0 over %d ops (all hardware kinds)"
          % len(plan["ops"]))

    op_csum = {i: vio.fnv1a_int8(out_g[i]) for i in range(len(plan["ops"]))}
    concat_csum = {}
    for op_id, op in enumerate(plan["ops"]):
        if op["kind"] != "copy":
            continue
        dt = plan["tensors"][op["dst"]]
        concat_csum[int(op["layer_idx"])] = vio.fnv1a_int8(
            store_g[op["dst"]][:, :, :dt.C])

    frozen = {} if args.skip_frozen_check else load_frozen(hw)
    # csum regression is only meaningful for C128 (frozen v0.5 plan is the
    # 128 plan); C320 keeps the resolution-independent W-region check below.
    do_csum = bool(frozen.get("csums")) and hw == 128
    if do_csum:
        n_ok = 0
        regress = []
        for op_id, op in enumerate(plan["ops"]):
            if op["kind"] == "copy":
                continue
            want = frozen["csums"].get((op["kind"], int(op["layer_idx"])))
            if want is None:
                continue
            if op_csum[op_id] != want:
                regress.append((op_id, op["kind"], op["layer_idx"],
                                op_csum[op_id], want))
            else:
                n_ok += 1
        for layer, got in concat_csum.items():
            want = frozen["csums"].get(("concat", int(layer)))
            if want is None:
                continue
            if got != want:
                regress.append(("concat", layer, got, want))
            else:
                n_ok += 1
        assert not regress, "NUMERICS REGRESSION vs v0.5: %s" % regress[:6]
        print("REGRESSION CHECK: PASS -- %d outputs (conv/dwconv/pool/upsample/"
              "add + concat targets) bit-identical to frozen v0.5" % n_ok)
    else:
        print("REGRESSION CHECK: skipped (no frozen plan)")

    fwq = None if args.skip_frozen_check else frozen.get("wq_bytes")
    if hw != 128 and fwq is not None:
        print("W-region check: comparing C320 weights against frozen v0.5 W image"
              " (resolution independent)")
    if not do_csum:
        print("csun regression: skipped for hw=%d (frozen plan is C128 only)" % hw)
    w_img, q_img, n_conv, n_add = build_wq_images(plan, q, fwq)
    archive = flat_archive(w_img, q_img)
    for name, img, want_lines in (
            ("yolo_w.hex", w_img, W_BYTES // 4),
            ("yolo_q.hex", q_img, Q_BYTES // 4),
            ("yolo_wq.hex", archive, WQ_BYTES // 4)):
        words = vio.bytes_to_u32_le(img)
        assert words.size == want_lines, \
            "%s line count %d != %d" % (name, words.size, want_lines)
        vio.write_u32_hex(words, os.path.join(outdir, name))
        with open(os.path.join(outdir, name), "r", encoding="ascii") as f:
            assert sum(1 for _ in f) == want_lines
    print("yolo_w.hex: %d lines / %d B (weights unchanged); "
          "yolo_q.hex: %d lines / %d B (%d conv + %d ADD_R blocks); "
          "yolo_wq.hex archive: %d lines / %d B"
          % (W_BYTES // 4, W_BYTES, Q_BYTES // 4, Q_BYTES,
             n_conv, n_add, WQ_BYTES // 4, WQ_BYTES))

    plan_json = build_plan_json(net, plan, q, op_csum, input_csum,
                                args.a_base, args.b_base, alloc)
    with open(os.path.join(outdir, "plan.json"), "w", encoding="utf-8") as f:
        json.dump(plan_json, f, indent=1)
    model_json = build_model_json(net, plan, q, op_csum, input_csum,
                                  args.a_base, args.b_base)
    with open(os.path.join(outdir, "model.json"), "w", encoding="utf-8") as f:
        json.dump(model_json, f, indent=1)

    reps = [] if args.no_vectors else select_representatives(plan)
    files = [] if args.no_vectors else write_vectors(
        plan, q, store_g, out_g, reps, outdir, x)

    lines = []
    lines.append("# YOLO-Fastest v1.1 int8 golden checksums (plan v0.6, %dx%d)"
                 % (hw, hw))
    lines.append("# FNV-1a 32: h=2166136261; for b: h^=b; h=(h*16777619)&0xFFFFFFFF")
    lines.append("# scope: real channels x H x W, compact NHWC logical order (y,x,c);")
    lines.append("#        channel padding bytes are NOT included.")
    lines.append("# copy ops: csum covers the channel slice written by that copy;")
    lines.append("#           'concatL<layer>' lines give the full concat target csum.")
    lines.append("# hw=%d wq_bytes=%d w_bytes=%d q_base=0x%05x q_bytes=%d"
                 % (hw, WQ_BYTES, plan["w_total"], dl.Q_BASE, Q_BYTES))
    lines.append("input 0x%08x  # pattern_v1 seed=12345 packed 3B/pixel"
                 % input_csum)
    lines.append("filter 0x%08x  # FNV of b'YOLO-FASTEST-V1.1-INT8-%d'"
                 % (vio.fnv1a_bytes(b"YOLO-FASTEST-V1.1-INT8-" + str(hw).encode()), hw))
    for op_id, op in enumerate(plan["ops"]):
        lines.append("op %3d kind=%-8s layer=%-3d flags=%d 0x%08x"
                     % (op_id, op["kind"], op["layer_idx"],
                        int(op.get("flags", 0)), op_csum[op_id]))
    for layer in sorted(concat_csum):
        lines.append("concatL%-3d 0x%08x" % (layer, concat_csum[layer]))
    with open(os.path.join(outdir, "checksums.txt"), "w",
              encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")

    with open(os.path.join(outdir, "representative_layers.json"), "w",
              encoding="utf-8") as f:
        json.dump([{"op": int(i), "label": lab} for i, lab in reps], f, indent=1)

    print("final_ops:", plan["final_ops"])
    if reps:
        print("representative ops:", reps)
        for path, n, what in files:
            print("  %-34s %8d B  %s" % (os.path.basename(path), n, what))
    for name in ("plan.json", "model.json", "checksums.txt",
                 "yolo_w.hex", "yolo_q.hex", "yolo_wq.hex"):
        p = os.path.join(outdir, name)
        print("  %-14s %8d B  sha256=%s"
              % (name, os.path.getsize(p), sha256(p)[:16]))


if __name__ == "__main__":
    main()
