#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Emit `sim/prog/yolo/vector_manifest.json` (C128 representative replay vectors).

Answers the t-accel replay questions: which `l{id}_*.hex` belongs to which plan
op, tensor shape / pixel bytes / storage layout, and the w/q file formats.

Run:  python tools/yolo/gen_vector_manifest.py
"""
import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
VEC = os.path.join(ROOT, "sim", "prog", "yolo")
OUT = os.path.join(VEC, "vector_manifest.json")

KIND_DESC = {
    "conv": "2D conv (PACKED3 if flags bit2)",
    "dwconv": "depthwise conv",
    "pool": "maxpool",
    "upsample": "2x nearest-neighbour upsample",
    "add": "residual add, ADD_R (per-tensor source requant)",
    "copy": "channel-block copy (concat expansion)",
}


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""):
            h.update(c)
    return h.hexdigest()


def nlines(path):
    with open(path, "rb") as f:
        return sum(1 for _ in f)


def pad8(c):
    return (int(c) + 7) // 8 * 8


def file_info(base, suffix):
    p = os.path.join(VEC, base + suffix)
    if not os.path.exists(p):
        return None
    return {"file": os.path.basename(p), "bytes": os.path.getsize(p),
            "lines": nlines(p), "sha256": sha256(p)}


def main():
    plan = json.load(open(os.path.join(VEC, "plan.json"), encoding="utf-8"))
    reps = json.load(open(os.path.join(VEC, "representative_layers.json"),
                          encoding="utf-8"))
    plan_sha = sha256(os.path.join(VEC, "plan.json"))[:16]

    vectors = []
    for rep in reps:
        op_id = int(rep["op"])
        label = rep["label"]
        op = plan["ops"][op_id]
        kind = op["kind"]
        flags = int(op.get("flags", 0))
        base = "l%d" % op_id
        packed3 = bool(flags & 4) or kind == "conv" and int(op["ic"]) == 3
        if kind == "copy":
            t_in = {"h": op["ih"], "w": op["iw"], "c": op["ic"],
                    "note": "source channel slice (c_src=%d) of source tensor"
                            % int(op.get("c_src", 0))}
            t_out = {"h": op["ih"], "w": op["iw"], "c": op["ic"],
                     "note": "written channel slice (c_dst=%d) of target tensor"
                             % int(op.get("c_dst", 0))}
        elif kind in ("add", "cpu_add"):
            t_in = {"h": op["ih"], "w": op["iw"], "c": op["ic"],
                    "note": "source branch tensor, real channels"}
            t_out = {"h": op["oh"], "w": op["ow"], "c": op["oc"],
                     "note": "in-place accumulated dst tensor (ADD_R)"}
        else:
            t_in = {"h": op["ih"], "w": op["iw"], "c": op["ic"],
                    "note": "PACKED3 (3 bytes/pixel)" if packed3
                            else "real channels only (no channel padding)"}
            t_out = {"h": op["oh"], "w": op["ow"], "c": op["oc"],
                     "note": "real channels only (no channel padding)"}
        in_elem = t_in["h"] * t_in["w"] * t_in["c"]
        out_elem = t_out["h"] * t_out["w"] * t_out["c"]
        in_px_bytes = 3 if packed3 else t_in["c"]
        v = {
            "op_id": op_id,
            "kind": kind,
            "kind_desc": KIND_DESC.get(kind, kind),
            "layer_idx": int(op["layer_idx"]),
            "flags": flags,
            "label": label,
            "tensor_in": dict(t_in, elements=in_elem,
                              pixel_bytes=in_px_bytes,
                              pixel_stride_pad8=3 if packed3 else pad8(t_in["c"])),
            "tensor_out": dict(t_out, elements=out_elem,
                               pixel_bytes=t_out["c"],
                               pixel_stride_pad8=pad8(t_out["c"])),
            "files": {},
        }
        for suf, key, elem in (("_in.hex", "in", in_elem),
                               ("_out.hex", "out", out_elem)):
            fi = file_info(base, suf)
            if fi is None:
                raise SystemExit("missing %s%s" % (base, suf))
            assert fi["lines"] == elem, \
                "%s%s: %d lines != %d elements" % (base, suf, fi["lines"], elem)
            assert fi["bytes"] == 3 * elem
            v["files"][key] = fi
        if kind in ("conv", "dwconv", "cpu_conv0"):
            k2 = int(op["k"]) ** 2
            if kind == "dwconv":
                w_elem = k2 * pad8(op["oc"])
                w_layout = "dw: [tap][OC_pad], tap=k*k index row-major; OC fastest"
                q_bytes = 6 * pad8(op["oc"]) + 16
            else:
                w_elem = k2 * pad8(op["ic"]) * pad8(op["oc"])
                w_layout = ("dense: [tap][IC_pad][OC_pad], tap=k*k row-major; "
                            "IC then OC, OC fastest; zero-padded IC/OC lanes")
                q_bytes = 6 * pad8(op["oc"]) + 16
            q_words = q_bytes // 4
            fiw = file_info(base, "_w.hex")
            fiq = file_info(base, "_q.hex")
            assert fiw and fiq, "missing w/q for op %d" % op_id
            assert fiw["lines"] == w_elem, \
                "%s_w.hex: %d != %d" % (base, fiw["lines"], w_elem)
            assert fiq["lines"] == q_words, \
                "%s_q.hex: %d != %d" % (base, fiq["lines"], q_words)
            v["files"]["w"] = dict(fiw, elements=w_elem, layout=w_layout)
            v["files"]["q"] = dict(
                fiq, words=q_words, payload_bytes=q_bytes,
                layout=("conv Q payload 32-bit LE words: bias_adj int32[OC_pad] @0, "
                        "M_pos int16[OC_pad] @4*OC_pad, tail 16 B "
                        "{zp_out, zp_in, leaky_en, SHIFT, 12'b0} @6*OC_pad")
                if kind != "dwconv" else
                ("conv Q payload 32-bit LE words: bias_adj int32[OC_pad] @0, "
                 "M_pos int16[OC_pad] @4*OC_pad, tail 16 B "
                 "{zp_out, zp_in, leaky_en, SHIFT, 12'b0} @6*OC_pad"))
        elif kind in ("add", "cpu_add"):
            fiq = file_info(base, "_q.hex")
            assert fiq, "missing add q for op %d" % op_id
            assert fiq["lines"] == 4
            v["files"]["q"] = dict(
                fiq, words=4, payload_bytes=16,
                layout="ADD_R Q block 16 B as 4 u32 LE words: "
                       "[0]=zp_s [1]=zp_d [2:3]=R u16 LE [4]=KADD [5:15]=0")
            v["add_params"] = {"r_scale": int(op.get("r_scale", 0)),
                               "k_add": int(op.get("k_add", 0)),
                               "zp_s": int(op.get("zp_s", 0)),
                               "zp_d": int(op.get("zp_d", 0))}
        # ops without weights/Q: pool / upsample / copy -> only in/out files
        vectors.append(v)

    manifest = {
        "format": "yolo-vector-manifest-v1",
        "generated_by": "tools/yolo/gen_vector_manifest.py",
        "plan": "sim/prog/yolo/plan.json",
        "plan_sha256": plan_sha,
        "plan_ops_total": plan["n_ops"],
        "hw": 128,
        "file_formats": {
            "i8_hex": {
                "files": ["*_in.hex", "*_out.hex", "*_w.hex"],
                "format": "one signed int8 per line: 2 lowercase hex digits "
                          "(two's complement) + LF",
                "bytes_per_element": 3,
                "note": "file size = 3 x element count (this is why e.g. "
                        "l2_in.hex is 98,304 B for 32,768 elements)",
            },
            "u32_hex": {
                "files": ["*_q.hex"],
                "format": "one 32-bit little-endian word per line: 8 lowercase "
                          "hex digits + LF",
                "bytes_per_element": 9,
                "note": "file size = 9 x word count",
            },
        },
        "tensor_layout": {
            "activation_files": "in/out hex store the op's REAL channels only, "
                                "compact NHWC row-major: index = ((y*W)+x)*C + c "
                                "(y outer, x middle, c inner)",
            "hardware_pixel_stride": "ceil(C/8)*8 bytes per pixel (CONTRACT §8); "
                                     "when C is not a multiple of 8 the loader must "
                                     "pad each pixel with zp_in in the padding lanes",
            "packed3": "op0 only: input is 3 B/pixel packed, index = ((y*W)+x)*3+c, "
                       "c in {0,1,2}; engine PACKED3 fills lanes 3..7 with zp_in",
            "channel_slices": "copy: in/out hex contain only the copied channel "
                              "slice; add: in = source branch, out = in-place dst",
        },
        "stale_files_removed": {
            "files": ["l96_in.hex", "l96_out.hex", "l96_w.hex", "l96_q.hex",
                      "l100_in.hex", "l100_out.hex", "l100_w.hex", "l100_q.hex",
                      "l101_in.hex", "l101_out.hex"],
            "reason": "v0.5 (108-op) numbering: v0.5 op96/100/101 == v0.7 op99/103/104 "
                      "(op ids shifted by +3 after SPP concat was expanded into 4 "
                      "copy ops). Contents were byte-identical to the v0.7 files; "
                      "the stale duplicates were deleted to avoid replay mix-ups.",
        },
        "c320": {
            "has_vectors": False,
            "note": "no l*.hex for C320 (only plan/w/q/rom/arena_map). The C320 "
                    "plan uses the same weights but 320-calibrated Q; vectors are "
                    "not needed for P3 data-path bring-up. If needed, generate "
                    "separately without overwriting the frozen plan/w/q.",
        },
        "current_vector_set": [{"op_id": v["op_id"], "kind": v["kind"],
                                "layer_idx": v["layer_idx"],
                                "base": "l%d" % v["op_id"]} for v in vectors],
        "vectors": vectors,
    }
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=1)
    print("wrote", os.path.relpath(OUT, ROOT),
          "(%d B, sha256 %s)" % (os.path.getsize(OUT), sha256(OUT)[:16]))
    for v in vectors:
        print("  l%-3d op%-3d %-8s L%-3d in(h=%d,w=%d,c=%d) out(h=%d,w=%d,c=%d)"
              % (v["op_id"], v["op_id"], v["kind"], v["layer_idx"],
                 v["tensor_in"]["h"], v["tensor_in"]["w"], v["tensor_in"]["c"],
                 v["tensor_out"]["h"], v["tensor_out"]["w"], v["tensor_out"]["c"]))


if __name__ == "__main__":
    main()
