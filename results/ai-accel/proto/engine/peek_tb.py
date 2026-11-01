# -*- coding: utf-8 -*-
import io
import re

s = io.open("../../../../sim/tb_nn_engine.sv", encoding="utf-8", errors="replace").read()
lines = s.splitlines()
print("lines", len(lines))
for i, ln in enumerate(lines, 1):
    if re.search(r"load_wq|load_buf|check_buf|run_op|run_case|wq|desc\.qoff|desc\.woff|readmemh|plusargs|fopen|fscanf|vec=", ln):
        print(i, ln.strip()[:150])
