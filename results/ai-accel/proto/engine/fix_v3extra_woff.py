# -*- coding: utf-8 -*-
"""修 gen_vectors_v3extra: packed3 的 W 字节应放在 woff 偏移 (manifest 的 woff 才一致)。"""
import io

P = "gen_vectors_v3extra.py"
s = io.open(P, encoding="utf-8").read()

old = "    c.put_w(0, wbytes)"
new = "    c.put_w(c.woff, wbytes)"
assert old in s
s = s.replace(old, new, 1)
io.open(P, "w", encoding="utf-8").write(s)
print("put_w offset fixed")
