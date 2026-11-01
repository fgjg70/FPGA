# -*- coding: utf-8 -*-
"""生成真实层 replay 向量 (l2 dw / l7 add) 并入 vec/ 回归。
   - 输入放 A@0, 输出放 A@align16(input_bytes) (放不下则 B@0)
   - W 放 W 区 0, Q 放 Q 区 0; desc 字段按 plan + v0.7 规则映射
"""
import io
import json
import os
import shutil

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
YOLO = os.path.join(ROOT, "sim", "prog", "yolo")
VEC = os.path.join(HERE, "vec")
NN_A = 0x60000
NN_B = 0x78000
NN_Q = 0x50000
A_BYTES = 96 * 1024
B_BYTES = 32 * 1024

plan = json.load(open(os.path.join(YOLO, "plan.json"), encoding="utf-8"))
ops = plan["ops"] if isinstance(plan, dict) else plan
byid = {o["id"]: o for o in ops}


def rb(name):
    return [int(x, 16) for x in io.open(os.path.join(YOLO, name), encoding="ascii").read().split()]


def rw(name):
    return [int(x, 16) for x in io.open(os.path.join(YOLO, name), encoding="ascii").read().split()]


def pad8(c):
    return ((c + 7) // 8) * 8


def ab_words(base_abs, data, region_base):
    words = {}
    for i, b in enumerate(data):
        rel = (base_abs - region_base) + i
        wd = rel >> 3
        words.setdefault(wd, [0, 0, 0])
        words[wd][(rel >> 2) & 1] |= b << (8 * (rel & 3))
        words[wd][2] = 1
    return words


def write_ab(fn, words):
    with io.open(fn, "w", encoding="ascii") as f:
        for wd in sorted(words):
            f.write("%04x %08x %08x\n" % (wd, words[wd][1], words[wd][0]))


def wq_lines(wbytes, qwords):
    agg = {}
    for i, b in enumerate(wbytes):
        a = i  # W-relative 0
        agg[a // 4] = agg.get(a // 4, 0) | (b << (8 * (a % 4)))
    lines = [("%05x %08x" % (a * 4, agg[a])) for a in sorted(agg)]
    for i, wd in enumerate(qwords):
        lines.append(("%05x %08x" % (NN_Q + i * 4, wd)))
    return lines


def gen(op_id, name):
    o = byid[op_id]
    kind = o["kind"]
    inp = rb("l%d_in.hex" % op_id)
    out = rb("l%d_out.hex" % op_id)
    ic, oc = o["ic"], o["oc"]
    ic8, oc8 = pad8(ic), pad8(oc)
    ih, iw = o["ih"], o["iw"]
    k = max(1, o["k"])
    # 输入/输出字节数校验
    assert len(inp) >= ih * iw * ic8 or kind == "copy", (name, len(inp))
    # op/flags 映射 (v0.7)
    flags = o.get("flags", 0)
    leaky = (flags >> 1) & 1
    if kind == "conv":
        op = 0
        eflags = (0x02 if leaky else 0) | (0x20 if (flags >> 2) & 1 else 0)
    elif kind == "dwconv":
        op = 0
        eflags = 0x01 | (0x02 if leaky else 0)
    elif kind == "add":
        op = 3
        eflags = 0x40
    elif kind == "copy":
        op = 2
        eflags = 0x08 if kind == "upsample" else 0
    elif kind == "upsample":
        op = 2
        eflags = 0x08
    else:
        raise SystemExit("unsupported kind " + kind)

    # 输入放 A@0
    in_bytes = ih * iw * ic8
    dst_off = (in_bytes + 15) // 16 * 16
    if dst_off + max(len(out), 1) <= A_BYTES:
        dst_base, dst_region = NN_A + dst_off, NN_A
        aexp = True
    else:
        dst_base, dst_region = NN_B, NN_B
        aexp = False

    # W/Q 加载
    wf = os.path.join(YOLO, "l%d_w.hex" % op_id)
    qf = os.path.join(YOLO, "l%d_q.hex" % op_id)
    wbytes = rb("l%d_w.hex" % op_id) if os.path.exists(wf) else []
    qwords = rw("l%d_q.hex" % op_id) if os.path.exists(qf) else []
    lines = wq_lines(wbytes, qwords)
    io.open(os.path.join(VEC, name + ".wq.wr"), "w", encoding="ascii").write(
        "\n".join(lines) + ("\n" if lines else ""))

    # A 装载 = 输入; 期望 = 输出
    io.open(os.path.join(VEC, name + ".b.wr"), "w", encoding="ascii").write("")
    io.open(os.path.join(VEC, name + ".bexp.wr"), "w", encoding="ascii").write("")
    write_ab(os.path.join(VEC, name + ".a.wr"), ab_words(NN_A, inp[:in_bytes], NN_A))
    if aexp:
        # 只比较输出字节 (如果 out 比 dst 余量短, 用 len(out))
        exp = out[:A_BYTES - dst_off]
        write_ab(os.path.join(VEC, name + ".aexp.wr"), ab_words(dst_base, exp, NN_A))
    else:
        write_ab(os.path.join(VEC, name + ".aexp.wr"), {})
        write_ab(os.path.join(VEC, name + ".bexp.wr"), ab_words(NN_B, out, NN_B))

    # manifest 行
    row = "%s %d %d %d %d %d %d %d %d %d %d %d %d %d" % (
        name, op, eflags, k, max(1, o["stride"]), o["pad"], ih, iw, ic, oc,
        NN_A, dst_base, 0, 0)
    return row


def main():
    rows = []
    rows.append(gen(2, "replay_l2_dw"))
    rows.append(gen(7, "replay_l7_add"))
    # 追加到 manifest (去重)
    mpath = os.path.join(VEC, "manifest.txt")
    man = io.open(mpath, encoding="ascii").read().splitlines()
    for r in rows:
        nm = r.split()[0]
        man = [m for m in man if not m.startswith(nm + " ")]
        man.append(r)
    io.open(mpath, "w", encoding="ascii").write("\n".join(man) + "\n")
    print("appended:", [r.split()[0] for r in rows], "total cases:", len(man))


if __name__ == "__main__":
    main()
