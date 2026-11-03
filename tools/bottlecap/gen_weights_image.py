#!/usr/bin/env python3
"""gen_weights_image.py -- pack NPU int8 weights + Q params into DDR init images.

Owner: rtl-stream (task-8 / M3).  ASCII only (project discipline).
Supports BOTH plan formats in the repo:
  . sim/prog/yolo/plan.json                 (format *-int8-plan-v0.6: woff/qoff
    are explicit, wlen/qlen are derived from OC_pad/IC_pad/K)
  . results/bottlecap/plan/plan.json        (format *-int8-plan-v0.8: explicit
    wlen/qlen fields + per-op tile_plan)
and emits TWO image layouts:

  A) "plan layout" (kept for compatibility; the YOLO images already validated by
     sim/tb_nn_wstream.sv case_b): the W/Q region bytes exactly as the plan
     stores them, i.e. layer i at plan.woff / plan.qoff.
       <stem>_ddr_w.hex, <stem>_ddr_q.hex, <stem>_ddr_img.hex
       layer_offsets.json, <stem>_layers.txt

  B) "stream layout" (Lead decision 2026-11-03): W and Q payloads packed per op
     in plan.ops order with NO padding, so the hardware sequencer can use simple
     running pointers (w_ptr += wlen; q_ptr += qlen) and needs no extra ROM
     fields.  Layer starts are 8B aligned (all payloads are multiples of 8);
     starts at 8 (mod 16) are handled by nn_wload's leading-64b-word skip.
     For plans whose Q region is NOT in op order (e.g. the YOLO sample plan
     stores its 18 ADD_R Q blocks at the end) this layout re-orders Q into op
     order, which is exactly what makes q_ptr += qlen work.
       <stem>_ddr_stream_w.hex, <stem>_ddr_stream_q.hex,
       <stem>_ddr_stream_img.hex, layer_stream_offsets.json,
       <stem>_stream_layers.txt

All hex images are 64-bit-per-line little endian so beh_ddr3's 64-bit word
array can be $readmemh'ed byte-identically (no repacking in RTL).

Outputs (default stem=yolo -> results/bottlecap/stream/)
--------------------------------------------------------
  yolo_ddr_w.hex          64b/line, W region image (327,680 B for YOLO)
  yolo_ddr_q.hex          64b/line, Q region image ( 49,152 B for YOLO)
  yolo_ddr_img.hex        64b/line, W then Q concatenated (376,832 B)
  layer_offsets.json      per-layer offsets (plan layout) + constraints + sha
  yolo_layers.txt         "<op_id> <kind_code> <woff> <wlen> <qoff> <qlen>"
  yolo_ddr_stream_w.hex   64b/line, W payloads in op order (319,792 B)
  yolo_ddr_stream_q.hex   64b/line, Q payloads in op order ( 44,544 B)
  yolo_ddr_stream_img.hex stream W then stream Q (364,336 B)
  layer_stream_offsets.json  per-op {w_off,w_len,q_off,q_len} in stream coords
  yolo_stream_layers.txt  same columns as yolo_layers.txt, stream offsets

Hard constraints checked here (mirror the RTL checks in nn_wload.sv)
--------------------------------------------------------------------
  . per-layer wlen <= 131072 B   (W bank prefetch limit, rtl-mem portB rule)
  . per-layer qlen <= 8192 B     (Q shadow bank = 8 KiB / 1024 x64b words)
  . sum(wlen) == plan.w_bytes
  . sum(qlen) == plan.q_total_payload (YOLO) or sum of explicit qlen (bottlecap)
  . every plan woff/qoff reproduced exactly; plan-layout contiguity asserted
  . stream layout: per-op offsets 8B aligned; payloads multiples of 8
  . images round-trip (re-read 64b hex == source bytes)
"""

import argparse
import hashlib
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

PAD8 = lambda c: ((int(c) + 7) // 8) * 8

# kind codes shared with sim/tb_nn_wstream.sv
KIND_CODE = {"conv": 0, "dwconv": 1, "add": 2, "pool": 3, "copy": 4, "upsample": 5}
WEIGHT_KINDS = ("conv", "dwconv")
Q_KINDS = ("conv", "dwconv", "add")


class CheckError(RuntimeError):
    pass


def fail(msg):
    raise CheckError(msg)


# ---------------------------------------------------------------------------
# hex I/O
# ---------------------------------------------------------------------------
def read_hex32(path):
    """Read a 32-bit-per-line hex image -> bytearray (little endian words)."""
    words = []
    with open(path, "r", encoding="ascii") as f:
        for lineno, line in enumerate(f, 1):
            s = line.strip()
            if not s or s.startswith("#") or s.startswith("//"):
                continue
            tok = s.split()[0]
            if len(tok) != 8:
                fail(f"{path}:{lineno}: expected 8 hex chars (32-bit word), got {tok!r}")
            try:
                words.append(int(tok, 16))
            except ValueError:
                fail(f"{path}:{lineno}: not a hex value: {tok!r}")
    out = bytearray(len(words) * 4)
    for i, w in enumerate(words):
        out[4 * i:4 * i + 4] = w.to_bytes(4, "little")
    return out


def read_hex64(path):
    """Read a 64-bit-per-line hex image -> list of 64-bit ints (cross-check)."""
    words = []
    with open(path, "r", encoding="ascii") as f:
        for lineno, line in enumerate(f, 1):
            s = line.strip()
            if not s or s.startswith("#") or s.startswith("//"):
                continue
            tok = s.split()[0]
            if len(tok) > 16:
                fail(f"{path}:{lineno}: >16 hex chars for a 64-bit word: {tok!r}")
            try:
                words.append(int(tok, 16))
            except ValueError:
                fail(f"{path}:{lineno}: not a hex value: {tok!r}")
    return words


def write_hex64(path, data, sha_list=None):
    """Write bytes as 64-bit-per-line hex (little endian, low word first)."""
    if len(data) % 8 != 0:
        fail(f"{path}: data length {len(data)} is not a multiple of 8")
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    with open(p, "w", encoding="ascii", newline="\n") as f:
        for i in range(0, len(data), 8):
            f.write("%016x\n" % int.from_bytes(data[i:i + 8], "little"))
    h = hashlib.sha256(bytes(data)).hexdigest()
    if sha_list is not None:
        sha_list.append((str(p), len(data), h))
    return h


def pack64(data):
    """bytes -> list of little-endian 64-bit words (for cross-checks)."""
    if len(data) % 8:
        fail("pack64: length is not a multiple of 8")
    return [int.from_bytes(data[i:i + 8], "little") for i in range(0, len(data), 8)]


# ---------------------------------------------------------------------------
# plan parsing
# ---------------------------------------------------------------------------
def oc_pad_of(op):
    return int(op["oc_pad"]) if "oc_pad" in op else PAD8(op["oc"])


def ic_pad_of(op):
    return int(op["ic_pad"]) if "ic_pad" in op else PAD8(op["ic"])


def qlen_of(kind, op):
    """Q bytes per op (CONTRACT section 7) when the plan has no qlen field."""
    if kind in ("conv", "dwconv"):
        return 6 * oc_pad_of(op) + 16
    if kind == "add":
        return 16
    return 0


def wlen_of(kind, op):
    """Weight bytes per op when the plan has no wlen field."""
    oc_pad = oc_pad_of(op)
    if kind == "conv":
        return oc_pad * ic_pad_of(op) * int(op["k"]) * int(op["k"])
    if kind == "dwconv":
        return oc_pad * int(op["k"]) * int(op["k"])
    return 0


def collect_layers(plan):
    """Per-op payload table in plan.ops order; validates against the plan."""
    ops = plan["ops"]
    layers = []
    for op in ops:
        kind = op["kind"]
        if kind not in KIND_CODE:
            fail(f"op {op['id']}: unknown kind {kind!r}")
        woff = int(op.get("woff", -1))
        qoff = int(op.get("qoff", -1))
        wlen_explicit = int(op["wlen"]) if "wlen" in op else None
        qlen_explicit = int(op["qlen"]) if "qlen" in op else None

        if kind in WEIGHT_KINDS:
            wlen_calc = wlen_of(kind, op)
            if wlen_explicit is not None and wlen_explicit != wlen_calc:
                fail(f"op {op['id']} ({kind}): explicit wlen={wlen_explicit} != "
                     f"formula {wlen_calc} (OC_pad/IC_pad/K)")
            wlen = wlen_explicit if wlen_explicit is not None else wlen_calc
        else:
            wlen = wlen_explicit if wlen_explicit is not None else 0
            if wlen != 0:
                fail(f"op {op['id']} ({kind}): non-weight op with wlen={wlen}")

        qlen_calc = qlen_of(kind, op)
        if qlen_explicit is not None and kind in Q_KINDS and qlen_explicit != qlen_calc:
            fail(f"op {op['id']} ({kind}): explicit qlen={qlen_explicit} != "
                 f"formula {qlen_calc} (6*OC_pad+16)")
        if kind in Q_KINDS:
            qlen = qlen_explicit if qlen_explicit is not None else qlen_calc
        else:
            qlen = qlen_explicit if qlen_explicit is not None else 0
            if qlen != 0:
                fail(f"op {op['id']} ({kind}): non-Q op with qlen={qlen}")

        if wlen > 0 and woff < 0:
            fail(f"op {op['id']}: wlen>0 but woff={woff}")
        if qlen > 0 and qoff < 0:
            fail(f"op {op['id']}: qlen>0 but qoff={qoff}")

        layers.append({
            "stream_seq": -1,   # filled below (streaming layer order)
            "op_id": int(op["id"]),
            "layer_idx": int(op.get("layer_idx", -1)),
            "kind": kind,
            "kind_code": KIND_CODE[kind],
            "k": int(op.get("k", 0)),
            "stride": int(op.get("stride", 1)),
            "pad": int(op.get("pad", 0)),
            "ic": int(op.get("ic", 0)),
            "oc": int(op.get("oc", 0)),
            "oc_pad": oc_pad_of(op),
            "ic_pad": ic_pad_of(op),
            "ih": int(op.get("ih", 0)),
            "iw": int(op.get("iw", 0)),
            "woff": woff if wlen else -1,
            "wlen": wlen,
            "qoff": qoff if qlen else -1,
            "qlen": qlen,
        })

    # ---- totals / W layout --------------------------------------------------
    sum_w = sum(L["wlen"] for L in layers)
    sum_q = sum(L["qlen"] for L in layers)
    if sum_w != int(plan["w_bytes"]):
        fail(f"sum(wlen)={sum_w} != plan.w_bytes={plan['w_bytes']}")
    q_expected = int(plan["q_total_payload"]) if "q_total_payload" in plan else sum_q
    if sum_q != q_expected:
        fail(f"sum(qlen)={sum_q} != plan Q payload {q_expected}")
    if "q_bytes" in plan and int(plan["q_bytes"]) < sum_q:
        fail(f"plan.q_bytes={plan['q_bytes']} < sum(qlen)={sum_q}")

    w_run = 0
    for L in layers:
        if L["wlen"] > 0:
            if L["woff"] != w_run:
                fail(f"op {L['op_id']} ({L['kind']}): woff {L['woff']} != running "
                     f"sum {w_run} (plan W must be packed in op order)")
            w_run += L["wlen"]
    if w_run != sum_w:
        fail(f"W running sum {w_run} != sum(wlen) {sum_w}")

    # ---- Q layout classification -------------------------------------------
    # op_order : qoff[i] == sum of previous qlen (running pointer works directly)
    # two_run  : conv/dw blocks contiguous from 0, then ADD blocks at the end
    #            (the YOLO sample plan); the stream layout re-orders it.
    q_run = 0
    op_order = True
    for L in layers:
        if L["qlen"] > 0:
            if L["qoff"] != q_run:
                op_order = False
                break
            q_run += L["qlen"]
    q_layout = "op_order"
    if not op_order:
        q_run = 0
        for L in layers:                       # conv/dw run first
            if L["kind"] in WEIGHT_KINDS and L["qlen"] > 0:
                if L["qoff"] != q_run:
                    fail(f"op {L['op_id']}: Q layout is neither op-order nor "
                         f"conv/dw-run+add-run (qoff {L['qoff']} != {q_run})")
                q_run += L["qlen"]
        q_conv_end = q_run
        add_run = q_conv_end
        for L in layers:                       # then ADD_R blocks
            if L["kind"] == "add" and L["qlen"] > 0:
                if L["qoff"] != add_run:
                    fail(f"op {L['op_id']}: ADD Q block qoff {L['qoff']} != {add_run}")
                add_run += L["qlen"]
        if add_run != sum_q:
            fail(f"Q two-run sum {add_run} != sum(qlen) {sum_q}")
        q_layout = "two_run"

    # ---- per-op streaming order (ops that carry W or Q payload) -------------
    seq = 0
    for L in layers:
        if L["wlen"] > 0 or L["qlen"] > 0:
            L["stream_seq"] = seq
            seq += 1
    return layers, sum_w, sum_q, q_layout, seq


def build_stream(layers, w_img, q_img):
    """Pack W and Q payloads in op order, no padding; returns images + table."""
    w_stream = bytearray()
    q_stream = bytearray()
    entries = []
    for L in layers:
        if L["stream_seq"] < 0:
            continue
        w_off = -1
        q_off = -1
        if L["wlen"] > 0:
            a, b = L["woff"], L["woff"] + L["wlen"]
            if b > len(w_img):
                fail(f"op {L['op_id']}: W payload [{a}:{b}] exceeds W image "
                     f"size {len(w_img)}")
            w_off = len(w_stream)
            w_stream += w_img[a:b]
        if L["qlen"] > 0:
            a, b = L["qoff"], L["qoff"] + L["qlen"]
            if b > len(q_img):
                fail(f"op {L['op_id']}: Q payload [{a}:{b}] exceeds Q image "
                     f"size {len(q_img)}")
            q_off = len(q_stream)
            q_stream += q_img[a:b]
        entries.append({
            "stream_seq": L["stream_seq"],
            "op_id": L["op_id"],
            "layer_idx": L["layer_idx"],
            "kind": L["kind"],
            "kind_code": L["kind_code"],
            "k": L["k"],
            "stride": L["stride"],
            "pad": L["pad"],
            "ic": L["ic"],
            "oc": L["oc"],
            "w_off": w_off,
            "w_len": L["wlen"],
            "q_off": q_off,
            "q_len": L["qlen"],
        })
    return bytes(w_stream), bytes(q_stream), entries


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--plan", default=str(REPO / "sim/prog/yolo/plan.json"))
    ap.add_argument("--w-hex", default=str(REPO / "sim/prog/yolo/yolo_w.hex"),
                    help="W region image, 32-bit-per-line hex")
    ap.add_argument("--q-hex", default=str(REPO / "sim/prog/yolo/yolo_q.hex"),
                    help="Q region image, 32-bit-per-line hex")
    ap.add_argument("--out-dir", default=str(REPO / "results/bottlecap/stream"))
    ap.add_argument("--stem", default="yolo", help="output file stem")
    ap.add_argument("--w-base-byte", type=lambda s: int(s, 0), default=0,
                    help="DDR byte base address of the W region (informational)")
    ap.add_argument("--q-base-byte", type=lambda s: int(s, 0), default=None,
                    help="DDR byte base address of the Q region "
                         "(default: plan image = W region size; "
                         "stream image = stream W size)")
    ap.add_argument("--max-wlen", type=lambda s: int(s, 0), default=131072)
    ap.add_argument("--max-qlen", type=lambda s: int(s, 0), default=8192)
    args = ap.parse_args(argv)

    plan = json.load(open(args.plan, "r", encoding="utf-8"))
    layers, sum_w, sum_q, q_layout, n_stream = collect_layers(plan)

    w_img = read_hex32(args.w_hex)
    q_img = read_hex32(args.q_hex)
    w_region = len(w_img)
    q_region = len(q_img)
    w_bytes = int(plan["w_bytes"])

    # ---- capacity / alignment assertions -----------------------------------
    if w_region % 16:
        fail(f"W image size {w_region} not a multiple of 16")
    if q_region % 16:
        fail(f"Q image size {q_region} not a multiple of 16")
    if w_bytes > w_region:
        fail(f"plan.w_bytes={w_bytes} exceeds W image size {w_region}")
    if sum_q > q_region:
        fail(f"sum(qlen)={sum_q} exceeds Q image size {q_region}")

    n_wlayers = sum(1 for L in layers if L["wlen"] > 0)
    n_qlayers = sum(1 for L in layers if L["qlen"] > 0)
    w_misaligned16 = 0
    for L in layers:
        if L["wlen"] > 0:
            if L["wlen"] > args.max_wlen:
                fail(f"op {L['op_id']} ({L['kind']}): wlen={L['wlen']} > "
                     f"max_wlen={args.max_wlen} (W bank prefetch limit)")
            if L["wlen"] % 8:
                fail(f"op {L['op_id']}: wlen={L['wlen']} is not a multiple of 8")
            if L["woff"] % 8:
                fail(f"op {L['op_id']}: woff={L['woff']} is not 8B aligned")
            if L["woff"] % 16:
                w_misaligned16 += 1
        if L["qlen"] > 0:
            if L["qlen"] > args.max_qlen:
                fail(f"op {L['op_id']} ({L['kind']}): qlen={L['qlen']} > "
                     f"max_qlen={args.max_qlen}")
            if L["qlen"] % 8:
                fail(f"op {L['op_id']}: qlen={L['qlen']} is not a multiple of 8")
            if L["qoff"] % 8:
                fail(f"op {L['op_id']}: qoff={L['qoff']} is not 8B aligned")

    # ---- plan-layout DDR absolute addresses --------------------------------
    w_base = args.w_base_byte
    q_base_plan = args.q_base_byte if args.q_base_byte is not None else w_region
    for L in layers:
        L["ddr_waddr"] = (w_base + L["woff"]) if L["wlen"] else None
        L["ddr_qaddr"] = (q_base_plan + L["qoff"]) if L["qlen"] else None
        L["wlen_words"] = (L["wlen"] + 7) // 8
        L["qlen_words"] = (L["qlen"] + 7) // 8
        L["wfill_word0"] = 0
        L["qfill_word0"] = 0
        L["w_lead_words"] = 0 if L["wlen"] == 0 else (L["woff"] % 16) // 8
        L["q_lead_words"] = 0 if L["qlen"] == 0 else (L["qoff"] % 16) // 8

    # ---- write plan-layout images -----------------------------------------
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    sha_list = []
    w_out = out_dir / f"{args.stem}_ddr_w.hex"
    q_out = out_dir / f"{args.stem}_ddr_q.hex"
    img_out = out_dir / f"{args.stem}_ddr_img.hex"
    w_sha = write_hex64(w_out, w_img, sha_list)
    q_sha = write_hex64(q_out, q_img, sha_list)
    combined = bytes(w_img) + bytes(q_img)
    comb_sha = write_hex64(img_out, combined, sha_list)

    if read_hex64(w_out) != pack64(w_img):
        fail("round-trip check failed: 64b W image != source W image")
    if read_hex64(q_out) != pack64(q_img):
        fail("round-trip check failed: 64b Q image != source Q image")
    if read_hex64(img_out) != pack64(combined):
        fail("round-trip check failed: combined DDR image mismatch")
    if "wq_bytes" in plan and len(combined) != int(plan["wq_bytes"]):
        fail(f"combined image {len(combined)} B != plan.wq_bytes={plan['wq_bytes']}")

    # ---- layers table (plan layout, for the existing TB) -------------------
    txt_out = out_dir / f"{args.stem}_layers.txt"
    with open(txt_out, "w", encoding="ascii", newline="\n") as f:
        f.write("# op_id kind_code woff wlen qoff qlen   (plan layout: W/Q region)\n")
        for L in layers:
            if L["stream_seq"] < 0:
                continue
            f.write("%4d %2d %8d %7d %8d %6d\n" % (
                L["op_id"], L["kind_code"],
                L["woff"] if L["wlen"] else -1, L["wlen"],
                L["qoff"] if L["qlen"] else -1, L["qlen"]))

    doc = {
        "format": "npu-ddr-weight-image-v1",
        "generator": "tools/bottlecap/gen_weights_image.py",
        "source": {
            "plan": str(Path(args.plan)).replace("\\", "/"),
            "w_hex": str(Path(args.w_hex)).replace("\\", "/"),
            "q_hex": str(Path(args.q_hex)).replace("\\", "/"),
        },
        "plan_format": plan.get("format"),
        "regions": {
            "w": {
                "region_bytes": w_region,
                "payload_bytes": sum_w,
                "slack_bytes": w_region - sum_w,
                "ddr_byte_base": w_base,
                "ddr_word_off": w_base // 8,
                "image": w_out.name,
                "sha256": w_sha,
            },
            "q": {
                "region_bytes": q_region,
                "payload_bytes": sum_q,
                "slack_bytes": q_region - sum_q,
                "ddr_byte_base": q_base_plan,
                "ddr_word_off": q_base_plan // 8,
                "image": q_out.name,
                "sha256": q_sha,
            },
            "combined": {
                "bytes": len(combined),
                "image": img_out.name,
                "sha256": comb_sha,
            },
        },
        "constraints": {
            "max_wlen_bytes": args.max_wlen,
            "max_qlen_bytes": args.max_qlen,
            "wfill_word_idx_max": 20479,
            "qfill_word_idx_max": 1023,
            "fill_start_word": 0,
            "note": "all layers are filled layer-relative from bank word 0; "
                    "W bank prefetch must stay <= 128 KiB (rtl-mem portB arbitration)",
        },
        "counts": {
            "ops_total": len(plan["ops"]),
            "stream_layers": n_stream,
            "weight_layers": n_wlayers,
            "q_layers": n_qlayers,
            "add_q_blocks": sum(1 for L in layers if L["kind"] == "add"),
            "sum_wlen": sum_w,
            "sum_qlen": sum_q,
            "w_layers_not_16b_aligned": w_misaligned16,
            "q_layout": q_layout,
        },
        "layers": layers,
    }
    json_out = out_dir / "layer_offsets.json"
    with open(json_out, "w", encoding="ascii", newline="\n") as f:
        json.dump(doc, f, indent=1)
        f.write("\n")

    # ======================================================================
    # B) stream layout: exact op-order concatenation (no padding)
    # ======================================================================
    w_stream, q_stream, s_entries = build_stream(layers, w_img, q_img)
    sum_sw = sum(e["w_len"] for e in s_entries)
    sum_sq = sum(e["q_len"] for e in s_entries)
    if sum_sw != sum_w:
        fail(f"stream sum(wlen)={sum_sw} != {sum_w}")
    if sum_sq != sum_q:
        fail(f"stream sum(qlen)={sum_sq} != {sum_q}")
    if len(w_stream) % 8 or len(q_stream) % 8:
        fail("stream image sizes are not 8B aligned")
    for e in s_entries:
        if e["w_off"] >= 0 and (e["w_off"] % 8):
            fail(f"op {e['op_id']}: stream w_off {e['w_off']} not 8B aligned")
        if e["q_off"] >= 0 and (e["q_off"] % 8):
            fail(f"op {e['op_id']}: stream q_off {e['q_off']} not 8B aligned")
    # For plans whose W region is already op-order contiguous (both current
    # plans) the stream W image must be byte-identical to the W payload prefix.
    if bytes(w_stream) != bytes(w_img[:sum_w]):
        fail("stream W image differs from the plan W payload prefix")

    sw_out = out_dir / f"{args.stem}_ddr_stream_w.hex"
    sq_out = out_dir / f"{args.stem}_ddr_stream_q.hex"
    simg_out = out_dir / f"{args.stem}_ddr_stream_img.hex"
    sw_sha = write_hex64(sw_out, w_stream, sha_list)
    sq_sha = write_hex64(sq_out, q_stream, sha_list)
    s_combined = w_stream + q_stream
    simg_sha = write_hex64(simg_out, s_combined, sha_list)
    if read_hex64(sw_out) != pack64(w_stream):
        fail("round-trip check failed: stream W image")
    if read_hex64(sq_out) != pack64(q_stream):
        fail("round-trip check failed: stream Q image")
    if read_hex64(simg_out) != pack64(s_combined):
        fail("round-trip check failed: stream combined image")

    q_base_stream = len(w_stream)
    for e in s_entries:
        e["ddr_waddr"] = (w_base + e["w_off"]) if e["w_len"] else None
        e["ddr_qaddr"] = (q_base_stream + e["q_off"]) if e["q_len"] else None
        e["w_lead_words"] = 0 if e["w_len"] == 0 else (e["w_off"] % 16) // 8
        e["q_lead_words"] = 0 if e["q_len"] == 0 else (e["q_off"] % 16) // 8

    s_txt = out_dir / f"{args.stem}_stream_layers.txt"
    with open(s_txt, "w", encoding="ascii", newline="\n") as f:
        f.write("# op_id kind_code w_off w_len q_off q_len   "
                "(stream layout: W stream / Q stream, no padding)\n")
        for e in s_entries:
            f.write("%4d %2d %8d %7d %8d %6d\n" % (
                e["op_id"], e["kind_code"],
                e["w_off"] if e["w_len"] else -1, e["w_len"],
                e["q_off"] if e["q_len"] else -1, e["q_len"]))

    s_misaligned16 = sum(1 for e in s_entries
                         if e["w_len"] > 0 and (e["w_off"] % 16))
    s_doc = {
        "format": "npu-ddr-stream-image-v1",
        "generator": "tools/bottlecap/gen_weights_image.py",
        "note": "W and Q payloads concatenated per op in plan.ops order with NO "
                "padding; use w_ptr += w_len / q_ptr += q_len in the sequencer. "
                "Layer starts are 8B aligned; starts at 8 (mod 16) are handled by "
                "nn_wload's leading-64b-word skip.",
        "source": doc["source"],
        "plan_format": plan.get("format"),
        "regions": {
            "w": {
                "bytes": len(w_stream),
                "ddr_byte_base": w_base,
                "image": sw_out.name,
                "sha256": sw_sha,
                "layers_not_16b_aligned": s_misaligned16,
            },
            "q": {
                "bytes": len(q_stream),
                "ddr_byte_base": q_base_stream,
                "image": sq_out.name,
                "sha256": sq_sha,
            },
            "combined": {
                "bytes": len(s_combined),
                "q_stream_base": len(w_stream),
                "image": simg_out.name,
                "sha256": simg_sha,
            },
        },
        "constraints": doc["constraints"],
        "counts": {
            "stream_layers": n_stream,
            "weight_layers": n_wlayers,
            "q_layers": n_qlayers,
            "sum_wlen": sum_sw,
            "sum_qlen": sum_sq,
            "w_layers_not_16b_aligned": s_misaligned16,
            "plan_q_layout": q_layout,
            "q_reordered": (q_layout != "op_order"),
        },
        "layers": s_entries,
    }
    s_json = out_dir / "layer_stream_offsets.json"
    with open(s_json, "w", encoding="ascii", newline="\n") as f:
        json.dump(s_doc, f, indent=1)
        f.write("\n")

    # ---- summary -----------------------------------------------------------
    print("=" * 78)
    print("  gen_weights_image.py: PASS")
    print("=" * 78)
    print(f"  plan            : {args.plan}")
    print(f"  plan format     : {plan.get('format')}")
    print(f"  W region        : {w_region:>9} B  payload {w_bytes:>9} B  slack {w_region - w_bytes:>7} B")
    print(f"  Q region        : {q_region:>9} B  payload {sum_q:>9} B  slack {q_region - sum_q:>7} B")
    print(f"  plan image      : {len(combined):>9} B")
    print(f"  stream image    : W {len(w_stream):>9} B + Q {len(q_stream):>9} B = {len(s_combined):>9} B")
    print(f"  stream layers   : {n_stream}  (weight {n_wlayers}, Q {n_qlayers}, "
          f"add-Q {doc['counts']['add_q_blocks']})")
    print(f"  plan q layout   : {q_layout}"
          + ("  -> stream Q REORDERED into op order"
             if q_layout != "op_order" else "  (stream Q == plan Q order)"))
    print(f"  sum(wlen)       : {sum_w} B  (== plan.w_bytes)")
    print(f"  sum(qlen)       : {sum_q} B")
    print(f"  max single wlen : {max((L['wlen'] for L in layers), default=0)} B (limit {args.max_wlen})")
    print(f"  max single qlen : {max((L['qlen'] for L in layers), default=0)} B (limit {args.max_qlen})")
    print(f"  W layers not 16B aligned (lead-word skip): {s_misaligned16}")
    print("  outputs:")
    for p, n, h in sha_list:
        print(f"    {p}  {n:>9} B  sha256={h[:16]}")
    print(f"    {json_out}")
    print(f"    {txt_out}")
    print(f"    {s_json}")
    print(f"    {s_txt}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except CheckError as e:
        print(f"[gen_weights_image] CHECK FAILED: {e}", file=sys.stderr)
        sys.exit(1)
