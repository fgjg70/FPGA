import io

p = 'results/bottlecap/reports/M6-PERF-IMPL.md'
add = io.open('results/bottlecap/perf-proto/_m6_add_2_9.md', encoding='utf-8').read()
s = io.open(p, encoding='utf-8').read()
anchor = '## 3. Step B 设计（PX16：16 px × 16 OC lane = 256 MAC/拍）'
assert s.count(anchor) == 1
s = s.replace(anchor, add + anchor)
io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('M6 section 2.9 appended, chars', len(s))
