"""从 nn_mem.sv 提取 module header 生成 fpga/nn_mem_bb.sv 黑盒 stub。"""
import sys
src = open("nn_mem.sv", encoding="utf-8").read()
i = src.index("module nn_mem")
j = src.index(");", i)
header = src[i:j+2]
stub = ("// nn_mem 黑盒 stub (自动生成, 勿手改; 由 tools/gen_nn_mem_bb.py 从 nn_mem.sv 提取)\n"
        "// 整机综合时替换 nn_mem.sv, 综合后用 read_checkpoint -cell u_nn/u_mem <dcp> 链接 OOC 结果。\n"
        + header + "\n  // 空 body -> Vivado black box\nendmodule\n")
open("fpga/nn_mem_bb.sv", "w", encoding="utf-8", newline="\n").write(stub)
print("OK: fpga/nn_mem_bb.sv")
