# -*- coding: utf-8 -*-
import io

p = "est_full_model.py"
s = io.open(p, encoding="utf-8").read()
s = s.replace('"105 HW op"', "105 个 HW op")
io.open(p, "w", encoding="utf-8").write(s)
print("fixed" if '"105 HW op"' not in s else "still broken")
