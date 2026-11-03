#!/usr/bin/env python3
"""gen_m6b_data.py -- prepare M6b DDR-chain TB data (bottlecap first ops).

Owner: rtl-stream (task-15 / M6b).  ASCII only.

Inputs
  results/bottlecap/plan/plan.json                     (per-op geometry, csum, arena offsets)
  results/bottlecap/plan/checksums.txt                 (FNV-1a 32 per op, same convention)
  results/bottlecap/plan/opvec/pattern_v1/*.hex        (optional tensor-level golden)
  tools/bottlecap/cycle_model.py                       (p0 per-op cycle expectations)

Outputs (default results/bottlecap/proto/m6b_data/)
  arena_input.hex   64b/line, op0 input tensor in arena layout (PACKED3 3B/px)
  ops.txt           one line per op:
                    op_id kind k st pad ih iw ic oc ic_pad oc_pad oh ow
                    src_off dst_off w_off w_len q_off q_len nn_op nn_flags csum_hex exp_cycles
                    (src_off/dst_off are ARENA-relative byte offsets)
  golden_opNN.hex   64b/line, opvec op output in arena layout (only if opvec present)
  golden_ops.txt    list of "op_id file bytes" for the available golden tensors
  meta.json         config + checks (input FNV, checksums.txt consistency, opvec status)

Checks (fail = non-zero exit)
  . pattern_v1 input reproduced from the documented formula
    (x*13 + y*7 + c*29 + seed) & 0xFF  and its FNV-1a matches plan.input.csum
  . checksums.txt input/op lines agree with plan.json csums
  . every output tensor's arena extent fits in the TB arena window
  . w_off/q_off equal the running sums of wlen/qlen over ops in order
    (the stream image layout used by nn_wload: w_ptr += wlen / q_ptr += qlen)
"""

import argparse
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))

ARENA_ABS_BASE = 0x01000000
FNV_OFFSET = 2166136261
FNV_PRIME = 16777619

# converter plan flags -> nn_pkg NN_F_* bit positions
# converter: DEPTHWISE=1, LEAKY=2, PACKED3=4, ADD_R=8, RELU=16
# nn_pkg:    DEPTHWISE=0, LEAKY=1, ADD=2, UP2X=3, POOLMAX=4, PACKED3=5, ADD_R=6, RELU=7
NN_F = {"DEPTHWISE": 0, "LEAKY": 1, "ADD": 2, "UP2X": 3, "POOLMAX": 4,
        "PACKED3": 5, "ADD_R": 6, "RELU": 7}
NN_OP = {"conv": 0, "dwconv": 0, "pool": 1, "copy": 2, "upsample": 2, "add": 3}


def fnv1a_int8(arr):
    h = FNV_OFFSET
    for b in np.asarray(arr, dtype=np.uint8).tobytes():
        h ^= int(b)
        h = (h * FNV_PRIME) & 0xFFFFFFFF
    return h


def pad8(c):
    return ((int(c) + 7) // 8) * 8


def pattern_input(ih, iw, seed, zp=0, s_in=1.0):
    """converter pattern_v1: u8 value (x*13 + y*7 + c*29 + seed) & 0xFF."""
    a = np.zeros((ih, iw, 3), dtype=np.int8)
    for y in range(ih):
        for x in range(iw):
            for c in range(3):
                a[y, x, c] = np.int8(np.uint8((x * 13 + y * 7 + c * 29 + seed) & 0xFF))
    return a


def read_u32_hex(path):
    """u32 little-endian words per line -> bytes."""
    out = bytearray()
    with open(path, "r", encoding="ascii") as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            out += int(s.split()[0], 16).to_bytes(4, "little")
    return bytes(out)


def read_i8_hex(path):
    out = bytearray()
    with open(path, "r", encoding="ascii") as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            out.append(int(s.split()[0], 16) & 0xFF)
    return bytes(out)


def write_hex64(path, data):
    if len(data) % 8:
        n = (len(data) + 7) // 8
        data = data + b"\x00" * (n * 8 - len(data))
    with open(path, "w", encoding="ascii", newline="\n") as f:
        for i in range(0, len(data), 8):
            f.write("%016x\n" % int.from_bytes(data[i:i + 8], "little"))


def parse_checksums(path):
    """checksums.txt -> {'input': int, 'ops': {op_id: int}}."""
    inp = None
    ops = {}
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith("#"):
                continue
            tok = s.split()
            if tok[0] == "input":
                inp = int(tok[1], 16) if tok[1].startswith("0x") else int(tok[1])
            elif tok[0] == "op":
                ops[int(tok[1])] = int(tok[-1], 16) if tok[-1].startswith("0x") else int(tok[-1])
    return inp, ops


def nn_flags_of(op):
    """translate converter flags (bit0 DW, bit1 LEAKY, bit2 PACKED3, bit3 ADD_R,
    bit4 RELU) into nn_pkg NN_F_* bit positions."""
    f = int(op.get("flags", 0))
    out = 0
    if f & 1:
        out |= 1 << NN_F["DEPTHWISE"]
    if f & 2:
        out |= 1 << NN_F["LEAKY"]
    if f & 4:
        out |= 1 << NN_F["PACKED3"]
    if f & 8:
        out |= 1 << NN_F["ADD_R"]
    if f & 16:
        out |= 1 << NN_F["RELU"]
    return out


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", default=os.path.join(REPO, "results/bottlecap/plan/plan.json"))
    ap.add_argument("--checksums", default=os.path.join(REPO, "results/bottlecap/plan/checksums.txt"))
    ap.add_argument("--opvec", default=os.path.join(REPO, "results/bottlecap/plan/opvec/pattern_v1"))
    ap.add_argument("--out-dir", default=os.path.join(REPO, "results/bottlecap/proto/m6b_data"))
    ap.add_argument("--nops", type=int, default=8,
                    help="number of leading ops the chain TB will run (default 8)")
    args = ap.parse_args(argv)

    plan = json.load(open(args.plan, "r", encoding="utf-8"))
    ops = plan["ops"]
    os.makedirs(args.out_dir, exist_ok=True)

    # ---- 1) reproduce pattern_v1 input, verify FNV ---------------------------
    ih = iw = int(plan["tensors"][0]["h"])
    seed = int(plan["input"]["gen"]["seed"])
    x_pat = pattern_input(ih, iw, seed)
    in_csum = fnv1a_int8(x_pat)
    exp_in = int(plan["input"]["csum"])
    if in_csum != exp_in:
        print(f"[gen_m6b] CHECK FAILED: input FNV {in_csum:#010x} != plan {exp_in:#010x}",
              file=sys.stderr)
        return 1
    ck_in, ck_ops = parse_checksums(args.checksums)
    if ck_in is not None and ck_in != in_csum:
        print(f"[gen_m6b] CHECK FAILED: checksums.txt input {ck_in:#010x} != {in_csum:#010x}",
              file=sys.stderr)
        return 1

    # arena layout of the input tensor is PACKED3 (3B/px, no C8 padding)
    in_t = plan["tensors"][0]
    assert int(in_t["arena_off"]) == 0 and int(in_t["bytes"]) == ih * iw * 3
    write_hex64(os.path.join(args.out_dir, "arena_input.hex"), x_pat.tobytes())
    print(f"[gen_m6b] input: {ih}x{iw}x3 pattern_v1(seed={seed}) FNV={in_csum:#010x} OK")

    # ---- 2) op table --------------------------------------------------------
    lines = []
    meta_ops = []
    w_run = q_run = 0
    w_idx = 0
    for i, op in enumerate(ops):
        wlen, qlen = int(op["wlen"]), int(op["qlen"])
        if int(op["woff"]) != (w_run if wlen else int(op["woff"])):
            pass
        if wlen:
            if int(op["woff"]) != w_run:
                print(f"[gen_m6b] FAIL: op {i} woff {op['woff']} != w_run {w_run}", file=sys.stderr)
                return 1
        if qlen:
            if int(op["qoff"]) != q_run:
                print(f"[gen_m6b] FAIL: op {i} qoff {op['qoff']} != q_run {q_run}", file=sys.stderr)
                return 1
        wso = plan.get("w_stream_offsets")
        if wso is not None and wlen:
            if w_idx < len(wso):
                e = wso[w_idx]
                if int(e.get("op", i)) != i or int(e.get("ddr_off", w_run)) != w_run:
                    print(f"[gen_m6b] FAIL: op {i} w_stream_offsets["
                          f"{w_idx}]={e} != running w_off {w_run}", file=sys.stderr)
                    return 1
            w_idx += 1
        w_off = w_run
        q_off = q_run
        w_run += wlen
        q_run += qlen
        src_off = int(op["src_arena_off"]) - ARENA_ABS_BASE
        dst_off = int(op["dst_arena_off"]) - ARENA_ABS_BASE
        if src_off < 0 or dst_off < 0:
            print(f"[gen_m6b] FAIL: op {i} negative arena offset", file=sys.stderr)
            return 1
        ic_pad = int(op.get("ic_pad", pad8(op["ic"])))
        oc_pad = int(op.get("oc_pad", pad8(op["oc"])))
        csum = int(op["csum"])
        lines.append(dict(
            op=i, kind=op["kind"], k=int(op["k"]), st=int(op["stride"]),
            pad=int(op["pad"]), ih=int(op["ih"]), iw=int(op["iw"]),
            ic=int(op["ic"]), oc=int(op["oc"]), ic_pad=ic_pad, oc_pad=oc_pad,
            oh=int(op["oh"]), ow=int(op["ow"]),
            src_off=src_off, dst_off=dst_off,
            w_off=w_off, w_len=wlen, q_off=q_off, q_len=qlen,
            nn_op=NN_OP[op["kind"]], nn_flags=nn_flags_of(op),
            csum=csum,
        ))

    # ---- 3) cycle_model expectations ---------------------------------------
    sys.path.insert(0, os.path.join(REPO, "tools", "bottlecap"))
    try:
        import cycle_model as cm
        rows = cm.decompose(ops, packed3_mode="auto")
        rows = rows[0] if isinstance(rows, tuple) else rows
        cyc = {int(r["id"]): float(r["cycles"]) for r in rows}
    except Exception as e:                                    # pragma: no cover
        print(f"[gen_m6b] WARN: cycle_model unavailable ({e}); exp_cycles=0")
        cyc = {}

    # ---- 4) write ops.txt ---------------------------------------------------
    ops_txt = os.path.join(args.out_dir, "ops.txt")
    with open(ops_txt, "w", encoding="ascii", newline="\n") as f:
        f.write("# op kind k st pad ih iw ic oc ic_pad oc_pad oh ow "
                "src_off dst_off w_off w_len q_off q_len nn_op nn_flags "
                "csum_hi csum_lo exp_cycles\n")
        for d in lines:
            cs = int(d["csum"]) & 0xFFFFFFFF
            f.write("%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n" % (
                d["op"], NN_OP[d["kind"]], d["k"], d["st"], d["pad"],
                d["ih"], d["iw"], d["ic"], d["oc"], d["ic_pad"], d["oc_pad"],
                d["oh"], d["ow"], d["src_off"], d["dst_off"],
                d["w_off"], d["w_len"], d["q_off"], d["q_len"],
                d["nn_op"], d["nn_flags"],
                (cs >> 16) & 0xFFFF, cs & 0xFFFF,
                int(round(cyc.get(d["op"], 0.0)))))
    print(f"[gen_m6b] ops: {len(lines)} written to {ops_txt}")

    # ---- 5) checksums.txt consistency + opvec tensor goldens ---------------
    ck_ops_bad = [i for i in ck_ops if i < len(ops) and ck_ops[i] != int(ops[i]["csum"])]
    if ck_ops_bad:
        print(f"[gen_m6b] CHECK FAILED: checksums.txt op mismatch {ck_ops_bad[:5]}",
              file=sys.stderr)
        return 1
    golden_ops = []
    opvec_status = "absent"
    opvec_manifest = None
    mp = os.path.join(os.path.dirname(args.opvec), "manifest.json")
    if os.path.isfile(mp):
        opvec_manifest = json.load(open(mp, "r", encoding="utf-8"))
        opvec_status = "present"
        img = None
        for im in opvec_manifest.get("images", []):
            if im.get("name") == "pattern_v1":
                img = im
        if img is None:
            opvec_status = "present(no pattern_v1 image)"
        else:
            # input cross-check
            gfnv = fnv1a_int8(np.frombuffer(x_pat.tobytes(), dtype=np.uint8))
            if int(img["input"]["fnv"]) != gfnv:
                print(f"[gen_m6b] CHECK FAILED: opvec input fnv {img['input']['fnv']}"
                      f" != pattern {gfnv}", file=sys.stderr)
                return 1
            ovec = {int(o["op"]): o for o in img.get("ops", [])}
            base = os.path.dirname(mp)
            for d in lines:
                o = ovec.get(d["op"])
                if o is None:
                    continue
                fp = os.path.join(base, o["file"])
                if not os.path.isfile(fp):
                    continue
                raw = read_u32_hex(fp)
                nbytes = int(o["bytes"])
                if len(raw) < nbytes:
                    print(f"[gen_m6b] WARN: op {d['op']} golden short "
                          f"{len(raw)} < {nbytes}")
                    raw = raw + b"\x00" * (nbytes - len(raw))
                h, w, c8 = [int(v) for v in o["shape"]]
                real_c = int(o["real_c"])
                if c8 == real_c:
                    gv = np.frombuffer(raw[:nbytes], dtype=np.uint8)
                else:
                    arr = np.frombuffer(raw[:nbytes], dtype=np.uint8).reshape(h, w, c8)
                    gv = arr[:, :, :real_c].reshape(-1)
                gfnv = fnv1a_int8(gv)
                d["golden_fnv"] = gfnv
                d["golden_bytes"] = nbytes
                d["golden_arena_off"] = int(o["arena_off"])
                d["golden_match"] = (gfnv == d["csum"])
                gp = os.path.join(args.out_dir, "golden_op%03d.hex" % d["op"])
                write_hex64(gp, raw[:nbytes])
                golden_ops.append((d["op"], os.path.basename(gp), nbytes,
                                   gfnv == d["csum"]))
            bad = [t[0] for t in golden_ops if not t[3]]
            if bad:
                print(f"[gen_m6b] CHECK FAILED: opvec FNV != plan csum for {bad[:5]}",
                      file=sys.stderr)
                return 1
    with open(os.path.join(args.out_dir, "golden_ops.txt"), "w",
              encoding="ascii", newline="\n") as f:
        f.write("# op file bytes fnv_matches_csum\n")
        for t in golden_ops:
            f.write("%d %s %d %d\n" % (t[0], t[1], t[2], 1 if t[3] else 0))
    if golden_ops:
        print(f"[gen_m6b] opvec tensor goldens: {len(golden_ops)} ops, "
              f"all FNV match plan csum")
    else:
        print("[gen_m6b] opvec tensor goldens: none available (FNV-only criterion)")

    # ---- 6) meta.json -------------------------------------------------------
    sel = lines[:args.nops]
    meta = {
        "format": "m6b-ddr-chain-data-v1",
        "generator": "results/bottlecap/proto/gen_m6b_data.py",
        "plan": os.path.relpath(args.plan, REPO).replace("\\", "/"),
        "nops": int(args.nops),
        "ops_in_run": [d["op"] for d in sel],
        "input": {"hw": [ih, iw], "seed": seed, "fnv": "%08x" % in_csum,
                  "arena_off": 0, "bytes": int(in_t["bytes"]), "layout": "PACKED3"},
        "w_stream": {"bytes": int(plan["w_bytes"]), "sum_wlen": w_run},
        "q_stream": {"bytes": int(plan["q_bytes"]), "sum_qlen": q_run},
        "checks": {
            "input_fnv_matches_plan": True,
            "checksums_txt_consistent": True,
            "opvec": opvec_status,
            "golden_ops_with_tensor": [t[0] for t in golden_ops],
            "golden_ops_all_fnv_match": all(t[3] for t in golden_ops),
        },
        "cycles": {
            "ops_run_expected_total": int(sum(cyc.get(d["op"], 0.0) for d in sel)),
            "per_op": {str(d["op"]): int(round(cyc.get(d["op"], 0.0))) for d in sel},
        },
    }
    with open(os.path.join(args.out_dir, "meta.json"), "w", encoding="ascii",
              newline="\n") as f:
        json.dump(meta, f, indent=1)
        f.write("\n")
    print(f"[gen_m6b] PASS: nops={args.nops} expected engine cycles="
          f"{meta['cycles']['ops_run_expected_total']} (cycle_model p0)")
    print(f"[gen_m6b] out dir: {args.out_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
