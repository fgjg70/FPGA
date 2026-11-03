import json
import os
import sys

import numpy as np

ROOT = r"D:\USER\Desktop\FPGA\FPGA"
sys.path.insert(0, os.path.join(ROOT, "tools", "bottlecap"))
sys.path.insert(0, os.path.join(ROOT, "tools", "yolo"))
import golden_npu as gn  # noqa: E402
import quant_npu as qn   # noqa: E402

A0 = gn.load_artifacts(os.path.join(ROOT, "results", "bottlecap", "plan"))
A1 = gn.load_artifacts(os.path.join(ROOT, "results", "bottlecap", "plan", "fused_a"))
fm = json.load(open(os.path.join(ROOT, "results", "bottlecap", "plan", "fused_a",
                                 "FUSION-MAP.json"), encoding="utf-8"))
fused_adds = {m["add_op"] for m in fm["mappings"]}
hosts = {m["host_conv_op"]: m["add_op"] for m in fm["mappings"]}
old2new = {}
k = 0
for o in A0["ops"]:
    if o["id"] in fused_adds:
        continue
    old2new[o["id"]] = k
    k += 1
assert k == len(A1["ops"]), (k, len(A1["ops"]))
new2old = {v: k for k, v in old2new.items()}

# 输入图 (与 golden 同源: eval_seed+7)
files = qn.calibration_files(os.path.join(ROOT, "tools", "bottlecap", "data"), 3, 777 + 7)
imgs = qn.load_calib_images(files, 224)
roots0 = None
plans = [A0, A1]
tot = 0
maxdiff = 0
for ii, img in enumerate(imgs):
    # 两张 plan 的输入量化参数相同(s_in/zp_in 来自同一 group); 直接取 unfused plan
    p = A0["plan"]
    s_in, zp_in = float(p["input"]["s_in"]), int(p["input"]["zp_in"])
    xq = qn.quantize_input(img, s_in, zp_in)
    _ar0, _st0, out0 = gn.golden_forward(A0, xq)
    _ar1, _st1, out1 = gn.golden_forward(A1, xq)
    for nid, ref in out1.items():
        old = new2old[nid]
        # 融合 op: 参考应为被融 add 的输出
        ref_id = hosts.get(old, old)
        if ref_id not in out0:
            print("missing ref", nid, old, ref_id)
            continue
        a = ref.astype(np.int16)
        b = out0[ref_id].astype(np.int16)
        d = np.abs(a - b)
        tot += int((d != 0).sum())
        maxdiff = max(maxdiff, int(d.max()))
    print("img%d: ops compared=%d cumulative mismatch=%d" % (ii, len(out1), tot))
print("A-class fused vs unfused: mismatch_elems=%d max|diff|=%d" % (tot, maxdiff))
