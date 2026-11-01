# -*- coding: utf-8 -*-
"""从 sim/tb_nn_engine.sv 生成 v3 TB (proto/engine/tb_nn_engine_v3.sv)。"""
import io

src = io.open("../../../../sim/tb_nn_engine.sv", encoding="utf-8", errors="replace").read()
d = src


def rep(old, new):
    global d
    assert old in d, "NOT FOUND:\n" + old[:200]
    d = d.replace(old, new, 1)


# 1) 信号: w_rdata 加宽 + q 口 + b_wstrb + dbg 装载口
rep("""  logic        w_re;
  logic [23:0] w_addr;
  logic [63:0] w_rdata;
  logic [1:0]  a_sel;
  logic        a_re;
  logic [23:0] a_addr;
  logic [127:0] a_rdata;
  logic [1:0]  b_sel;
  logic        b_we;
  logic [23:0] b_addr;
  logic [63:0] b_wdata;

  nn_mem u_mem (
    .clk(clk), .rst(rst),
    .cpu_re(cpu_re), .cpu_we(cpu_we), .cpu_addr(cpu_addr),
    .cpu_wdata(cpu_wdata), .cpu_wstrb(cpu_wstrb), .cpu_rdata(cpu_rdata),
    .w_re(w_re), .w_addr(w_addr), .w_rdata(w_rdata),
    .a_sel(a_sel), .a_re(a_re), .a_addr(a_addr), .a_rdata(a_rdata),
    .b_sel(b_sel), .b_we(b_we), .b_addr(b_addr), .b_wdata(b_wdata)
  );

  nn_conv_engine u_eng (
    .clk(clk), .rst(rst), .desc(desc), .start(start),
    .busy(busy), .done(done), .cycles(cycles), .err_code(err_code),
    .w_re(w_re), .w_addr(w_addr), .w_rdata(w_rdata),
    .a_sel(a_sel), .a_re(a_re), .a_addr(a_addr), .a_rdata(a_rdata),
    .b_sel(b_sel), .b_we(b_we), .b_addr(b_addr), .b_wdata(b_wdata)
  );""",
    """  logic        w_re;
  logic [23:0] w_addr;
  logic [127:0] w_rdata;
  logic        q_re;
  logic [12:0] q_addr;
  logic [63:0] q_rdata;
  logic [1:0]  a_sel;
  logic        a_re;
  logic [23:0] a_addr;
  logic [127:0] a_rdata;
  logic [1:0]  b_sel;
  logic        b_we;
  logic [23:0] b_addr;
  logic [127:0] b_wdata;
  logic [15:0] b_wstrb;
  logic        dbg_we;
  logic        dbg_space;
  logic [16:0] dbg_addr;
  logic [31:0] dbg_wdata;

  nn_mem_v07_stub #(.A_BYTES(96*1024), .B_BYTES(32*1024)) u_mem (
    .clk(clk), .rst(rst),
    .cpu_re(cpu_re), .cpu_we(cpu_we), .cpu_addr(cpu_addr),
    .cpu_wdata(cpu_wdata), .cpu_wstrb(cpu_wstrb), .cpu_rdata(cpu_rdata),
    .w_re(w_re), .w_addr(w_addr), .w_rdata(w_rdata),
    .q_re(q_re), .q_addr(q_addr), .q_rdata(q_rdata),
    .a_sel(a_sel), .a_re(a_re), .a_addr(a_addr), .a_rdata(a_rdata),
    .b_sel(b_sel), .b_we(b_we), .b_addr(b_addr), .b_wdata(b_wdata),
    .b_wstrb(b_wstrb),
    .dbg_we(dbg_we), .dbg_space(dbg_space), .dbg_addr(dbg_addr), .dbg_wdata(dbg_wdata)
  );

  nn_conv_engine #(.OC_LANES(16), .PX_LANES(8)) u_eng (
    .clk(clk), .rst(rst), .desc(desc), .start(start),
    .busy(busy), .done(done), .cycles(cycles), .err_code(err_code),
    .w_re(w_re), .w_addr(w_addr), .w_rdata(w_rdata),
    .q_re(q_re), .q_addr(q_addr), .q_rdata(q_rdata),
    .a_sel(a_sel), .a_re(a_re), .a_addr(a_addr), .a_rdata(a_rdata),
    .b_sel(b_sel), .b_we(b_we), .b_addr(b_addr),
    .b_wdata_128(b_wdata), .b_wstrb(b_wstrb)
  );""")

# 2) load_wq -> dbg 装载 (W/Q 分开)
rep("""  task automatic load_wq(input string nm, output integer nw);
    integer fh, rc;
    logic [31:0] off, wd;
    begin
      nw = 0;
      fh = $fopen({vecdir, "/", nm, ".wq.wr"}, "r");
      if (fh == 0) begin
        $display("TB: [FAIL] cannot open %s.wq.wr", nm);
        $fatal;
      end
      rc = $fscanf(fh, "%h %h", off, wd);
      while (rc == 2) begin
        cpu_wr32(off, wd);
        nw = nw + 1;
        rc = $fscanf(fh, "%h %h", off, wd);
      end
      $fclose(fh);
    end
  endtask""",
    """  // v0.7: W/Q 走 mem 的 debug 预装口 (CPU 不可访问); 向量偏移约定:
  //   off <  NN_Q_OFF -> W 区 32-bit 字索引 = off>>2
  //   off >= NN_Q_OFF -> Q 区 32-bit 字索引 = (off-NN_Q_OFF)>>2
  task automatic dbg_wr(input logic sp, input logic [16:0] widx, input logic [31:0] wd);
    begin
      @(negedge clk);
      dbg_we    = 1'b1;
      dbg_space = sp;
      dbg_addr  = widx;
      dbg_wdata = wd;
      @(negedge clk);
      dbg_we    = 1'b0;
    end
  endtask

  task automatic load_wq(input string nm, output integer nw);
    integer fh, rc;
    logic [31:0] off, wd;
    begin
      nw = 0;
      fh = $fopen({vecdir, "/", nm, ".wq.wr"}, "r");
      if (fh == 0) begin
        $display("TB: [FAIL] cannot open %s.wq.wr", nm);
        $fatal;
      end
      rc = $fscanf(fh, "%h %h", off, wd);
      while (rc == 2) begin
        if (off >= NN_Q_OFF)
          dbg_wr(1'b1, 17'((off - NN_Q_OFF) >> 2), wd);
        else
          dbg_wr(1'b0, 17'(off >> 2), wd);
        nw = nw + 1;
        rc = $fscanf(fh, "%h %h", off, wd);
      end
      $fclose(fh);
    end
  endtask""")

# 3) flags 7 位 + qoff 转 Q 区相对偏移
rep("""      desc.flags  = flags[4:0];""", """      desc.flags  = flags[6:0];""")
rep("""      desc.qoff   = qoff[31:0];""",
    """      desc.qoff   = (qoff[31:0] >= NN_Q_OFF) ? (qoff[31:0] - NN_Q_OFF) : qoff[31:0];""")

# 4) 初始化: dbg 口默认 0
rep("""  logic [31:0] dbg_wdata;
""", "")  # (占位, 若已存在则忽略)
d = d.replace("""  logic [31:0] dbg_wdata;
""", "")

io.open("tb_nn_engine_v3.sv", "w", encoding="utf-8").write(d)
print("tb v3 written")
