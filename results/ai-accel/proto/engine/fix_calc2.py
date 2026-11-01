# -*- coding: utf-8 -*-
"""更新 calc_cycles_v3 公式: q 打拍(+1/tile) + requant 三级(+1/block) + single16 变体。"""
import io

P = "calc_cycles_v3.py"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:200]
    s = s.replace(old, new, 1)


rep("""QPER8 = 10        # 8-lane  tile: S_Q(8) + QLOAD(2)
QLOAD = 2""",
    """QPER8 = 11        # 8-lane tile: S_Q(9, q_iss 0..q_tot+1) + QLOAD(2)
QLOAD = 2
REQP = 6          # requant 流水级数 (acc_sel..out 5 级 + 写起始偏 1)""")

rep("""def q_cycles(act):
    return q_tot(act) + 1 + QLOAD     # S_Q = q_tot+1 拍


def req_cyc(act):
    return 5 + (16 if act == 16 else 8) + 2""",
    """def q_cycles(act):
    return q_tot(act) + 4             # S_Q = q_tot+2 拍 (q 口打拍) + QLOAD 2


def req_cyc(act, oc8, dst16):
    if act == 16:
        beats = 8 if (oc8 % 16 == 0 and dst16) else 16
    else:
        beats = 8
    return REQP + beats + 2""")

rep("""def cycles_of(o):
    op = o['op']           # 0 conv,1 pool,2 copy,3 add""",
    """def cycles_of(o):
    op = o['op']           # 0 conv,1 pool,2 copy,3 add
    dst16 = ((o.get('dst', 0) & 0xF) == 0)""")

rep("""            tot += q_cycles(act)
            tot += NB * (1 + sub * per + DRN + req_cyc(act) + NEXT)""",
    """            tot += q_cycles(act)
            tot += NB * (1 + sub * per + DRN + req_cyc(act, oc8, dst16) + NEXT)""")
rep("""            tot += QPER8
            tot += NB * (1 + k * per + DRN + req_cyc(8) + NEXT)""",
    """            tot += QPER8
            tot += NB * (1 + k * per + DRN + req_cyc(8, oc8, dst16) + NEXT)""")

rep("""        d[a[0]] = dict(op=int(a[1]), flags=int(a[2]), k=int(a[3]), st=int(a[4]),
                       pad=int(a[5]), ih=int(a[6]), iw=int(a[7]), ic=int(a[8]),
                       oc=int(a[9]))""",
    """        d[a[0]] = dict(op=int(a[1]), flags=int(a[2]), k=int(a[3]), st=int(a[4]),
                       pad=int(a[5]), ih=int(a[6]), iw=int(a[7]), ic=int(a[8]),
                       oc=int(a[9]), src=int(a[10]), dst=int(a[11]))""")
rep("""if __name__ == "__main__":
    main()""",
    """if __name__ == "__main__":
    main()""")
io.open(P, "w", encoding="utf-8").write(s)
print("calc formula v3 updated")
