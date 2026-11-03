import io

p = 'results/bottlecap/reports/M6-PERF-IMPL.md'
add = io.open('results/bottlecap/perf-proto/_m6_add_2_8.md', encoding='utf-8').read()
s = io.open(p, encoding='utf-8').read()

anchor = '## 3. Step B 设计（PX16：16 px × 16 OC lane = 256 MAC/拍）'
assert s.count(anchor) == 1, s.count(anchor)
s = s.replace(anchor, add + anchor)

old_status = ('| **Step A 代码** | \u2705 **A1/A2/A4/A5 \u5168\u90e8\u843d\u5730\u5e76 PASS**\uff1a'
              '`ENGINE_TB: PASS (58 cases)`\uff1b\u65e7 47+9 \u4e0d\u53d8\uff1b'
              'YOLO E2E `npu_cycles=1,191,020` \u96f6\u56de\u9000\uff1b'
              '\u8d1f\u5411\u5bf9\u7167\u8bc1\u660e\u65b0 case \u6709\u7259\u9f7f\uff08\u89c1 \u00a72.7\uff09 |')
new_status = ('| **Step A 代码** | \u2705 **A1/A2/A4/A5/A5e \u5168\u90e8\u843d\u5730\u5e76 PASS**\uff1a'
              '`ENGINE_TB: PASS (58 cases)`\uff1b\u65e7 47+9 \u4e0d\u53d8\uff1b'
              'YOLO E2E `npu_cycles=1,191,020` \u96f6\u56de\u9000\uff1b'
              'OOC @122MHz **+1.125ns MET**\uff08\u89c1 \u00a72.8\uff09 |')
assert s.count(old_status) == 1, ('status', s.count(old_status))
s = s.replace(old_status, new_status)

io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('M6 updated, size', len(s))
