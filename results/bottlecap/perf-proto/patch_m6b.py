import io
import re

p = 'results/bottlecap/reports/M6-PERF-IMPL.md'
s = io.open(p, encoding='utf-8').read()
orig = len(s)

# 1) §1.3 场景表：用实测校准后的数字（13 拍/块融合代价）
s = s.replace('32,626,502', '32,719,099')
s = s.replace('32626502', '32719099')
s = s.replace('20,399,364', '20,426,805')
s = s.replace('20399364', '20426805')
s = s.replace('20,537,712', '20,587,903')
s = s.replace('20537712', '20587903')
s = s.replace('15,707,392', '15,757,583')
s = s.replace('15707392', '15757583')
s = s.replace('**32,626,502', '**32,719,099')
# p1 行里的 fps（3.75 -> 3.74 与 6.01->5.98 等按新 JSON 校准；只改明确的旧值组合）
s = s.replace('| **p1 融合+LB+dw（Step A）** | **32,719,099** | 69.6 | 3.06 | **3.75** | 4.60 |',
              '| **p1 融合+LB+dw（Step A）** | **32,719,099** | 69.4 | 3.06 | **3.74** | 4.58 |')
s = s.replace('| **p2b P1+PX16（Step B）** | **20,426,805** | 111.4 | 4.90 | **5.99** | 7.35 |',
              '| **p2b P1+PX16（Step B）** | **20,426,805** | 111.2 | 4.90 | **5.98** | 7.34 |')

# 2) §5 方法论：补两条 A5e 实战教训
anchor = '本次的三个"模型先行"收益'
if anchor in s and '$signed' not in s:
    lessons = (
        '**A5e 实战教训（RTL 侧，务必固化）**：\n'
        '1. `(* use_dsp = "no" *)` 写在 **function 内部变量**上 Vivado 2018.3 不认，乘法仍进 DSP48 且变成关键路径；'
        '要么写模块级 always_comb + 属性，要么流水化。\n'
        '2. Verilog 的 `+`/`*`/`>>`：**只要有一个操作数是 unsigned，整个表达式按 unsigned 算**。'
        '`(qd_w[l*8+:8]) + dv` 漏 `$signed()` 会把负 q_d 当无符号 → 全部饱和到 127；'
        '这次三级流水"功能失败"的真正根因就是这个（不是流水本身），补 `$signed()` 后逐位精确。\n'
        '3. 关键路径优化顺序：**先拆流水级（+1 拍/块）再看 OOC**，比在单拍里改结构收益大得多'
        '（-6.494ns → +1.125ns，代价仅 +3 拍/块）。\n\n'
    )
    s = s.replace(anchor, lessons + anchor)

io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('M6 numbers+lessons updated: %d -> %d chars' % (orig, len(s)))
