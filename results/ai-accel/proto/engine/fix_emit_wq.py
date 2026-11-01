# -*- coding: utf-8 -*-
"""修 emit 的 wq 打印: 应打印字节偏移 (word*4), 与旧向量/TB 约定一致。"""
import io

P = "gen_vectors_v3extra.py"
s = io.open(P, encoding="utf-8").read()
old = '            f.write("%05x %08x\\n" % (a & 0xFFFFF, agg[a]))'
new = '            f.write("%05x %08x\\n" % ((a * 4) & 0xFFFFF, agg[a]))'
assert old in s, "not found"
s = s.replace(old, new, 1)
io.open(P, "w", encoding="utf-8").write(s)
print("emit wq fix applied")
