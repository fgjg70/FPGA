# -*- coding: utf-8 -*-
"""bc3 = bc2(已应用) + 低风险拆: icb_n 寄存 + band 前进步长提前一拍寄存 (不加流水段/不加周期)。
目标路径: c_icb[4] -> la_reg[23] (band 基址选择, 6.18ns)。只落盘 draft/。"""
import io

src = io.open("../../../../nn_conv_engine.sv", encoding="utf-8").read()
d = src


def rep(old, new):
    global d
    assert old in d, "NOT FOUND:\n" + old[:200]
    d = d.replace(old, new, 1)


# 1) 寄存器声明
rep("""  logic [23:0] p1_2, p1_3, p1_4;""",
    """  logic [23:0] p1_2, p1_3, p1_4;
  logic [15:0] icb_n_r;       // bc3: IC8/8 寄存 (去掉 d_ic 从 FSM/比较锥)
  logic [23:0] band_adv_r;    // bc3: 下一个 band 的基址增量 (S_LD 末拍预计算)""")

# 2) CPREP c_p=1: 寄存 ICB
rep("""              oc_limit_r <= is_pool ? (ic8_r >> 3) : (oc8_r >> 3);""",
    """              oc_limit_r <= is_pool ? (ic8_r >> 3) : (oc8_r >> 3);
              icb_n_r    <= ic8_r >> 3;""")

# 3) 所有 FSM/数据通路里的 icb_n -> icb_n_r
d = d.replace("(c_icb + 16'd1 < icb_n)", "(c_icb + 16'd1 < icb_n_r)")
d = d.replace("(c_cb + 16'd1 < icb_n)", "(c_cb + 16'd1 < icb_n_r)")

# 4) S_LD 末拍预计算 band 增量
rep("""          ld_ret_v      <= 1'b1;
          x_ld          <= x_ld + $signed({15'd0, dx_r});""",
    """          ld_ret_v      <= 1'b1;
          x_ld          <= x_ld + $signed({15'd0, dx_r});
          // bc3: 在装载最后一拍把"下一个 band 的基址增量"算好 (只 1 级比较+mux -> FF)
          if (c_ld == ld_m1_r)
            band_adv_r <= (dense && (c_icb + 16'd1 < icb_n_r))
                          ? 24'd8 : band_ky_step;""")

# 5) S_LDCAP: 只做 band_base+band_adv_r (一个加法, 两个操作数都是寄存器)
rep("""        S_LDCAP: begin
          c_m   <= 16'd0;
          if (dense && (c_icb + 16'd1 < icb_n_r)) begin
            band_base <= band_base + 24'd8;
            la        <= band_base + 24'd8;
          end
          else begin
            band_base <= band_base + band_ky_step;
            la        <= band_base + band_ky_step;
          end""",
    """        S_LDCAP: begin
          c_m   <= 16'd0;
          band_base <= band_base + band_adv_r;
          la        <= band_base + band_adv_r;""")

# 6) reset
rep("""      ld_count_r <= 16'd0; ld_m1_r <= 16'd0;""",
    """      ld_count_r <= 16'd0; ld_m1_r <= 16'd0;
      icb_n_r <= 16'd0; band_adv_r <= 24'd0;""")

io.open("draft/nn_conv_engine_v2bc3.sv", "w", encoding="utf-8").write(d)
print("bc3 draft written")
