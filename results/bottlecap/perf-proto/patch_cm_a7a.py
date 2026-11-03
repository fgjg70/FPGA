import io

p = 'tools/bottlecap/cycle_model.py'
s = io.open(p, encoding='utf-8').read()

old = '''    if dwpath:
        # A7a(16 lane: A/2 + C/2) + A7b(row-buffer: B*0.38) 的实测口径（D 不变）
        saved = 0.0
        for r in rows:
            if r["detail"].get("cat") == "dw":
                a0, b0, c0 = r["A"], r["B"], r["C"]
                r["A"] = a0 / 2.0
                r["B"] = b0 * 0.38
                r["C"] = c0 / 2.0
                new = r["A"] + r["B"] + r["C"] + r["D"]
                saved += r["cycles"] - new
                r["cycles"] = new
        notes.append("dwpath(A7a+A7b): 省 %.0f 拍" % saved)'''
new = '''    if dwpath:
        # A7a 保守版实测口径（2026-11-04）：只有 ic==oc 且 %16==0 的 dw 层能 16-lane，
        #   OC tile 数减半 => 该层总周期 ≈ ×0.5（YOLO E2E 实测 141,931  vs 模型 142,765，差 0.6%）。
        #   其余 dw 层保持不变（旧 8-lane 路径）。A7b(行缓冲) 未实施，公式里不再假设。
        saved = 0.0
        for r in rows:
            if r["detail"].get("cat") == "dw":
                if r["ic"] == r["oc"] and r["oc"] % 16 == 0:
                    a0, b0, c0 = r["A"], r["B"], r["C"]
                    r["A"] = a0 / 2.0
                    r["B"] = b0 / 2.0
                    r["C"] = c0 / 2.0
                    new = r["A"] + r["B"] + r["C"] + r["D"]
                    saved += r["cycles"] - new
                    r["cycles"] = new
        notes.append("dwpath(A7a 保守版: 16-lane dw ×0.5): 省 %.0f 拍" % saved)'''
assert s.count(old) == 1, s.count(old)
s = s.replace(old, new)
io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('dwpath -> A7a conservative formula')
