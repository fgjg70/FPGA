#!/usr/bin/env python3
"""gen_bands_txt.py -- flatten band_plan.json into an ASCII table for the TB.

Line format (one band per line):
  op band_idx in_off in_rows pad_top rd_rows out_off out_rows in_row_bytes out_row_bytes add_mode
where in_off / out_off are ARENA-RELATIVE byte offsets (TB adds ARENA_BASE).
in_off = band_in_base (arena_off of the first read row);
out_off = op.dst_arena_off-ARENA_ABS_BASE + band_idx*band_rows*out_row_bytes.

ASCII only.
"""

import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
PLAN = os.path.join(REPO, "results/bottlecap/plan")
ARENA_ABS_BASE = 0x01000000


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    plan_dir = argv[0] if len(argv) > 0 else PLAN
    out_path = argv[1] if len(argv) > 1 else os.path.join(
        HERE, "m6b_data/bands.txt")
    plan = json.load(open(os.path.join(plan_dir, "plan.json"), "r", encoding="utf-8"))
    bp = json.load(open(os.path.join(plan_dir, "band_plan.json"), "r", encoding="utf-8"))
    ops = plan["ops"]
    bp_ops = {int(o["op"]): o for o in bp["ops"]}

    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    n = 0
    with open(out_path, "w", encoding="ascii", newline="\n") as f:
        f.write("# op band in_off in_rows pad_top rd_rows out_off out_rows "
                "in_row_bytes out_row_bytes add_mode\n")
        for op in ops:
            oid = int(op["id"])
            b = bp_ops[oid]
            src_off = int(op["src_arena_off"]) - ARENA_ABS_BASE
            dst_off = int(op["dst_arena_off"]) - ARENA_ABS_BASE
            br = int(b["band_rows"])
            nbands = int(b["n_bands"])
            in_row_bytes = int(b["in_row_bytes"])
            out_row_bytes = int(b["out_row_bytes"])
            add_mode = 1 if op["kind"] == "add" else 0
            for bi in range(nbands):
                # band_in_base from band_plan is the arena offset of the first
                # read row of this band (pad_top rows are synthetic)
                in_off = int(b["band_in_base"]) + bi * int(b["in_rows"]) * in_row_bytes \
                    if False else int(b["band_in_base"])
                # recompute per band from the rule (safer than trusting a single base)
                pad_top = int(b["pad_top"]) if bi == 0 else 0
                # rows advance by band_rows*stride per band; formula from converter:
                # band_in_base(bi) = src_off + (bi*br*st - pad)*row_bytes  (clamped >=0)
                # We recompute from the plan rule directly:
                st = int(op["stride"])
                in_off_b = src_off + max(0, bi * br * st - int(op["pad"])) * in_row_bytes
                out_off_b = dst_off + bi * br * out_row_bytes
                rd_rows = int(b["in_rows"]) - pad_top
                f.write("%d %d %d %d %d %d %d %d %d %d %d\n" % (
                    oid, bi, in_off_b, int(b["in_rows"]), pad_top, rd_rows,
                    out_off_b, br, in_row_bytes, out_row_bytes, add_mode))
                n += 1
    print(f"[bands] {n} bands -> {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
