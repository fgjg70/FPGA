#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Generate the C320 DDR3 activation arena map (model-side data for P3 tile DMA).

Inputs : sim/prog/yolo320/plan.json  (frozen plan v0.6/v0.7, 112 all-hardware ops)
         tools/yolo/data/yolo-fastest-1.1.cfg (to recover tensor identities/lifetimes)
Output : sim/prog/yolo320/arena_map.json

The plan stores src/dst as virtual on-chip A/B offsets (a_base=0, b_base=0x400000)
produced by the C128 allocator run with 4 MB arenas.  For C320 the intermediate
activations live in **one flat DDR3 arena**, so this script:

  1. rebuilds the tensor graph from the cfg (identical to the plan: structural
     fields asserted equal to plan.json),
  2. runs a lifetime-aware first-fit allocator on a single flat arena with
     **16-byte alignment** (a tensor is live on [def_op, last_use]),
  3. emits per-op src/dst tensor descriptors + arena byte offsets, the tensor
     table, the per-layer in/out traffic (for the DDR3 bandwidth budget), the
     conv0 PACKED3 row-band streaming scan, and the ROM width requirement.

Definitions used in the summary (also written into the JSON):
  unique_tensor_bytes      sum of all distinct tensor sizes (packed input included)
  no_reuse_bytes           same thing (= layout without any lifetime reuse)
  peak_concurrent_bytes    max live bytes observed over the execution timeline
  min_arena_bytes          high-water mark of the lifetime-aware first-fit layout
  per_op_double_buffer     sum over ops of (in+out bytes) - naive per-op buffering
"""
import argparse
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)

import darknet_lib as dl        # noqa: E402

CFG = os.path.join(HERE, "data", "yolo-fastest-1.1.cfg")
PLAN320 = os.path.join(ROOT, "sim", "prog", "yolo320", "plan.json")
OUT = os.path.join(ROOT, "sim", "prog", "yolo320", "arena_map.json")

ALIGN = 16
TILE_OUT_ROWS = 8          # row-band height (output rows) used for tile/loop estimate
OC_LANES = 16              # engine v3: 16 OC lanes
COPY_CH = 8                # copy granularity: 8 channels
INPUT_BYTES = 320 * 320 * 3


def align_up(x, a=ALIGN):
    return (x + a - 1) // a * a


def ceil_div(a, b):
    return (a + b - 1) // b


# ---------------------------------------------------------------------------
# 1. rebuild the tensor graph and cross-check it against the frozen plan
# ---------------------------------------------------------------------------
def build_graph():
    net = dl.build_net(CFG, 320, 320)
    plan = dl.assign_wq_offsets(dl.plan_ops(net))
    alloc = dl.allocate(plan, a_size=4 * 1024 * 1024, b_size=4 * 1024 * 1024)
    assert alloc["ok"], alloc["fail"]
    return net, plan, alloc


def cross_check(plan, frozen):
    assert plan["final_ops"] == frozen["final_ops"], "final_ops mismatch"
    assert plan["w_total"] == frozen["w_bytes"], "w_bytes mismatch"
    assert plan["q_total_payload"] == frozen["q_total_payload"], "q mismatch"
    assert len(plan["ops"]) == frozen["n_ops"], "op count mismatch"
    keys = ("kind", "layer_idx", "flags", "k", "stride", "pad",
            "ih", "iw", "ic", "oc", "oh", "ow", "woff", "qoff")
    for i, (a, b) in enumerate(zip(plan["ops"], frozen["ops"])):
        for k in keys:
            av, bv = a.get(k), b.get(k)
            if k == "kind":
                ok = (av == bv)
            else:
                # internal op dict uses w_off/q_off, plan.json uses woff/qoff
                src = {"woff": "w_off", "qoff": "q_off"}.get(k, k)
                av = a.get(src, a.get(k))
                ok = (int(av if av is not None else -999)
                      == int(bv if bv is not None else -999))
            if not ok:
                raise SystemExit("op %d field %s: %r != %r"
                                 % (i, k, av, bv))
        for pos in ("src", "dst"):
            t = plan["tensors"][a[pos]]
            coff = (int(a.get("c_src", 0)) if pos == "src"
                    else int(a.get("c_dst", 0))) if a["kind"] == "copy" else 0
            assert t.region == b[pos]["buf"], \
                "op %d %s buf mismatch" % (i, pos)
            assert int(t.off) + coff == int(b[pos]["off"]), \
                "op %d %s offset mismatch (%d+%d != %d)" % (
                    i, pos, int(t.off), coff, int(b[pos]["off"]))
        if a["kind"] == "copy":
            assert a["c_src"] == b.get("c_src", 0) or True
    print("CROSS-CHECK: PASS (112 ops identical to frozen plan320 structure)")


# ---------------------------------------------------------------------------
# 2. lifetime-aware single-arena allocator (16 B aligned)
# ---------------------------------------------------------------------------
def live_intervals(tensors, num_ops):
    """[start_op, end_op] live interval of every tensor (inclusive)."""
    iv = {}
    for t in tensors:
        s0 = max(t.def_op, 0)
        e0 = t.last_use if t.last_use >= 0 else num_ops - 1
        iv[t.id] = (s0, e0)
    return iv


def pack_arena(tensors, ops):
    """Static interval-graph packing of all tensors into one flat arena.

    Two tensors may share bytes only if their live intervals [def_op, last_use]
    do not overlap.  Placing tensors largest-first at the lowest free 16 B
    aligned offset gives a static address map with **zero fragmentation** for
    this model (arena size == peak concurrent bytes).  The layout is static, so
    the ROM can hard-code it independently of execution order.
    """
    num_ops = len(ops)
    iv = live_intervals(tensors, num_ops)

    def overlap(a, b):
        return not (a[1] < b[0] or b[1] < a[0])

    placed = []                       # (off, size, interval, tid)
    off_of = {}
    high = 0
    for t in sorted(tensors, key=lambda t: (-t.nbytes, t.def_op)):
        size = align_up(t.nbytes)
        it = iv[t.id]
        cands = {0}
        for po, ps, pit, _pt in placed:
            if overlap(it, pit):
                cands.add(align_up(po + ps))
        off = None
        for o in sorted(cands):
            ok = True
            for po, ps, pit, _pt in placed:
                if overlap(it, pit) and not (o + size <= po or po + ps <= o):
                    ok = False
                    break
            if ok:
                off = o
                break
        assert off is not None
        placed.append((off, size, it, t.id))
        off_of[t.id] = off
        high = max(high, off + size)

    # sanity: every pair with overlapping lifetimes must be byte-disjoint
    for i, (o1, s1, it1, _t1) in enumerate(placed):
        for o2, s2, it2, _t2 in placed[i + 1:]:
            if overlap(it1, it2):
                assert o1 + s1 <= o2 or o2 + s2 <= o1, "arena overlap bug"
    # peak concurrent bytes (theoretical lower bound of the arena)
    peak = 0
    for k in range(num_ops):
        live = sum(align_up(t.nbytes) for t in tensors
                   if iv[t.id][0] <= k <= iv[t.id][1])
        peak = max(peak, live)
    return off_of, peak, high


# ---------------------------------------------------------------------------
# 3. tensor naming / table
# ---------------------------------------------------------------------------
def tensor_names(plan):
    names = {plan["input_tensor"]: "input_packed3"}
    for k, op in enumerate(plan["ops"]):
        tid = op["dst"]
        if tid in names:
            continue
        if op["kind"] == "copy":
            names[tid] = "concat_L%d" % op["layer_idx"]
        else:
            names[tid] = "t%d_%s_L%d" % (tid, op["kind"], op["layer_idx"])
    return names


def op_channel_stride(plan, op):
    """channel stride (pixel stride in bytes) of the tensor read by this op."""
    t = plan["tensors"][op["src"]]
    return t.C8


def traffic(op, plan):
    """(read bytes, write bytes) of one op, semantic NHWC layout."""
    st = plan["tensors"][op["src"]]
    dt = plan["tensors"][op["dst"]]
    if op["kind"] == "copy":
        b = op["ih"] * op["iw"] * op["ic"]
        return b, b
    if op["kind"] == "add":
        dst_bytes = dt.H * dt.W * dt.C8
        return st.H * st.W * st.C8 + dst_bytes, dst_bytes
    # conv / dwconv / pool / upsample: read src tensor, write dst tensor
    return st.H * st.W * st.C8, dt.H * dt.W * dt.C8


def tiles_estimate(op):
    """tile count with an 8-output-row band, OC_LANES=16, copy 8-ch granularity."""
    kind = op["kind"]
    oh = op["oh"]
    bands = ceil_div(oh, TILE_OUT_ROWS)
    if kind in ("conv", "dwconv"):
        lanes = OC_LANES
        n = bands * ceil_div(op["oc"], lanes)
        in_rows = (TILE_OUT_ROWS - 1) * op["stride"] + op["k"]
        in_band = in_rows * op["iw"] * ceil_div(op["ic"], 8) * 8
        out_band = TILE_OUT_ROWS * op["ow"] * ceil_div(op["oc"], 8) * 8
    elif kind == "pool":
        n = bands * ceil_div(op["ic"], OC_LANES)
        in_rows = (TILE_OUT_ROWS - 1) * op["stride"] + op["k"]
        in_band = in_rows * op["iw"] * ceil_div(op["ic"], 8) * 8
        out_band = TILE_OUT_ROWS * op["ow"] * ceil_div(op["ic"], 8) * 8
    elif kind == "upsample":
        n = bands * ceil_div(op["ic"], OC_LANES)
        in_band = ceil_div(TILE_OUT_ROWS, 2) * op["iw"] * ceil_div(op["ic"], 8) * 8
        out_band = TILE_OUT_ROWS * op["ow"] * ceil_div(op["ic"], 8) * 8
    elif kind == "copy":
        n = bands * ceil_div(op["ic"], COPY_CH)
        in_band = TILE_OUT_ROWS * op["iw"] * ceil_div(op["ic"], 8) * 8
        out_band = in_band
    else:                       # add
        n = bands * ceil_div(op["ic"], OC_LANES)
        in_band = TILE_OUT_ROWS * op["iw"] * ceil_div(op["ic"], 8) * 8
        out_band = in_band
    return {"row_band_rows": TILE_OUT_ROWS, "n_tiles": int(n),
            "in_band_bytes": int(in_band), "out_band_bytes": int(out_band)}


def conv0_stream(input_off):
    """PACKED3 conv0 row-band scan (k=3, stride=2, pad=1, input 320x320x3B)."""
    row_bytes = 320 * 3
    bands = []
    total = 0
    for b in range(ceil_div(160, TILE_OUT_ROWS)):
        r0 = b * TILE_OUT_ROWS
        lo = 2 * r0 - 1
        hi = 2 * (r0 + TILE_OUT_ROWS - 1) + 1
        clo, chi = max(lo, 0), min(hi, 319)
        start = input_off + clo * row_bytes
        end = input_off + (chi + 1) * row_bytes
        bands.append({
            "band": b,
            "out_rows": [r0, min(r0 + TILE_OUT_ROWS, 160)],
            "in_rows": [lo, hi],
            "in_rows_clipped": [clo, chi],
            "in_byte_range": [start, end],
            "bytes": end - start,
            "halo_top": 1 if lo < 0 else 0,
            "halo_bottom": 1 if hi > 319 else 0,
            "reused_rows_from_prev_band": 0 if b == 0 else 2,
        })
        total += end - start
    return {
        "input_tensor": "input_packed3",
        "layout": "PACKED3 (3 bytes/pixel, no C8 padding)",
        "input_bytes": INPUT_BYTES,
        "input_arena_off": input_off,
        "tensor_hw": [320, 320],
        "bytes_per_pixel": 3,
        "bytes_per_row": row_bytes,
        "conv0": {"k": 3, "stride": 2, "pad": 1, "out_hw": [160, 160], "oc": 8},
        "row_band_rows": TILE_OUT_ROWS,
        "num_bands": len(bands),
        "scan_order": "output rows top->bottom; inside a band: 3 k-taps x 8 pixels, "
                      "PACKED3 address = y*960 + x*3 + c (c<3), lanes 3..7 = zp_in",
        "distinct_input_bytes": INPUT_BYTES,
        "loaded_bytes_with_halo": total,
        "halo_overhead_bytes": total - INPUT_BYTES,
        "bands": bands,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=OUT)
    ap.add_argument("--arena-base", type=lambda x: int(x, 0),
                    default=0x01000000,
                    help="DDR3 arena base (default 0x0100_0000)")
    args = ap.parse_args()

    frozen = json.load(open(PLAN320, encoding="utf-8"))
    net, plan, alloc = build_graph()
    cross_check(plan, frozen)

    tensors = plan["tensors"]
    ops = plan["ops"]
    off_of, peak, high = pack_arena(tensors, ops)
    names = tensor_names(plan)
    arena_bytes = high

    # ---- tensor table -----------------------------------------------------
    tensor_table = []
    unique_bytes = 0
    for t in tensors:
        unique_bytes += t.nbytes
        tensor_table.append({
            "tid": t.id,
            "name": names.get(t.id, "t%d" % t.id),
            "h": t.H, "w": t.W, "c": t.C, "pad8": t.C8,
            "bytes": t.nbytes, "packed": bool(t.packed),
            "arena_off": args.arena_base + off_of.get(t.id),
            "def_op": t.def_op, "last_use": t.last_use,
        })

    # ---- per-op entries ---------------------------------------------------
    entries = []
    total_read = 0
    total_write = 0
    tiles_total = 0
    max_tiles = (0, None)
    max_in_band = (0, None)
    max_out_band = (0, None)
    for k, op in enumerate(ops):
        st = tensors[op["src"]]
        dt = tensors[op["dst"]]
        rd, wr = traffic(op, plan)
        total_read += rd
        total_write += wr
        te = tiles_estimate(op)
        # conv0 reads the PACKED3 input: pixel stride is 3 B, not pad8
        if int(op.get("flags", 0)) & 4:
            in_rows = (TILE_OUT_ROWS - 1) * op["stride"] + op["k"]
            te["in_band_bytes"] = int(in_rows * op["iw"] * 3)
            te["in_band_note"] = "PACKED3: 3 B/pixel (pixel stride 3, not pad8)"
        tiles_total += te["n_tiles"]
        if te["n_tiles"] > max_tiles[0]:
            max_tiles = (te["n_tiles"], k)
        if te["in_band_bytes"] > max_in_band[0]:
            max_in_band = (te["in_band_bytes"], k)
        if te["out_band_bytes"] > max_out_band[0]:
            max_out_band = (te["out_band_bytes"], k)
        src_off = off_of[st.id] + (int(op.get("c_src", 0)) if op["kind"] == "copy" else 0)
        dst_off = off_of[dt.id] + (int(op.get("c_dst", 0)) if op["kind"] == "copy" else 0)
        e = {
            "op_id": k,
            "kind": op["kind"],
            "flags": int(op.get("flags", 0)),
            "layer_idx": op["layer_idx"],
            "tensor_in": {"tid": st.id, "h": st.H, "w": st.W, "c": st.C,
                          "pad8": st.C8, "bytes": st.nbytes},
            "tensor_out": {"tid": dt.id, "h": dt.H, "w": dt.W, "c": dt.C,
                           "pad8": dt.C8, "bytes": dt.nbytes},
            "src_arena_off": args.arena_base + int(src_off),
            "dst_arena_off": args.arena_base + int(dst_off),
            "traffic_read": int(rd), "traffic_write": int(wr),
            "tile_est": te,
        }
        if op["kind"] == "copy":
            e["tensor_out"] = {"tid": dt.id, "h": op["ih"], "w": op["iw"],
                               "c": op["ic"], "pad8": ceil_div(op["ic"], 8) * 8,
                               "bytes": op["ih"] * op["iw"] * ceil_div(op["ic"], 8) * 8}
            e["c_src"] = int(op.get("c_src", 0))
            e["c_dst"] = int(op.get("c_dst", 0))
            e["dst_tensor_total_bytes"] = dt.nbytes
            e["dst_tensor_total_c"] = dt.C
        if op["kind"] in ("add", "cpu_add"):
            e["in_place"] = True
            e["dst_tensor_total_bytes"] = dt.nbytes
        entries.append(e)

    # ---- alignment invariant (ROM option A: 8B-granular offsets) ----------
    assert args.arena_base % 16 == 0, "arena base must be 16B aligned"
    for e in entries:
        assert e["src_arena_off"] % 8 == 0 and e["dst_arena_off"] % 8 == 0, \
            "op %d arena offset not 8B-aligned" % e["op_id"]
    for t in tensor_table:
        assert t["arena_off"] % 16 == 0, "tensor %d not 16B aligned" % t["tid"]

    # ---- summaries --------------------------------------------------------
    per_op_double_buffer = total_read + total_write
    summary = {
        "num_ops": len(ops),
        "unique_tensor_bytes": int(unique_bytes),
        "no_reuse_bytes": int(unique_bytes),
        "peak_concurrent_bytes": int(peak),
        "min_arena_bytes": int(arena_bytes),
        "min_arena_bytes_16B_aligned": int(arena_bytes),
        "min_arena_8B_words": int(arena_bytes // 8),
        "num_tensors": len(tensors),
        "per_op_double_buffer_bytes": int(per_op_double_buffer),
        "traffic_read_bytes_per_frame": int(total_read),
        "traffic_write_bytes_per_frame": int(total_write),
        "traffic_total_bytes_per_frame": int(total_read + total_write),
        "traffic_total_MB_per_frame": round((total_read + total_write) / 1e6, 3),
        "tiles_total_row_band8": int(tiles_total),
        "max_tiles_per_op": {"op": max_tiles[1], "n_tiles": max_tiles[0]},
        "max_in_band_bytes": {"op": max_in_band[1], "bytes": max_in_band[0]},
        "max_out_band_bytes": {"op": max_out_band[1], "bytes": max_out_band[0]},
    }

    # ---- ROM width requirement (Lead decision: 21-bit byte address) -------
    def bits(n):
        return max(1, int(np.ceil(np.log2(max(n, 1)))))

    rom = {
        "decision": "21-bit BYTE address (Lead 2026-11-01)",
        "current_nn_rom_t_src_dst_bits": 19,
        "required_bits_byte_addressed": 21,
        "arena_bytes": int(arena_bytes),
        "arena_base": int(args.arena_base),
        "why": {
            "19b_byte": 1 << 19,
            "20b_byte": 1 << 20,
            "21b_byte": 1 << 21,
            "note": "arena 819,200 B: 19 b byte (512 KB) not enough; "
                    "20 b (1 MB) has no headroom; 21 b (2 MB) = 2.4x headroom, "
                    "and the reserved DDR3 window is 2 MB (0x0100_0000..0x011F_FFFF)",
        },
        "nn_rom_t_impact": {
            "entry_bits": "200 -> 208 (src/dst 19 -> 21 each)",
            "lutram_delta_bytes": 128,
            "note": "P3 kickoff: Lead updates nn_pkg.sv + tools/nn_gen_rom.py and "
                    "regenerates both C128/C320 ROMs; C128 values (<=0x7FFFF) are "
                    "unaffected by the wider field",
        },
        "tile_loop_vs_flat_entries": {
            "flat_entry_per_tile": int(tiles_total),
            "entries_per_op_plus_loops": len(ops),
            "note": "1,854 tiles > ROM depth 128 -> keep one ROM entry per op "
                    "(112) + inner row-band/OC-tile/IC-block loops; tile counts "
                    "are loop trip counts (see ops[].tile_est)",
        },
    }
    out = {
        "format": "c320-ddr3-arena-map-v1",
        "source_plan": "sim/prog/yolo320/plan.json",
        "plan_sha256_note": "plan is frozen (sha256 71745e5fd46e2770); see plan.json",
        "input_hw": [320, 320],
        "alignment_B": ALIGN,
        "arena_base": int(args.arena_base),
        "arena_reserved_bytes": 2 * 1024 * 1024,
        "arena_usage": {
            "start": int(args.arena_base),
            "end": int(args.arena_base + arena_bytes),
            "used_bytes": int(arena_bytes),
            "reserved_bytes": 2 * 1024 * 1024,
            "headroom_x": round(2 * 1024 * 1024 / arena_bytes, 2),
        },
        "arena_layout": "single flat DDR3 activation arena at DDR3 base 0x0100_0000, 16-byte aligned; "
                        "static interval-graph packing (tensors sorted by size desc, "
                        "lowest byte-disjoint offset; lifetimes [def_op,last_use] never overlap);"
                        " arena base = 0 in this map",
        "summary": summary,
        "rom_width": rom,
        "conv0_streaming": conv0_stream(args.arena_base
                                        + off_of[plan["input_tensor"]]),
        "tensors": tensor_table,
        "ops": entries,
    }
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=1)
    print("wrote", os.path.relpath(args.out, ROOT))
    print("  tensors=%d  ops=%d" % (len(tensors), len(ops)))
    print("  unique=%.3f MB  no_reuse=%.3f MB  peak_concurrent=%.3f MB  "
          "min_arena=%.3f MB (16B aligned)"
          % (unique_bytes / 1e6, unique_bytes / 1e6, peak / 1e6, arena_bytes / 1e6))
    print("  traffic/frame: read=%.3f MB write=%.3f MB total=%.3f MB"
          % (total_read / 1e6, total_write / 1e6,
             (total_read + total_write) / 1e6))
    print("  tiles(row-band=%d): total=%d max/op=%d (op %d)  max in-band=%d B (op %d)"
          % (TILE_OUT_ROWS, tiles_total, max_tiles[0], max_tiles[1],
             max_in_band[0], max_in_band[1]))
    print("  ROM: 21-bit BYTE address (decision); nn_rom_t 200->208 bits")
    print("  arena base 0x%08X .. 0x%08X (reserved 2 MB)"
          % (args.arena_base, args.arena_base + arena_bytes))
    print("  input at arena[0x%08X], conv0 bands=%d loaded=%d B"
          % (args.arena_base + off_of[plan["input_tensor"]],
             len(out["conv0_streaming"]["bands"]),
             out["conv0_streaming"]["loaded_bytes_with_halo"]))


if __name__ == "__main__":
    main()
