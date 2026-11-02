# -*- coding: utf-8 -*-
"""engine-report §0.7: 填根 tb sha + 联合验证说明."""
import io

P = "../../../engine-report.md"
s = io.open(P, encoding="utf-8").read()
old = "- `sim/tb_nn_engine.sv` = 待根 `nn_mem.sv` wpipe 落地后更新（LAT2 + 根 mem 版）"
new = """- `sim/tb_nn_engine.sv` = `ce574de04c323d8121ae4cb91bf525b55911f16f735fc0ccc8bca6b85ddbb0b9`
  （LAT2 + 真根 `nn_mem`(wpipe)；根 `nn_mem.sv` sha `0da19bf0…` 由 t-mem 提供）

**根目录联合回归**：`verify --only tb_nn_engine --force` → **PASS 3.6s**（47 case，含 l0 全尺寸 replay）；
proto 侧训练集（vec 47 + vec_v3extra 4）= **47/47 + 4/4 PASS, mismatch=0**（LAT2 + 根 wpipe mem）。
LAT1 兼容模式（`W_RD_LAT=1` + 旧 mem）47/47 PASS。"""
assert old in s
s = s.replace(old, new, 1)
io.open(P, "w", encoding="utf-8").write(s)
print("report updated with final TB sha")
