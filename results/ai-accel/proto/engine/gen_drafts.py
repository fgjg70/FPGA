# -*- coding: utf-8 -*-
"""生成 B/C 两种时序拆法的引擎草稿 (只落盘到 proto/engine/draft/, 不动根目录 RTL)。

用法: python gen_drafts.py
输入: ../../../../nn_conv_engine.sv  (v2 冻结版, SHA256 见 engine-report §0.5)
输出: draft/nn_conv_engine_v2b.sv   (B: op/flags one-hot 寄存 + ld_count 寄存)
      draft/nn_conv_engine_v2c.sv   (C: requant 48 位归约/窄化)
"""
import hashlib
import io
import os

ROOT = "../../../../nn_conv_engine.sv"
OUT = "draft"
os.makedirs(OUT, exist_ok=True)
src = io.open(ROOT, encoding="utf-8").read()
h = hashlib.sha256(src.encode("utf-8")).hexdigest()
print("root engine sha256 =", h)

# ============================================================ B: one-hot flags
b = src


def repb(old, new):
    global b
    assert old in b, "B NOT FOUND:\n" + old[:200]
    b = b.replace(old, new, 1)


repb("""  wire is_conv = (d_op == NN_OP_CONV);
  wire is_pool = (d_op == NN_OP_POOL);
  wire is_copy = (d_op == NN_OP_COPY);
  wire is_add  = (d_op == NN_OP_ADD);
  wire f_dw    = d_flags[NN_F_DEPTHWISE];
  wire f_leaky = d_flags[NN_F_LEAKY];
  wire f_up2x  = d_flags[NN_F_UP2X];""",
     """  // ---- v2b (草稿): op/flags 在 S_IDLE 打 one-hot 寄存器, 切断 d_op/d_flags 到
  //      下游所有组合锥 (state CE / 地址 / 计数器) 的长链。
  logic is_conv, is_pool, is_copy, is_add;
  logic f_dw, f_leaky, f_up2x;""")

repb("""            d_woff  <= desc.woff;
            d_qoff  <= desc.qoff;""",
     """            d_woff  <= desc.woff;
            d_qoff  <= desc.qoff;
            is_conv <= (desc.op == NN_OP_CONV);
            is_pool <= (desc.op == NN_OP_POOL);
            is_copy <= (desc.op == NN_OP_COPY);
            is_add  <= (desc.op == NN_OP_ADD);
            f_dw    <= desc.flags[NN_F_DEPTHWISE];
            f_leaky <= desc.flags[NN_F_LEAKY];
            f_up2x  <= desc.flags[NN_F_UP2X];""")

# reset 里加 one-hot 复位
repb("""      q_iss    <= 4'd0;""",
     """      q_iss    <= 4'd0;
      is_conv <= 1'b0; is_pool <= 1'b0; is_copy <= 1'b0; is_add <= 1'b0;
      f_dw <= 1'b0; f_leaky <= 1'b0; f_up2x <= 1'b0;""")

# ld_count 打一拍 (S_LD 里只用寄存器)
repb("""  wire [15:0] ld_count = (is_conv && !f_dw && (d_ks == 4'd1))
                         ? 16'd8 : (7 * st16 + ks16);""",
     """  logic [15:0] ld_count_r, ld_m1_r;      // v2b: S_LD 用的计数上限 (寄存)""")
repb("""              dx_r        <= (dense && (d_ks == 4'd1))
                             ? (st2_r ? 16'd2 : 16'd1) : 16'd1;""",
     """              dx_r        <= (dense && (d_ks == 4'd1))
                             ? (st2_r ? 16'd2 : 16'd1) : 16'd1;
              ld_count_r  <= (dense && (d_ks == 4'd1))
                             ? 16'd8 : (7 * st16 + ks16);
              ld_m1_r     <= ((dense && (d_ks == 4'd1))
                              ? 16'd8 : (7 * st16 + ks16)) - 16'd1;""")
b = b.replace("? ld_inb_at(c_ky, c_ld + 16'd1) : 1'b0;", "? 1'b0 : 1'b0;")  # 无 a_re_r 版本时不存在, 忽略
b = b.replace("(c_ld + 16'd1 < ld_count)", "(c_ld + 16'd1 < ld_count_r)")
b = b.replace("if (c_ld == (ld_count - 16'd1)) begin", "if (c_ld == ld_m1_r) begin")
# reset
repb("""      ic8_r <= 16'd0; oc8_r <= 16'd0; oc_limit_r <= 16'd0;""",
     """      ic8_r <= 16'd0; oc8_r <= 16'd0; oc_limit_r <= 16'd0;
      ld_count_r <= 16'd0; ld_m1_r <= 16'd0;""")
io.open(os.path.join(OUT, "nn_conv_engine_v2b.sv"), "w", encoding="utf-8").write(b)
print("B draft written")

# ============================================================ C: 48-bit requant
c = src


def repc(old, new):
    global c
    assert old in c, "C NOT FOUND:\n" + old[:200]
    c = c.replace(old, new, 1)


repc("""  logic signed [63:0] y64_q   [0:OCL-1];      // 右移后 (第 3 级)
  logic signed [63:0] y2_q    [0:OCL-1];      // +zp 后 (第 4 级)""",
     """  // v2c (草稿): |acc*M| < 2^46 (acc int32 x M int16), 右移只减不增, 所以 48 位足够;
  // 用 48 位代替 64 位, 归约/比较/寄存器都变窄。
  logic signed [47:0] y64_q   [0:OCL-1];      // 右移后 (第 3 级)
  logic signed [47:0] y2_q    [0:OCL-1];      // +zp 后 (第 4 级)""")

repc("""  logic [63:0] rq_pack;
  always_comb begin
    logic signed [63:0] y2;
    logic [7:0] bb;
    logic fits;
    rq_pack = 64'd0;
    for (int l = 0; l < OCL; l++) begin
      y2   = y2_q[l];
      fits = (&y2[63:7]) || (~|y2[63:7]);        // -128 <= y2 <= 127
      if (fits) bb = y2[7:0];
      else      bb = y2[63] ? 8'h80 : 8'h7F;""",
     """  logic [63:0] rq_pack;
  always_comb begin
    logic signed [47:0] y2;
    logic [7:0] bb;
    logic fits;
    rq_pack = 64'd0;
    for (int l = 0; l < OCL; l++) begin
      y2   = y2_q[l];
      // |y2| < 2^47  =>  bits[63:47] 是 sign extension, 只判 [47:7] 全相等即可
      fits = (&y2[47:7]) || (~|y2[47:7]);
      if (fits) bb = y2[7:0];
      else      bb = y2[47] ? 8'h80 : 8'h7F;""")

repc("""        if ((c_p >= 16'd3) && (c_p <= 16'd10)) begin
          for (int l = 0; l < OCL; l++)
            y2_q[l] <= y64_q[l] + {{56{zp_out[7]}}, zp_out};
        end""",
     """        if ((c_p >= 16'd3) && (c_p <= 16'd10)) begin
          for (int l = 0; l < OCL; l++)
            y2_q[l] <= y64_q[l] + {{40{zp_out[7]}}, zp_out};
        end""")

repc("""      for (int l = 0; l < OCL; l++) begin y64_q[l] <= 64'sd0; y2_q[l] <= 64'sd0; end""",
     """      for (int l = 0; l < OCL; l++) begin y64_q[l] <= 48'sd0; y2_q[l] <= 48'sd0; end""")

io.open(os.path.join(OUT, "nn_conv_engine_v2c.sv"), "w", encoding="utf-8").write(c)
print("C draft written")
