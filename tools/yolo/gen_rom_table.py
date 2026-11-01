#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""plan.json (v0.6, all hardware) -> microcode ROM data source for `nn_seq`.

Field set follows SPEC-SPECIALIZED.md §1 plus the CONTRACT v0.7 address
conventions (Lead 2026-11-01):
  * kind   : 0=conv, 1=dwconv, 2=pool, 3=upsample, 4=add, 5=copy
  * flags  : bit0 depthwise, bit1 leaky, bit2 PACKED3, bit3 ADD_R
  * pad/stride/icb/ocb/ih/iw : shape info (icb/ocb in 8-channel blocks)
  * ohop/owop : reserved 2+2 bit output block offsets (0 in v0.7; copy channel
                offsets are carried in aux0/aux1, see below)
  * woff   : W-region-relative byte offset (W 320 KB)
  * qoff   : Q-region-relative byte offset (Q 48 KB)       [v0.7]
  * csum   : golden FNV-1a of the op output (debug mode)
  * aux0/aux1:
       add  -> aux0 = R (u16 requant multiplier), aux1 = KADD
       copy -> aux0 = source channel offset, aux1 = destination channel offset
       others -> 0
  * src/dst: NN-window ABSOLUTE byte offset (A base 0x60000 / B base 0x78000
             for C128; plan a_base/b_base used as-is for C320 DDR arena)

Run:  python tools/yolo/gen_rom_table.py --plan sim/prog/yolo/plan.json \
          --out results/ai-accel/nn_rom_table.json
      python tools/yolo/gen_rom_table.py --plan sim/prog/yolo320/plan.json \
          --out sim/prog/yolo320/nn_rom_table.json
"""
import argparse
import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)

KIND = {"conv": 0, "dwconv": 1, "pool": 2, "upsample": 3, "add": 4, "copy": 5}
ROM_DEPTH = 128


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for c in iter(lambda: f.read(1 << 20), b""):
            h.update(c)
    return h.hexdigest()


def blocks(c):
    return (int(c) + 7) // 8


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", required=True)
    ap.add_argument("--out", default=os.path.join(ROOT, "results", "ai-accel",
                                                  "nn_rom_table.json"))
    ap.add_argument("--label", default=None)
    args = ap.parse_args()
    plan_path = args.plan if os.path.isabs(args.plan) else os.path.join(ROOT, args.plan)
    plan = json.load(open(plan_path, encoding="utf-8"))
    ops = plan["ops"]
    a_base = int(plan.get("a_base", 0x60000))
    b_base = int(plan.get("b_base", 0x78000))

    entries = []
    errors = []
    for i, op in enumerate(ops):
        kind = op["kind"]
        if kind not in KIND:
            errors.append("op %d: CPU/non-hardware kind %r" % (i, kind))
            continue
        k = int(op.get("k", 0))
        stride = int(op.get("stride", 1))
        pad = int(op.get("pad", 0))
        ih, iw = int(op["ih"]), int(op["iw"])
        ic, oc = int(op["ic"]), int(op["oc"])
        flags = int(op.get("flags", 0))
        if kind in ("conv", "dwconv"):
            icb, ocb = blocks(ic), blocks(oc)
        elif kind == "copy":
            icb, ocb = blocks(ic), blocks(oc)
        else:                       # pool / upsample / add: channel count unchanged
            icb = ocb = blocks(ic)
        if kind == "add":
            assert "r_scale" in op, "add op %d misses r_scale" % i
            aux0 = int(op["r_scale"]) & 0xFFFF
            aux1 = int(op["k_add"]) & 0xFFFF
            assert int(op["r_scale"]) <= 0xFFFF, "R > u16 at op %d" % i
        elif kind == "copy":
            aux0 = int(op.get("c_src", 0))
            aux1 = int(op.get("c_dst", 0))
        else:
            aux0 = aux1 = 0
        qoff = int(op.get("qoff", -1))
        if kind in ("conv", "dwconv"):
            assert 0 <= qoff < 48 * 1024, "conv qoff out of Q region: %d" % qoff
            assert 0 <= int(op["woff"]) < 320 * 1024, "woff out of W region"
        if kind == "add":
            assert 0 <= qoff < 48 * 1024, "add qoff out of Q region: %d" % qoff
        src = a_base + int(op["src"]["off"]) if op["src"]["buf"] == "A" \
            else b_base + int(op["src"]["off"])
        dst = a_base + int(op["dst"]["off"]) if op["dst"]["buf"] == "A" \
            else b_base + int(op["dst"]["off"])
        entries.append({
            "op": i, "layer": int(op.get("layer_idx", -1)), "kind": KIND[kind],
            "kind_name": kind, "flags": flags,
            "pad": pad, "stride": stride,
            "icb": icb, "ocb": ocb, "ih": ih, "iw": iw,
            "ohop": 0, "owop": 0,
            "woff": int(op["woff"]) if int(op.get("woff", -1)) >= 0 else 0,
            "qoff": qoff if qoff >= 0 else 0,
            "csum": int(op.get("csum", 0)),
            "aux0": aux0, "aux1": aux1,
            "src": src, "dst": dst,
        })
    if errors:
        raise SystemExit("[FAIL] plan has non-hardware ops:\n  " + "\n  ".join(errors))
    assert len(entries) <= ROM_DEPTH, \
        "ROM depth %d entries > %d" % (len(entries), ROM_DEPTH)
    kinds = {}
    for e in entries:
        kinds[e["kind_name"]] = kinds.get(e["kind_name"], 0) + 1
    out = {
        "format": "nn_rom_table-v0.7",
        "source_plan": os.path.relpath(plan_path, ROOT).replace("\\", "/"),
        "plan_sha256": sha256(plan_path),
        "hw": plan["input"]["ih"],
        "input": plan["input"],
        "w_bytes": plan.get("w_bytes"),
        "q_bytes": plan.get("q_bytes", 48 * 1024),
        "woff_units": "w_region_relative",
        "qoff_units": "q_region_relative",
        "src_dst_units": "window_absolute (A=%d, B=%d)" % (a_base, b_base),
        "aux_encoding": {
            "add": "aux0=R (u16 requant multiplier), aux1=KADD",
            "copy": "aux0=source channel offset, aux1=destination channel offset",
            "other": "0",
        },
        "depth": len(entries),
        "depth_limit": ROM_DEPTH,
        "kinds": kinds,
        "entries": entries,
    }
    out_dir = os.path.dirname(args.out if os.path.isabs(args.out)
                              else os.path.join(ROOT, args.out))
    os.makedirs(out_dir, exist_ok=True)
    out_path = args.out if os.path.isabs(args.out) else os.path.join(ROOT, args.out)
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=1)
    print("ROM table %s: depth=%d/%d kinds=%s"
          % (os.path.relpath(out_path, ROOT), len(entries), ROM_DEPTH, kinds))
    print("  woff range [0,%d)  qoff range [0,%d)  src/dst window absolute "
          "(A=0x%06x B=0x%06x)"
          % (max(e["woff"] for e in entries), max(e["qoff"] for e in entries),
             a_base, b_base))
    print("  bytes=%d  sha256(plan)=%s" % (os.path.getsize(out_path),
                                           out["plan_sha256"][:16]))


if __name__ == "__main__":
    main()
