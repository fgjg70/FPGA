# -*- coding: utf-8 -*-
"""R5 落根: 引擎 W_RD_LAT 默认值改 2, 复制为根 nn_conv_engine.sv。
   同时生成根 TB 版本 (LAT2 + 根 nn_mem) 到 proto (等 t-mem 根 mem wpipe 落地后再拷根)。"""
import hashlib
import io
import os
import shutil

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))

# 1) proto engine: 默认 W_RD_LAT = 2
p = os.path.join(HERE, "nn_conv_engine_v3.sv")
s = io.open(p, encoding="utf-8").read()
old = "  parameter int W_RD_LAT = 1        // W 读有效时延: 1=旧行为; 2=mem 侧 w_addr/w_re 寄存一拍"
new = "  parameter int W_RD_LAT = 2        // W 读有效时延: 2=配 wpipe mem (根默认); 1=旧 mem 兼容"
assert old in s, "engine W_RD_LAT default not found"
s = s.replace(old, new, 1)
io.open(p, "w", encoding="utf-8").write(s)

# 2) 覆盖根 engine
shutil.copyfile(p, os.path.join(ROOT, "nn_conv_engine.sv"))
b = open(os.path.join(ROOT, "nn_conv_engine.sv"), "rb").read()
print("root nn_conv_engine.sv", len(b), hashlib.sha256(b).hexdigest())

# 3) 根 TB 候选 (LAT2 + 根 nn_mem): 由 wpipe 版 TB 改回 nn_mem, 先放 proto
t = io.open(os.path.join(HERE, "tb_nn_engine_v3rw.sv"), encoding="utf-8").read()
t = t.replace("nn_mem_wpipe #(", "nn_mem #(")
assert "nn_mem_wpipe" not in t
io.open(os.path.join(HERE, "tb_nn_engine_root_lat2.sv"), "w", encoding="utf-8").write(t)
print("tb_nn_engine_root_lat2.sv written (proto; 待根 nn_mem wpipe 落地后拷 sim/tb_nn_engine.sv)")
