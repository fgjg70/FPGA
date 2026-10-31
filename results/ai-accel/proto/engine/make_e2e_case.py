#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ============================================================================
# make_e2e_case.py — 用 T-model 的 l<op>_*.hex 生成"单 op 重放"TB 向量
#   目的: 在 engine TB 里逐位复现 E2E 的某个 op, 判断 mismatch 在引擎内还是集成层。
#
# 用法:
#   python make_e2e_case.py all          # 代表性 op 集合, 写 vec_e2e/manifest.txt
#   python make_e2e_case.py 2            # 只生成 op2
# 读 sim/prog/yolo/plan.json + l<op>_{in,w,q,out}.hex, 按 CONTRACT §8/§6/§7 v0.3.1
# 打包成 A/B + W/Q 镜像。支持 conv / dwconv / pool / upsample (add 需 dst 初值, 跳过)。
# ============================================================================
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
YOLO = os.path.join(REPO, "sim", "prog", "yolo")
_pkg = open(os.path.join(REPO, "nn_pkg.sv"), "r", encoding="utf-8", errors="ignore").read()


def pint(name):
    m = re.search(r"localparam\s+(?:logic\s*\[31:0\]\s+|int\s+unsigned\s+)" + name +
                  r"\s*=\s*(32'h[0-9A-Fa-f_]+|[0-9]+\*1024|[0-9]+)", _pkg)
    tok = m.group(1).replace("_", "")
    if tok.startswith("32'h"):
        return int(tok[4:], 16)
    if "*" in tok:
        a, b = tok.split("*")
        return int(a) * int(b)
    return int(tok)


NN_W_OFF = pint("NN_W_OFF")
NN_Q_OFF = pint("NN_Q_OFF")
NN_A_OFF = pint("NN_A_OFF")
NN_B_OFF = pint("NN_B_OFF")
NN_WQ_BYTES = pint("NN_W_BYTES") + pint("NN_Q_BYTES")
NN_A_BYTES = pint("NN_A_BYTES")
NN_B_BYTES = pint("NN_B_BYTES")
A_END = NN_A_OFF + NN_A_BYTES
B_END = NN_B_OFF + NN_B_BYTES


def pad8(c):
    return ((c + 7) // 8) * 8


def read_hex_bytes(path):
    vals = []
    with open(path, "r", encoding="ascii") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("@"):
                vals.append(int(line, 16) & 0xFF)
    return bytes(vals)


def read_hex_words(path):
    out = []
    with open(path, "r", encoding="ascii") as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(int(line, 16))
    return out


def pack_tensor(flat, h, w, c, c8):
    out = bytearray(h * w * c8)
    for i in range(h * w):
        out[i * c8:i * c8 + c] = flat[i * c:(i + 1) * c]
    return bytes(out)


def fnv1a(bs):
    h = 2166136261
    for b in bs:
        h ^= b
        h = (h * 16777619) & 0xFFFFFFFF
    return h


def buf_of(off):
    if NN_A_OFF <= off < A_END:
        return "a", off - NN_A_OFF
    if NN_B_OFF <= off < B_END:
        return "b", off - NN_B_OFF
    raise SystemExit("offset 0x%X not in A/B" % off)


def gen_one(plan, opid, outdir):
    op = plan["ops"][opid]
    kind, k, st, pad = op["kind"], op["k"], op["stride"], op["pad"]
    ih, iw, ic, oc = op["ih"], op["iw"], op["ic"], op["oc"]
    c8, oc8 = pad8(ic), pad8(oc)
    base = os.path.join(YOLO, "l%d" % opid)
    outname = "e2e_op%d" % opid

    if kind == "cpu_conv0":
        in_flat = read_hex_bytes(os.path.join(YOLO, "l0_in.hex"))
    else:
        in_flat = read_hex_bytes(base + "_in.hex")
    assert len(in_flat) == ih * iw * ic, \
        "%s_in.hex: %d != %d" % (base, len(in_flat), ih * iw * ic)

    if kind in ("conv", "dwconv", "cpu_conv0"):
        oh = (ih + 2 * pad - k) // st + 1
        ow = (iw + 2 * pad - k) // st + 1
        out_c = oc
    elif kind == "pool":
        pp = pad if pad else (k - 1) // 2
        oh = (ih + 2 * pp - k) // st + 1
        ow = (iw + 2 * pp - k) // st + 1
        out_c = ic
    elif kind == "upsample":
        oh, ow, out_c = ih * 2, iw * 2, ic
    else:
        raise SystemExit("unsupported kind %s" % kind)
    out_flat = read_hex_bytes(base + "_out.hex")
    assert len(out_flat) == oh * ow * out_c, \
        "%s_out.hex: %d != %d" % (base, len(out_flat), oh * ow * out_c)
    c8_out = pad8(out_c)

    def to_off(ref):
        return (NN_A_OFF if ref["buf"] == "A" else NN_B_OFF) + ref["off"]

    src = to_off(op["src"])
    dst = to_off(op["dst"])

    A = bytearray(NN_A_BYTES)
    B = bytearray(NN_B_BYTES)

    def put(off, data):
        which, p = buf_of(off)
        buf = A if which == "a" else B
        assert p + len(data) <= len(buf), "region overflow op%d" % opid
        buf[p:p + len(data)] = data

    put(src, pack_tensor(in_flat, ih, iw, ic, c8))
    expA, expB = bytearray(A), bytearray(B)

    if kind in ("conv", "dwconv", "cpu_conv0"):
        qw = read_hex_words(base + "_q.hex")
        assert len(qw) * 4 == 6 * oc8 + 16, "Q payload words %d" % len(qw)
        qbytes = b"".join(w.to_bytes(4, "little") for w in qw)
        zp_out = qbytes[6 * oc8]
        zp_out = zp_out - 256 if zp_out >= 128 else zp_out
        out_bytes = bytearray(oh * ow * oc8)
        for i in range(oh * ow):
            out_bytes[i * oc8:i * oc8 + out_c] = out_flat[i * out_c:(i + 1) * out_c]
            for c in range(out_c, oc8):
                out_bytes[i * oc8 + c] = zp_out & 0xFF
        out_bytes = bytes(out_bytes)
    else:
        out_bytes = pack_tensor(out_flat, oh, ow, out_c, c8_out)
    put(dst, bytes(len(out_bytes)))
    which, p = buf_of(dst)
    (expA if which == "a" else expB)[p:p + len(out_bytes)] = out_bytes

    wq = bytearray(NN_WQ_BYTES)
    woff, qoff = op.get("woff", -1), op.get("qoff", -1)
    wb = b""
    if woff >= 0:
        wb = read_hex_bytes(base + "_w.hex")
        if kind == "dwconv":
            assert len(wb) == k * k * pad8(oc), "dw weight bytes %d" % len(wb)
        else:
            assert len(wb) == k * k * pad8(ic) * pad8(oc), \
                "dense weight bytes %d" % len(wb)
        wq[woff - NN_W_OFF:woff - NN_W_OFF + len(wb)] = wb
        assert qoff >= 0
        wq[qoff - NN_Q_OFF:qoff - NN_Q_OFF + len(qbytes)] = qbytes

    flags = 0
    if kind == "dwconv":
        flags |= 1
    if kind == "upsample":
        flags |= 8
    if op.get("leaky", 0):
        flags |= 2
    op_code = 0 if kind in ("conv", "dwconv", "cpu_conv0") else \
              (1 if kind == "pool" else 2)
    man = "%s %d %d %d %d %d %d %d %d %d %d %d %d %d" % (
        outname, op_code, flags, k, st, pad, ih, iw, ic, oc, src, dst,
        max(woff, 0), max(qoff, 0))

    lines = []
    for i in range(0, len(wb), 4):
        w = wb[i] | (wb[i + 1] << 8) | (wb[i + 2] << 16) | (wb[i + 3] << 24)
        lines.append("%x %08x" % (woff + i, w))
    if woff >= 0:
        for i in range(0, len(qbytes), 4):
            w = (qbytes[i] | (qbytes[i + 1] << 8) | (qbytes[i + 2] << 16)
                 | (qbytes[i + 3] << 24))
            lines.append("%x %08x" % (qoff + i, w))
    open(os.path.join(outdir, outname + ".wq.wr"), "w", encoding="ascii").write(
        "\n".join(lines) + ("\n" if lines else ""))

    def emit_full(path, buf):
        ls = []
        for i in range(len(buf) // 8):
            v = int.from_bytes(buf[i * 8:i * 8 + 8], "little")
            ls.append("%x %08x %08x" % (i, (v >> 32) & 0xFFFFFFFF, v & 0xFFFFFFFF))
        open(path, "w", encoding="ascii").write("\n".join(ls) + "\n")

    emit_full(os.path.join(outdir, outname + ".a.wr"), A)
    emit_full(os.path.join(outdir, outname + ".b.wr"), B)
    emit_full(os.path.join(outdir, outname + ".aexp.wr"), expA)
    emit_full(os.path.join(outdir, outname + ".bexp.wr"), expB)

    ec = fnv1a(out_flat)
    ok = (op["csum"] == ec)
    extra = ""
    if kind in ("conv", "dwconv"):
        extra = " zp_out=%d SHIFT=%d" % (zp_out, qbytes[6 * oc8 + 3])
    print("op%-3d %-8s %2dx%2dx%3d->%-3d k=%d st=%d pad=%d  csum %s%s" % (
        opid, kind, ih, iw, ic, oc, k, st, pad, "OK" if ok else "MISMATCH", extra))
    if not ok:
        print("  plan csum=0x%08X  l%d_out fnv=0x%08X" % (op["csum"], opid, ec))
    return man


def main():
    outdir = os.path.join(HERE, "vec_e2e")
    os.makedirs(outdir, exist_ok=True)
    plan = json.load(open(os.path.join(YOLO, "plan.json"), encoding="utf-8"))
    if len(sys.argv) > 1 and sys.argv[1] == "all":
        ids = [2, 70, 93, 96, 100, 101]
    else:
        ids = [int(sys.argv[1]) if len(sys.argv) > 1 else 2]
    mans = []
    for opid in ids:
        if plan["ops"][opid]["kind"] in ("add", "cpu_concat", "cpu_conv0"):
            print("op%-3d skip kind=%s (需要 dst 初值/CPU)" % (opid, plan["ops"][opid]["kind"]))
            continue
        mans.append(gen_one(plan, opid, outdir))
    open(os.path.join(outdir, "manifest.txt"), "w", encoding="ascii").write(
        "\n".join(mans) + "\n")
    print("wrote %d cases -> %s" % (len(mans), outdir))


if __name__ == "__main__":
    main()
