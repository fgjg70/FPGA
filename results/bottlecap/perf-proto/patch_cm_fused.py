import io

p = 'tools/bottlecap/cycle_model.py'
s = io.open(p, encoding='utf-8').read()

# 1) dwpath 改成与 A7a+A7b 实测口径一致：A/2 + B*0.38 + C/2 + D（saving 2.4158M on bottlecap plan）
old_dw = '''    if dwpath:
        saved = 0.0
        for r in rows:
            if r["detail"].get("cat") == "dw":
                a0 = r["A"]
                new = a0 / 2.0 + (r["cycles"] - a0) * 0.38
                saved += r["cycles"] - new
                r["A"] = a0 / 2.0
                r["B"] *= 0.38
                r["C"] *= 0.38
                r["cycles"] = new
                r["D"] = new - r["A"] - r["B"] - r["C"]
        notes.append("dwpath: 省 %.0f 拍" % saved)'''
new_dw = '''    if dwpath:
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
assert s.count(old_dw) == 1
s = s.replace(old_dw, new_dw)

# 2) fusion 分支：支持"plan 已融合"（按 fused_add 标记）：不再扣 add（已不在 plan 里），只加 13 拍/块
old_f = '''    if fusion:
        saved = 0.0
        for r in rows:
            if r["detail"].get("cat") == "elemwise" and r["kind"] in ("add", "copy"):
                saved += r["cycles"]
                r["cycles"] = r["A"] = r["B"] = r["C"] = r["D"] = 0.0'''
new_f = '''    if fusion:
        already_fused = any("fused_add" in o for o in ops)
        saved = 0.0
        if not already_fused:
            for r in rows:
                if r["detail"].get("cat") == "elemwise" and r["kind"] in ("add", "copy"):
                    saved += r["cycles"]
                    r["cycles"] = r["A"] = r["B"] = r["C"] = r["D"] = 0.0'''
assert s.count(old_f) == 1
s = s.replace(old_f, new_f)

# 3) 已融合 plan：融合块按 fused_add 标记的 conv 计（13 拍/块），不再用 add 映射
old_cost = '''        # A5e 实测口径：融合进 conv 的 add 使该 conv 每个输出块 +13 拍
        #   = S_ADRD 读 dst (wrbeats+2=10) + 写回延后 3 拍（三项流水）；1 个输出块 = 8 拍写
        #   （16 lane 单16B 模式；8-lane 尾块最多 +21）
        _fids, fidx = fused_conv_ids(ops)
        fuse_cost = 0.0
        for j in fidx:
            r = rows[j]
            nb = r["detail"].get("pblocks", 0) * r["detail"].get("n_tiles", 1)
            add = 13.0 * nb
            r["D"] += add
            r["cycles"] += add
            fuse_cost += add
        notes.append("fusion: add+copy %.0f 拍 -> %d 个 conv、%.0f 拍融合代价(13 拍/块)"
                     % (saved, len(fidx), fuse_cost))'''
new_cost = '''        # A5e 实测口径：融合进 conv 的 add 使该 conv 每个输出块 +13 拍
        #   = S_ADRD 读 dst (wrbeats+2=10) + 写回延后 3 拍（三项流水）；1 个输出块 = 8 拍写
        #   （16 lane 单16B 模式；8-lane 尾块最多 +21）
        if already_fused:
            fidx = [j for j, o in enumerate(ops) if "fused_add" in o]
        else:
            _fids, fidx = fused_conv_ids(ops)
        fuse_cost = 0.0
        for j in fidx:
            r = rows[j]
            nb = r["detail"].get("pblocks", 0) * r["detail"].get("n_tiles", 1)
            add = 13.0 * nb
            r["D"] += add
            r["cycles"] += add
            fuse_cost += add
        notes.append("fusion%s: add+copy %.0f 拍 -> %d 个 conv、%.0f 拍融合代价(13 拍/块)"
                     % ("(已融合plan)" if already_fused else "", saved, len(fidx), fuse_cost))'''
assert s.count(old_cost) == 1
s = s.replace(old_cost, new_cost)

# 4) 新增 p1_rtl 场景（= 当前 RTL 只有融合）
old_sc = '''    "p1": dict(fusion=True, bopt=0.7, dwpath=True),'''
new_sc = '''    "p1_rtl": dict(fusion=True),          # 当前 RTL 特性集：仅融合（A4/A5e）
    "p1": dict(fusion=True, bopt=0.7, dwpath=True),'''
assert s.count(old_sc) == 1
s = s.replace(old_sc, new_sc)

io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('cycle_model patched: plan-driven fusion + dwpath A7a/A7b + p1_rtl')
