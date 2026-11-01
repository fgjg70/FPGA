# -*- coding: utf-8 -*-
"""更新 est_full_model_v3: 把 dst 绝对地址传入 (single16 判定), 重新估算。"""
import io

P = "est_full_model_v3.py"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:200]
    s = s.replace(old, new, 1)


rep("""PLAN = "../../../../sim/prog/yolo/plan.json\"""",
    """PLAN = "../../../../sim/prog/yolo/plan.json"
NN_A_OFF = 0x60000
NN_B_OFF = 0x78000


def dst_abs(o):
    d = o.get("dst")
    if isinstance(d, dict):
        return (NN_A_OFF if d.get("buf") == "A" else NN_B_OFF) + d.get("off", 0)
    return 0""")

rep("""def to_engine_op(o):
    kind = o["kind"]""",
    """def to_engine_op(o):
    kind = o["kind"]
    dabs = dst_abs(o)
    ret = _to_engine_op(o)
    ret["dst"] = dabs
    return ret


def _to_engine_op(o):
    kind = o["kind"]""")
io.open(P, "w", encoding="utf-8").write(s)
print("est v3 dst patch applied")
