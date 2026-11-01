# -*- coding: utf-8 -*-
"""修 calc_cycles_v3: TB 日志是 PowerShell 重定向的 UTF-16LE, 自动探测解码。"""
import io

P = "calc_cycles_v3.py"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:160]
    s = s.replace(old, new, 1)


rep("""def parse_log(path):
    rows = {}
    txt = io.open(path, encoding="utf-8", errors="ignore").read()""",
    """def read_text_auto(path):
    raw = io.open(path, "rb").read()
    if len(raw) >= 2 and raw[0] == 0xFF and raw[1] == 0xFE:
        return raw.decode("utf-16")
    if b"\\x00" in raw[:200]:
        return raw.decode("utf-16-le", errors="ignore")
    return raw.decode("utf-8", errors="ignore")


def parse_log(path):
    rows = {}
    txt = read_text_auto(path)""")
rep("""    for ln in io.open(path, encoding="utf-8", errors="ignore"):""",
    """    for ln in read_text_auto(path).splitlines():""")
io.open(P, "w", encoding="utf-8").write(s)
print("utf16 detect added")
