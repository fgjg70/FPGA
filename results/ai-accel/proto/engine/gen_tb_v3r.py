# -*- coding: utf-8 -*-
"""生成 tb_nn_engine_v3r.sv: 与 tb_nn_engine_v3.sv 完全相同, 但把内存换成根目录真 nn_mem.sv
   (用于定位 stub vs 真 mem 的端口语义差异)。"""
import io

src = io.open("tb_nn_engine_v3.sv", encoding="utf-8").read()
d = src
d = d.replace("""  nn_mem_v07_stub #(.A_BYTES(96*1024), .B_BYTES(32*1024)) u_mem (""",
              """  nn_mem #(.A_BYTES(96*1024), .B_BYTES(32*1024)) u_mem (""")
io.open("tb_nn_engine_v3r.sv", "w", encoding="utf-8").write(d)
print("tb v3r written (root nn_mem)")
