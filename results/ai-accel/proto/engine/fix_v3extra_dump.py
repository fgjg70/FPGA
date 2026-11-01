# -*- coding: utf-8 -*-
"""修 gen_vectors_v3extra: a/b 期望文件用"区域内相对字索引"(与 TB 的 base+idx*8 对齐)。"""
import io

P = "gen_vectors_v3extra.py"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:200]
    s = s.replace(old, new, 1)


rep("""    def dump(imgs, tag):
        agg = {}
        for a, b in imgs.items():
            w = a >> 3
            agg.setdefault(w, [0, 0])
            agg[w][0 if (a & 7) < 4 else 1] = 0
        # 直接按 8B 字构造
        words = {}
        for a, b in imgs.items():
            w = a >> 3
            hi = (a & 4) != 0
            words.setdefault(w, [0, 0])
            words[w][1 if hi else 0] |= (b & 0xFF) << (8 * (a & 3))
        with open(os.path.join(OUT, "%s.%s.wr" % (n, tag)), "w", encoding="ascii") as f:
            for w in sorted(words):
                f.write("%04x %08x %08x\\n" % (w & 0xFFFF, words[w][1], words[w][0]))

    dump(case.a_img, "a")
    dump(case.b_img, "b")
    dump(case.a_exp, "aexp")
    dump(case.b_exp, "bexp")""",
    """    def dump(imgs, tag, base):
        words = {}
        for a, b in imgs.items():
            rel = a - base
            w = rel >> 3
            hi = (rel & 4) != 0
            words.setdefault(w, [0, 0])
            words[w][1 if hi else 0] |= (b & 0xFF) << (8 * (rel & 3))
        with open(os.path.join(OUT, "%s.%s.wr" % (n, tag)), "w", encoding="ascii") as f:
            for w in sorted(words):
                f.write("%04x %08x %08x\\n" % (w & 0xFFFF, words[w][1], words[w][0]))

    dump(case.a_img, "a", NA)
    dump(case.b_img, "b", NB)
    dump(case.a_exp, "aexp", NA)
    dump(case.b_exp, "bexp", NB)""")
io.open(P, "w", encoding="utf-8").write(s)
print("dump base fixed")
