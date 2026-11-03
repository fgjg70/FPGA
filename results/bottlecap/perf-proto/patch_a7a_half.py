import io

p = 'nn_conv_engine.sv'
s = io.open(p, encoding='utf-8').read()

old = "        dwbuf[ld_j_d] <= ld_fill_d ? {16{ld_fillbyte_d}} : a_rdata;   // v0.9 [A7a] dw 128b"
new = ("        // v0.9 [A7a] dw 128b 窗口：16-lane tile 用完整 16B；8-lane tile（ic8=8 或尾 tile）\n"
       "        // 必须沿用旧 8B 旋转语义（ld_half_d 选半窗）——否则奇数像素取错 8B。\n"
       "        dwbuf[ld_j_d] <= ld_fill_d ? {16{ld_fillbyte_d}}\n"
       "                       : (16'(act_l) == 16'd16) ? a_rdata\n"
       "                       : (ld_half_d ? {a_rdata[127:64], a_rdata[127:64]}\n"
       "                                    : {a_rdata[63:0], a_rdata[63:0]});")
assert s.count(old) == 1, s.count(old)
s = s.replace(old, new)
io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('dwbuf 8B-rotation fix applied')
