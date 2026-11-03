import re
log = open("tb_run10.log", encoding="utf-8", errors="ignore").read()
print("has CASE:", "CASE conv1x1_s1" in log)
for line in log.splitlines():
    if "CASE conv1x1_s1 " in line:
        print(repr(line)); break
