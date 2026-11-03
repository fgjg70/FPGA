import io

p = 'nn_conv_engine.sv'
s = io.open(p, encoding='utf-8').read()
report = {}

# 1) wby_r：lane 门控按 act_l（dense 16 / dw16 16 / dw8 8 / pool 8 与原语义等价）
n = s.count('(dense || (oc < 8))')
s = s.replace('(dense || (oc < 8))', "(dense || (16'(oc) < act_l))")
report['wby_r_gate'] = n

# 2) S_WI：dwbsh 初始化
old = 'for (int i = 0; i < WINW; i++) bshift[i] <= abuf[i];'
n = s.count(old)
s = s.replace(old, old + '\n          for (int i = 0; i < WINW; i++) dwbsh[i] <= dwbuf[i];   // v0.9 [A7a]')
report['dwbsh_init'] = n

# 3) ocw_r：dense 16 / dw 16 / pool 8
old = "ocw_r <= dense ? 16'd16 : 16'd8;"
n = s.count(old)
s = s.replace(old, "ocw_r <= is_pool ? 16'd8 : 16'd16;   // v0.9 [A7a] dw 也 16 lane（pool 保持 8）")
report['ocw_r'] = n

# 4) oc_limit_r：dense/dw 都按 16-lane tile；pool 保持 8
old = """: dense    ? ((oc8_r + 16'd15) >> 4)
                                     : (oc8_r >> 3);"""
n = s.count(old)
s = s.replace(old, """: ((oc8_r + 16'd15) >> 4);""")
report['oc_limit'] = n

# 5) dw tile 偏移 8→16 通道
old = "band_base <= f_dw ? (blk_base + (c_ocb << 3)) : blk_base;"
n1 = s.count(old)
s = s.replace(old, "band_base <= f_dw ? (blk_base + (c_ocb << 4)) : blk_base;   // v0.9 [A7a] dw 16 lane/tile")
old = "la        <= f_dw ? (blk_base + (c_ocb << 3)) : blk_base;"
n2 = s.count(old)
s = s.replace(old, "la        <= f_dw ? (blk_base + (c_ocb << 4)) : blk_base;")
report['dw_off'] = (n1, n2)

io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print(report)
