"""A7a 保守版门控：只有 ic8==oc8 且 %16==0 的 dw 用 16-lane；其余 dw 回退旧 8-lane。

在 patch_a7a_full.py + patch_a7a_half.py 之后运行。
"""
import io

p = 'nn_conv_engine.sv'
s = io.open(p, encoding='utf-8').read()
n = 0


def rep(old, new, cnt=1):
    global s, n
    assert s.count(old) == cnt, (old[:70], s.count(old), cnt)
    s = s.replace(old, new)
    n += 1


# 0) f_dw16 门控：dw 且 ic==oc 且都是 16 的倍数（这样每像素 16B 对齐、无尾 tile）
rep("  wire dense = is_conv && !f_dw;",
    "  wire dense = is_conv && !f_dw;\n"
    "  // v0.9 [A7a] dw 16-lane 仅用于 ic==oc 且 %16==0 的层（16B 对齐，无尾 tile）；\n"
    "  //            其余 dw（24/72/88...）回退旧 8-lane 路径，保证逐位等价。\n"
    "  wire f_dw16 = f_dw && ((d_oc[3:0] == 4'd0) && (d_ic[3:0] == 4'd0) && (d_oc == d_ic));")

# 1) 写回模式：只有 dw16 才走 16B/像素
rep("  wire single16 = ((dense || f_dw) && (act_l == 16'd16) && (oc8_r[3:0] == 4'd0) &&",
    "  wire single16 = ((dense || f_dw16) && (act_l == 16'd16) && (oc8_r[3:0] == 4'd0) &&")
rep("  wire wr_dense16 = (dense || f_dw) && (act_l == 16'd16);",
    "  wire wr_dense16 = (dense || f_dw16) && (act_l == 16'd16);")

# 2) MAC 输入：只有 dw16 用 128b 窗口；其余 dw 保持旧 win_sel 路径
rep("            else if (f_dw)\n              a_pipe[px][oc] <= (16'(oc) < act_l) ? dw_win[px][oc*8 +: 8] : 8'sd0;",
    "            else if (f_dw16)\n              a_pipe[px][oc] <= (16'(oc) < act_l) ? dw_win[px][oc*8 +: 8] : 8'sd0;")

# 3) dwbuf 装载：只有 dw16 需要（其余 dw 旧路径）；dw16 恒 16B 对齐
rep("""        // v0.9 [A7a] dw 128b 窗口：16-lane tile 用完整 16B；8-lane tile（ic8=8 或尾 tile）
        // 必须沿用旧 8B 旋转语义（ld_half_d 选半窗）——否则奇数像素取错 8B。
        dwbuf[ld_j_d] <= ld_fill_d ? {16{ld_fillbyte_d}}
                       : (16'(act_l) == 16'd16) ? a_rdata
                       : (ld_half_d ? {a_rdata[127:64], a_rdata[127:64]}
                                    : {a_rdata[63:0], a_rdata[63:0]});""",
    """        // v0.9 [A7a] dw16（ic8=oc8 且 %16==0 => 16B 对齐）用完整 128b；其余 dw 不用 dwbuf
        dwbuf[ld_j_d] <= ld_fill_d ? {16{ld_fillbyte_d}} : a_rdata;""")

# 4) tile 宽度：dw16 才 16
rep("ocw_r <= is_pool ? 16'd8 : 16'd16;   // v0.9 [A7a] dw 也 16 lane（pool 保持 8）",
    "ocw_r <= is_pool ? 16'd8 : ((f_dw && !f_dw16) ? 16'd8 : 16'd16);   // v0.9 [A7a] 仅 dw16 用 16")
rep(""": ((oc8_r + 16'd15) >> 4);""",
    """: ((f_dw && !f_dw16) ? (oc8_r >> 3) : ((oc8_r + 16'd15) >> 4));""")

# 5) dw tile 通道偏移：dw16 <<4，其余 dw <<3
rep("band_base <= f_dw ? (blk_base + (c_ocb << 4)) : blk_base;   // v0.9 [A7a] dw 16 lane/tile",
    "band_base <= f_dw ? (blk_base + (f_dw16 ? (c_ocb << 4) : (c_ocb << 3))) : blk_base;")
rep("la        <= f_dw ? (blk_base + (c_ocb << 4)) : blk_base;",
    "la        <= f_dw ? (blk_base + (f_dw16 ? (c_ocb << 4) : (c_ocb << 3))) : blk_base;")

io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('A7a conservative gate applied: %d replacements' % n)
