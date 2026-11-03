"""A7a 完整补丁（从 A5e 基线一键重放；重新实施时直接跑本脚本）。

2026-11-04 第一次实施结果（已回退，树保持 A5e 绿）：
- dw ic=oc>=16 的 case PASS（dw3x3_c16/c13、dw5x5_c16、m1_ic864_dw3x3）；
- dw ic=oc=8 与 ic=24 的 5 个 case FAIL（dw3x3_c8/s2、dw5x5_c8/s2、dw3x3_c24，misB 35..90）
  => 怀疑点：act_l=8 的 tile 里 lane 8..15 现在是"无意义窗口数据 × wby_r=0"，但某处
     （rq_pack 的 padding-lane 屏蔽 or 8-lane 写回 half-beat 映射）与旧 8-lane 行为不等价。
  下一步：先只把 a_pipe 的 dw lane 8..15 在 act_l=8 时强制 0（与旧行为逐位一致），
  再逐级打开 16-lane，用 58-case 二分定位。
"""
import io

p = 'nn_conv_engine.sv'
s = io.open(p, encoding='utf-8').read()
n = 0


def rep(old, new, cnt=1):
    global s, n
    assert s.count(old) == cnt, (old[:60], s.count(old), cnt)
    s = s.replace(old, new)
    n += 1


# 1) dw 专用 128b 窗口声明
rep("""  logic [63:0] abuf  [0:BANDW-1];
  logic [63:0] bshift[0:WINW-1];""",
    """  logic [63:0] abuf  [0:BANDW-1];
  logic [63:0] bshift[0:WINW-1];
  // v0.9 [A7a] dw 专用 128b 窗口（16 通道/像素）：仅 f_dw 装载/移位，dense 共用流水零改动
  logic [127:0] dwbuf [0:BANDW-1];
  logic [127:0] dwbsh [0:WINW-1];""")

# 2) 写回模式：dw 16-lane 也走 16B/像素单拍
rep("""  wire single16 = (dense && (act_l == 16'd16) && (oc8_r[3:0] == 4'd0) &&
                   (d_dst[3:0] == 4'd0));
  wire wr_dense16 = dense && (act_l == 16'd16);""",
    """  wire single16 = ((dense || f_dw) && (act_l == 16'd16) && (oc8_r[3:0] == 4'd0) &&
                   (d_dst[3:0] == 4'd0));
  wire wr_dense16 = (dense || f_dw) && (act_l == 16'd16);""")

# 3) dw 128b 窗口（win_sel 之后）
rep("""  logic [63:0] win_sel [0:PX-1];
  always_comb begin
    for (int px = 0; px < PX; px++) begin
      if (dense && (d_ks == 4'd1))
        win_sel[px] = abuf[px];
      else
        win_sel[px] = st2_r ? bshift[2*px] : bshift[px];
    end
  end""",
    """  logic [63:0] win_sel [0:PX-1];
  always_comb begin
    for (int px = 0; px < PX; px++) begin
      if (dense && (d_ks == 4'd1))
        win_sel[px] = abuf[px];
      else
        win_sel[px] = st2_r ? bshift[2*px] : bshift[px];
    end
  end
  // v0.9 [A7a] dw 专用 128b 窗口（仅 f_dw 使用）
  logic [127:0] dw_win [0:PX-1];
  always_comb begin
    for (int px = 0; px < PX; px++)
      dw_win[px] = st2_r ? dwbsh[2*px] : dwbsh[px];
  end""")

# 4) 装载存 128b
rep("""      if (ld_ret_v) begin
        if (ld_fill_d) abuf[ld_j_d] <= {8{ld_fillbyte_d}};
        else           abuf[ld_j_d] <= ld_half_d ? a_rdata[127:64] : a_rdata[63:0];
      end""",
    """      if (ld_ret_v) begin
        if (ld_fill_d) abuf[ld_j_d] <= {8{ld_fillbyte_d}};
        else           abuf[ld_j_d] <= ld_half_d ? a_rdata[127:64] : a_rdata[63:0];
        dwbuf[ld_j_d] <= ld_fill_d ? {16{ld_fillbyte_d}} : a_rdata;   // v0.9 [A7a] dw 128b
      end""")

# 5) 窗口滑动
rep("""      if (win_adv) begin
        for (int i = 0; i < WINW-1; i++) bshift[i] <= bshift[i+1];
        bshift[WINW-1] <= abuf[15 + cur_kx[3:0]];
      end""",
    """      if (win_adv) begin
        for (int i = 0; i < WINW-1; i++) bshift[i] <= bshift[i+1];
        bshift[WINW-1] <= abuf[15 + cur_kx[3:0]];
        for (int i = 0; i < WINW-1; i++) dwbsh[i] <= dwbsh[i+1];      // v0.9 [A7a]
        dwbsh[WINW-1] <= dwbuf[15 + cur_kx[3:0]];
      end""")

# 6) MAC 输入：dw 取 128b 窗口
rep("""            if (dense)
              a_pipe[px][oc] <= win_sel[px][sel_byte_base +: 8];
            else
              a_pipe[px][oc] <= (oc < 8) ? win_sel[px][oc*8 +: 8] : 8'sd0;""",
    """            if (dense)
              a_pipe[px][oc] <= win_sel[px][sel_byte_base +: 8];
            else if (f_dw)
              a_pipe[px][oc] <= (16'(oc) < act_l) ? dw_win[px][oc*8 +: 8] : 8'sd0;
            else
              a_pipe[px][oc] <= (oc < 8) ? win_sel[px][oc*8 +: 8] : 8'sd0;""")

# 7) 权重 lane 门控（两处 LAT2/LAT1 分支）
rep("(dense || (oc < 8))", "(dense || (16'(oc) < act_l))", cnt=2)

# 8) S_WI 初始化 dwbsh
rep("for (int i = 0; i < WINW; i++) bshift[i] <= abuf[i];",
    "for (int i = 0; i < WINW; i++) bshift[i] <= abuf[i];\n          for (int i = 0; i < WINW; i++) dwbsh[i] <= dwbuf[i];   // v0.9 [A7a]")

# 9) tile 宽度：dense 16 / dw 16 / pool 8
rep("ocw_r <= dense ? 16'd16 : 16'd8;",
    "ocw_r <= is_pool ? 16'd8 : 16'd16;   // v0.9 [A7a] dw 也 16 lane（pool 保持 8）")
rep(""": dense    ? ((oc8_r + 16'd15) >> 4)
                                     : (oc8_r >> 3);""",
    """: ((oc8_r + 16'd15) >> 4);""")

# 10) dw tile 通道偏移 8 -> 16
rep("band_base <= f_dw ? (blk_base + (c_ocb << 3)) : blk_base;",
    "band_base <= f_dw ? (blk_base + (c_ocb << 4)) : blk_base;   // v0.9 [A7a] dw 16 lane/tile")
rep("la        <= f_dw ? (blk_base + (c_ocb << 3)) : blk_base;",
    "la        <= f_dw ? (blk_base + (c_ocb << 4)) : blk_base;")

io.open(p, 'w', encoding='utf-8', newline='\n').write(s)
print('A7a patch applied: %d replacements' % n)
