import io

p = 'tools/bottlecap/cycle_model.py'
s = io.open(p, encoding='utf-8').read()
old = '    "p1_rtl": dict(fusion=True),          # 当前 RTL 特性集：仅融合（A4/A5e）'
new = ('    "p1_rtl": dict(fusion=True),          # 仅融合（A4/A5e）\n'
       '    "p1_a7a": dict(fusion=True, dwpath=True),   # 融合 + A7a 保守版（当前 RTL，2026-11-04）')
assert s.count(old) == 1
s = s.replace(old, new)
io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('p1_a7a scenario added')
