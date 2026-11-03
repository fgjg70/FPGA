#!/usr/bin/env python3
"""convert_u32_to_u64.py -- convert u32-LE hex file to 64b/line hex (for TB load)."""
import sys

src, dst = sys.argv[1], sys.argv[2]
words = []
for line in open(src, "r", encoding="ascii"):
    s = line.strip()
    if not s or s.startswith("#"):
        continue
    words.append(int(s.split()[0], 16))
if len(words) % 2:
    words.append(0)
with open(dst, "w", encoding="ascii", newline="\n") as f:
    for i in range(0, len(words), 2):
        f.write("%016x\n" % ((words[i + 1] << 32) | words[i]))
print(f"[conv] {src} -> {dst} ({len(words)*4} B)")
