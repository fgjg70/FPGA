# -*- coding: utf-8 -*-
"""W 读跨模块流水: engine 支持 W_RD_LAT=2（W 读等 2 拍再消费）:
   - 参数 W_RD_LAT（默认 1，兼容现网；=2 时给 mem 侧 w_addr/w_re 寄存留出一拍）
   - LAT2 时 MAC 流水 +1 级: a_pipe1 中间级, wby 在 mac_v2 捕获, prod mac_v3, acc mac_v4, DRN=4
   - 同时给 stub 加 W_LAT 参数（=2 时 W 读输入再寄一拍，纯测试模型）"""
import io

P = "nn_conv_engine_v3.sv"
s = io.open(P, encoding="utf-8").read()


def rep(old, new):
    global s
    assert old in s, "NOT FOUND:\n" + old[:200]
    s = s.replace(old, new, 1)


# 1) 参数
rep("""#(
  parameter int OC_LANES = 16,
  parameter int PX_LANES = 8
)(""",
    """#(
  parameter int OC_LANES = 16,
  parameter int PX_LANES = 8,
  parameter int W_RD_LAT = 1        // W 读有效时延: 1=旧行为; 2=mem 侧 w_addr/w_re 寄存一拍
)(""")

# 2) DRNN 参数化
rep("""  localparam int DRNN  = 3;""",
    """  localparam bit LAT2  = (W_RD_LAT >= 2);
  localparam int DRNN  = LAT2 ? 4 : 3;""")

# 3) 声明
rep("""  logic        mac_v1, mac_v2, mac_v3;""",
    """  logic        mac_v1, mac_v2, mac_v3, mac_v4;""")
rep("""  logic signed [7:0]  a_pipe2[0:PX-1][0:OCL-1];""",
    """  logic signed [7:0]  a_pipe1[0:PX-1][0:OCL-1];   // LAT2: 中间级 (对齐 2 拍 W 时延)
  logic signed [7:0]  a_pipe2[0:PX-1][0:OCL-1];""")

# 4) reset
rep("""      mac_v1 <= 1'b0; mac_v2 <= 1'b0; mac_v3 <= 1'b0;""",
    """      mac_v1 <= 1'b0; mac_v2 <= 1'b0; mac_v3 <= 1'b0; mac_v4 <= 1'b0;""")
rep("""          a_pipe2[px][l] <= 8'sd0; prod[px][l] <= 16'sd0; mx[px][l] <= -8'sd128;""",
    """          a_pipe1[px][l] <= 8'sd0;
          a_pipe2[px][l] <= 8'sd0; prod[px][l] <= 16'sd0; mx[px][l] <= -8'sd128;""")

# 5) MAC 流水: LAT1/LAT2 两套
old_pipe = """      mac_v1 <= mac_issue;
      mac_v2 <= mac_v1;
      mac_v3 <= mac_v2;
      if (mac_issue) begin
        for (int px = 0; px < PX; px++)
          for (int oc = 0; oc < OCL; oc++) begin
            if (dense)
              a_pipe[px][oc] <= win_sel[px][sel_byte_base +: 8];
            else
              a_pipe[px][oc] <= (oc < 8) ? win_sel[px][oc*8 +: 8] : 8'sd0;
          end
      end
      if (mac_v1) begin
        for (int oc = 0; oc < OCL; oc++)
          wby_r[oc] <= (dense || (oc < 8)) ? $signed(w_rdata[oc*8 +: 8]) : 16'sd0;
        for (int px = 0; px < PX; px++)
          for (int oc = 0; oc < OCL; oc++)
            a_pipe2[px][oc] <= a_pipe[px][oc];
      end
      if (mac_v2) begin
        for (int px = 0; px < PX; px++)
          for (int oc = 0; oc < OCL; oc++)
            prod[px][oc] <= $signed(a_pipe2[px][oc]) * wby_r[oc];
      end
      if (mac_v3) begin
        for (int px = 0; px < PX; px++)
          for (int oc = 0; oc < OCL; oc++)
            acc[px][oc] <= acc[px][oc] + {{16{prod[px][oc][15]}}, prod[px][oc]};
      end"""
new_pipe = """      mac_v1 <= mac_issue;
      mac_v2 <= mac_v1;
      mac_v3 <= mac_v2;
      mac_v4 <= mac_v3;
      if (mac_issue) begin
        for (int px = 0; px < PX; px++)
          for (int oc = 0; oc < OCL; oc++) begin
            if (dense)
              a_pipe[px][oc] <= win_sel[px][sel_byte_base +: 8];
            else
              a_pipe[px][oc] <= (oc < 8) ? win_sel[px][oc*8 +: 8] : 8'sd0;
          end
      end
      if (LAT2) begin : g_wlat2
        if (mac_v1) begin
          for (int px = 0; px < PX; px++)
            for (int oc = 0; oc < OCL; oc++)
              a_pipe1[px][oc] <= a_pipe[px][oc];
        end
        if (mac_v2) begin
          for (int oc = 0; oc < OCL; oc++)
            wby_r[oc] <= (dense || (oc < 8)) ? $signed(w_rdata[oc*8 +: 8]) : 16'sd0;
          for (int px = 0; px < PX; px++)
            for (int oc = 0; oc < OCL; oc++)
              a_pipe2[px][oc] <= a_pipe1[px][oc];
        end
        if (mac_v3) begin
          for (int px = 0; px < PX; px++)
            for (int oc = 0; oc < OCL; oc++)
              prod[px][oc] <= $signed(a_pipe2[px][oc]) * wby_r[oc];
        end
        if (mac_v4) begin
          for (int px = 0; px < PX; px++)
            for (int oc = 0; oc < OCL; oc++)
              acc[px][oc] <= acc[px][oc] + {{16{prod[px][oc][15]}}, prod[px][oc]};
        end
      end
      else begin : g_wlat1
        if (mac_v1) begin
          for (int oc = 0; oc < OCL; oc++)
            wby_r[oc] <= (dense || (oc < 8)) ? $signed(w_rdata[oc*8 +: 8]) : 16'sd0;
          for (int px = 0; px < PX; px++)
            for (int oc = 0; oc < OCL; oc++)
              a_pipe2[px][oc] <= a_pipe[px][oc];
        end
        if (mac_v2) begin
          for (int px = 0; px < PX; px++)
            for (int oc = 0; oc < OCL; oc++)
              prod[px][oc] <= $signed(a_pipe2[px][oc]) * wby_r[oc];
        end
        if (mac_v3) begin
          for (int px = 0; px < PX; px++)
            for (int oc = 0; oc < OCL; oc++)
              acc[px][oc] <= acc[px][oc] + {{16{prod[px][oc][15]}}, prod[px][oc]};
        end
      end"""
rep(old_pipe, new_pipe)

io.open(P, "w", encoding="utf-8").write(s)
print("engine W_RD_LAT support added")

# ---------------- stub: W_LAT 参数 ----------------
P2 = "nn_mem_v07_stub.sv"
t = io.open(P2, encoding="utf-8").read()
old = """  parameter int A_BYTES = 96*1024,
  parameter int B_BYTES = 32*1024
)("""
new = """  parameter int A_BYTES = 96*1024,
  parameter int B_BYTES = 32*1024,
  parameter int W_LAT   = 1        // 1=1 拍; 2=额外寄存 w_re/w_addr 一拍 (模拟 nn_mem_pipe)
)("""
assert old in t
t = t.replace(old, new, 1)

old2 = """  logic [127:0] w_rdata_r;
  always @(posedge clk) begin
    begin : w_rd
      logic [16:0] wa;
      wa = 17'(w_addr >> 2);   // 32-bit 字索引
      if (!w_re || (w_addr >= W_BYTES)) w_rdata_r <= 128'd0;
      else w_rdata_r <= {w_mem[wa + 17'd3], w_mem[wa + 17'd2],
                         w_mem[wa + 17'd1], w_mem[wa]};
    end
  end
  assign w_rdata = w_rdata_r;"""
new2 = """  logic [127:0] w_rdata_r;
  logic         w_re_d;
  logic [23:0]  w_addr_d;
  always @(posedge clk) begin
    w_re_d   <= w_re;
    w_addr_d <= w_addr;
  end
  wire        w_re_e   = (W_LAT >= 2) ? w_re_d   : w_re;
  wire [23:0] w_addr_e = (W_LAT >= 2) ? w_addr_d : w_addr;
  always @(posedge clk) begin
    begin : w_rd
      logic [16:0] wa;
      wa = 17'(w_addr_e >> 2);   // 32-bit 字索引
      if (!w_re_e || (w_addr_e >= W_BYTES)) w_rdata_r <= 128'd0;
      else w_rdata_r <= {w_mem[wa + 17'd3], w_mem[wa + 17'd2],
                         w_mem[wa + 17'd1], w_mem[wa]};
    end
  end
  assign w_rdata = w_rdata_r;"""
assert old2 in t
t = t.replace(old2, new2, 1)
io.open(P2, "w", encoding="utf-8").write(t)
print("stub W_LAT added")
