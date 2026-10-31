`timescale 1ns/1ps

// ============================================================================
// tb_nn_mem.sv — nn_mem (v0.3: WQ 368KB + A/B 各 64KB) 自检 testbench
// ----------------------------------------------------------------------------
// 判据 (机器可判定, 不接受"波形看起来对"):
//   MEM_TB: PASS/FAIL + mismatch 计数 + X 传播计数 (所有比较用 !==, X 必报)
//   有 `+nnwq=<file>` 时做 WQ 全量镜像扫描; 没有时打印 SKIP 并跳过镜像相关检查
//   (集成框架在 yolo_wq.hex 尚未生成时也能单独跑本 TB)。
//
// 覆盖:
//   ① WQ 阵列的 $readmemh 镜像: 全量 64 位 NPU 读扫描 (47104 拍 = 94208 个
//      32 位字), 加 FNV-1a 校验和独立比对; CPU 32 位读抽查 (含 Q 区)
//   ② Q 区 CPU 32 位整字写 + 字节写 (wstrb 组合) 读回
//   ③ 激活 A/B: NPU 64 位写 / 128 位读、两缓冲不串扰、CPU 32 位读、CPU 字节写,
//      以及同一拍 NPU 读 B + CPU 读 A 的并行一致性
//   ④ CPU 窗口: 空洞 0x5C000..0x5FFFF 读 0、越界(>=512KB)读 0、写忽略
//   ⑤ 复位: 复位期间/之后控制状态 (无 X); 复位不清存储器内容
//   ⑥ w 口越界/落在 A/B 区 -> 返回 64'b0 (不是 X); a 口非法 sel/越界 -> 128'b0
//
// 运行 (ModelSim, 见 results/ai-accel/mem-report.md):
//   vlib work
//   vlog -sv rv32_pkg.sv nn_pkg.sv nn_mem.sv sim/tb_nn_mem.sv
//   vsim -c -do "run -all; quit -f" work.tb_nn_mem +nnwq=<abs path>/yolo_wq.hex
//   参数默认 = CONTRACT v0.3 交付配置; 也可 vsim -gA_BYTES=... 覆盖(需重生成镜像)
// ============================================================================

module tb_nn_mem #(
  parameter int W_BYTES = 320*1024,
  parameter int Q_BYTES = 48*1024,
  parameter int A_BYTES = 96*1024,
  parameter int B_BYTES = 32*1024,
  parameter int CPU_AW  = 19
);

  // ---- 与 nn_mem 内部一致的布局常量 ----
  localparam int WQ_BYTES  = W_BYTES + Q_BYTES;
  localparam int WQ_WORDS  = WQ_BYTES / 4;
  localparam int WQ_AW     = $clog2(WQ_WORDS);
  localparam int ACT_BYTES = A_BYTES + B_BYTES;
  localparam int ACT_WORDS = ACT_BYTES / 16;
  localparam int ACT_AW    = $clog2(ACT_WORDS);

  localparam logic [31:0] A_OFF = 32'h0006_0000;
  localparam logic [31:0] B_OFF = A_OFF + A_BYTES;
  localparam logic [31:0] WIN   = 32'h1 << CPU_AW;

  localparam logic [23:0] A_ADDR = A_OFF[23:0];
  localparam logic [23:0] B_ADDR = B_OFF[23:0];

  // ---- DUT 端口 ----
  logic         clk;
  logic         rst;
  logic         cpu_re, cpu_we;
  logic [31:0]  cpu_addr, cpu_wdata;
  logic [3:0]   cpu_wstrb;
  logic [31:0]  cpu_rdata;
  logic         w_re;
  logic [23:0]  w_addr;
  logic [63:0]  w_rdata;
  logic [1:0]   a_sel;
  logic         a_re;
  logic [23:0]  a_addr;
  logic [127:0] a_rdata;
  logic [1:0]   b_sel;
  logic         b_we;
  logic [23:0]  b_addr;
  logic [63:0]  b_wdata;

  // ---- 计分板 ----
  int n_checks;
  int n_mismatch;
  int n_xerr;
  int n_wq_sweep;
  int n_act;
  int n_cpu;

  // ---- 期望值模型 (与 results/ai-accel/proto/mem/gen_wq_image.py 完全一致) ----
  // WQ 32 位字 i: (i * 0x9E3779B9) ^ 0xC0DE0000
  function automatic logic [31:0] wq_exp(input logic [31:0] i);
    wq_exp = (i * 32'h9E37_79B9) ^ 32'hC0DE_0000;
  endfunction

  // 激活 64 位写样图 (j = 64 位字序号)
  function automatic logic [63:0] pat64(input logic [31:0] j);
    pat64 = {(j ^ 32'hA5A5_A5A5), ((j * 32'h9E37_79B9) ^ 32'h5A5A_5A5A)};
  endfunction

  // FNV-1a 32 位单字节推进 (WQ 全量扫描用)
  function automatic logic [31:0] fnv1a_byte(input logic [31:0] h,
                                             input logic [7:0]  b);
    fnv1a_byte = (h ^ 32'(b)) * 32'd16777619;
  endfunction

  // ---- 时钟 ----
  initial clk = 1'b0;
  always #5 clk = ~clk;

  // ---- 计分板检查 (X 必须显式报错) ----
  task automatic chk32(input logic [31:0] actual, input logic [31:0] expected,
                       input string msg);
    n_checks++;
    if (^actual === 1'bx) begin
      n_xerr++;
      if (n_xerr <= 10) $display("[MEM_TB] X-ERR  %s : actual=%b", msg, actual);
    end else if (actual !== expected) begin
      n_mismatch++;
      if (n_mismatch <= 20)
        $display("[MEM_TB] MISMATCH %s : actual=0x%08x expected=0x%08x",
                 msg, actual, expected);
    end
  endtask

  task automatic chk64(input logic [63:0] actual, input logic [63:0] expected,
                       input string msg);
    n_checks++;
    if ((^actual) === 1'bx) begin
      n_xerr++;
      if (n_xerr <= 10) $display("[MEM_TB] X-ERR  %s : actual=%b", msg, actual);
    end else if (actual !== expected) begin
      n_mismatch++;
      if (n_mismatch <= 20)
        $display("[MEM_TB] MISMATCH %s : actual=0x%016x expected=0x%016x",
                 msg, actual, expected);
    end
  endtask

  task automatic chk128(input logic [127:0] actual, input logic [127:0] expected,
                        input string msg);
    n_checks++;
    if ((^actual) === 1'bx) begin
      n_xerr++;
      if (n_xerr <= 10) $display("[MEM_TB] X-ERR  %s : actual=%b", msg, actual);
    end else if (actual !== expected) begin
      n_mismatch++;
      if (n_mismatch <= 20)
        $display("[MEM_TB] MISMATCH %s : actual=0x%032x expected=0x%032x",
                 msg, actual, expected);
    end
  endtask

  // ---- 总线驱动任务 (negedge 驱动, 下一个 negedge 采样 = dmem 的 1 拍口径) ----
  task automatic idle_all;
    cpu_re = 1'b0; cpu_we = 1'b0; cpu_addr = 32'h0; cpu_wdata = 32'h0;
    cpu_wstrb = 4'h0;
    w_re = 1'b0; w_addr = 24'h0;
    a_re = 1'b0; a_sel = 2'd0; a_addr = 24'h0;
    b_we = 1'b0; b_sel = 2'd0; b_addr = 24'h0; b_wdata = 64'h0;
  endtask

  task automatic cpu_write(input logic [31:0] addr, input logic [31:0] data,
                           input logic [3:0] strb);
    @(negedge clk);
    cpu_we    = 1'b1;
    cpu_re    = 1'b0;
    cpu_addr  = addr;
    cpu_wdata = data;
    cpu_wstrb = strb;
    @(negedge clk);
    cpu_we    = 1'b0;
    cpu_wstrb = 4'h0;
  endtask

  task automatic cpu_read(input logic [31:0] addr, output logic [31:0] data);
    @(negedge clk);
    cpu_re    = 1'b1;
    cpu_we    = 1'b0;
    cpu_addr  = addr;
    cpu_wstrb = 4'h0;
    @(negedge clk);
    data = cpu_rdata;
    cpu_re = 1'b0;
  endtask

  task automatic npu_wread(input logic [23:0] addr, output logic [63:0] data);
    @(negedge clk);
    w_re   = 1'b1;
    w_addr = addr;
    @(negedge clk);
    data = w_rdata;
    w_re = 1'b0;
  endtask

  task automatic npu_awrite(input logic [23:0] addr, input logic [63:0] data,
                            input logic [1:0] sel);
    @(negedge clk);
    b_we    = 1'b1;
    b_sel   = sel;
    b_addr  = addr;
    b_wdata = data;
    @(negedge clk);
    b_we = 1'b0;
  endtask

  task automatic npu_aread(input logic [23:0] addr, input logic [1:0] sel,
                           output logic [127:0] data);
    @(negedge clk);
    a_re   = 1'b1;
    a_sel  = sel;
    a_addr = addr;
    @(negedge clk);
    data = a_rdata;
    a_re = 1'b0;
  endtask

  // 说明 (v0.3.2): A/B 合并在同一块 128 位宽物理阵列里, 读口由 NPU/CPU 共享,
  // 因此**不存在**"同拍 NPU 读 + CPU 读"的并行用法 (契约本来就规定 NPU busy
  // 期间 CPU 不许访问窗口)。这里改为顺序验证 NPU 读 A/B 与 CPU 读 A/B 都正确。
  task automatic npu_and_cpu_aread(input logic [23:0] naddr, input logic [1:0] nsel,
                                   input logic [31:0] caddr,
                                   output logic [127:0] ndata,
                                   output logic [31:0]  cdata);
    @(negedge clk);
    a_re    = 1'b1;
    a_sel   = nsel;
    a_addr  = naddr;
    @(negedge clk);
    ndata = a_rdata;
    a_re  = 1'b0;
    @(negedge clk);
    cpu_re    = 1'b1;
    cpu_we    = 1'b0;
    cpu_addr  = caddr;
    cpu_wstrb = 4'h0;
    @(negedge clk);
    cdata = cpu_rdata;
    cpu_re = 1'b0;
  endtask

  // ==========================================================================
  // 主测试序列
  // ==========================================================================
  logic [31:0]  rd32;
  logic [63:0]  rd64;
  logic [127:0] rd128;
  logic [31:0]  fnv_read, fnv_exp;
  logic         has_wq_img;

  initial begin : main
    n_checks   = 0;
    n_mismatch = 0;
    n_xerr     = 0;
    n_wq_sweep = 0;
    n_act      = 0;
    n_cpu      = 0;
    has_wq_img = $test$plusargs("nnwq");
    fnv_read   = 32'h811c_9dc5;
    fnv_exp    = 32'h811c_9dc5;

    idle_all();
    rst = 1'b1;

    // ---------- ⑤ 复位期间/之后: 输出必须无 X ----------
    repeat (3) @(negedge clk);
    chk32(cpu_rdata, 32'h0, "reset: cpu_rdata");
    chk64(w_rdata, 64'h0, "reset: w_rdata");
    chk128(a_rdata, 128'h0, "reset: a_rdata");

    @(negedge clk);
    rst = 1'b0;
    repeat (2) @(negedge clk);
    // 注意: cpu_addr 仍为 0 (idle_all), 译码到 WQ 字 0 —— 与 dmem 同口径
    // (地址每拍都在采样, 没有"复位后读数据必须为 0"的语义); 有镜像时查镜像值,
    // 没镜像时 WQ 初值为 0
    chk32(cpu_rdata, has_wq_img ? wq_exp(32'd0) : 32'h0,
          "post-reset: cpu_rdata = WQ[0] (addr=0)");
    chk64(w_rdata, 64'h0, "post-reset: w_rdata");
    chk128(a_rdata, 128'h0, "post-reset: a_rdata");

    // ---------- ① WQ 镜像: NPU 全量 64 位读扫描 (需 +nnwq) ----------
    if (has_wq_img) begin : wq_sweep
      $display("[MEM_TB] WQ sweep start: WQ_BYTES=%0d (%0d x 32-bit words, %0d x 64-bit reads)",
               WQ_BYTES, WQ_WORDS, WQ_WORDS/2);
      for (int p = 0; p < WQ_WORDS/2; p++) begin
        logic [63:0] expw;
        npu_wread(24'(p*8), rd64);
        expw = {wq_exp(32'(2*p+1)), wq_exp(32'(2*p))};
        n_wq_sweep++;
        n_checks++;
        if ((^rd64) === 1'bx) begin
          n_xerr++;
          if (n_xerr <= 10) $display("[MEM_TB] X-ERR  WQ[%0d] : actual=%b", p, rd64);
        end else if (rd64 !== expw) begin
          n_mismatch++;
          if (n_mismatch <= 20)
            $display("[MEM_TB] MISMATCH WQ[%0d] : actual=0x%016x expected=0x%016x",
                     p, rd64, expw);
        end
        for (int bi = 0; bi < 8; bi++) begin
          fnv_read = fnv1a_byte(fnv_read, rd64[8*bi +: 8]);
          fnv_exp  = fnv1a_byte(fnv_exp,  expw[8*bi +: 8]);
        end
      end
      $display("[MEM_TB] WQ sweep done: %0d reads, fnv_read=0x%08x fnv_exp=0x%08x",
               n_wq_sweep, fnv_read, fnv_exp);
      chk32(fnv_read, fnv_exp, "WQ full-sweep FNV checksum");
    end else begin
      $display("[MEM_TB] SKIP WQ image sweep (+nnwq not given); WQ-dependent checks skipped");
    end

    // ---------- ①/② CPU 32 位读 WQ (W 区与 Q 区抽查, 需镜像) ----------
    if (has_wq_img) begin : cpu_wq_reads
      logic [31:0] addrs [0:7];
      addrs[0] = 32'h0000_0000;   // W 头
      addrs[1] = 32'h0000_0004;   // W 第二字
      addrs[2] = 32'h0000_0100;   // W 中
      addrs[3] = 32'h0004_FFF8;   // W 尾
      addrs[4] = 32'h0005_0000;   // Q 头
      addrs[5] = 32'h0005_0004;   // Q 第二字
      addrs[6] = 32'h0005_BFFC;   // Q 尾 (48KB 区最后一字)
      addrs[7] = 32'h0002_3458;   // 任意
      for (int i = 0; i < 8; i++) begin
        cpu_read(addrs[i], rd32);
        chk32(rd32, wq_exp(addrs[i] >> 2), $sformatf("CPU WQ read @0x%08x", addrs[i]));
        n_cpu++;
      end
    end

    // ---------- WQ 区 CPU 32 位写 + 读回 (不依赖镜像) ----------
    cpu_write(32'h0000_0200, 32'hCAFE_F00D, 4'hF);
    cpu_read (32'h0000_0200, rd32);
    chk32(rd32, 32'hCAFE_F00D, "CPU WQ word write/read");
    n_cpu++;

    // ---------- ② Q 区 CPU 32 位整字写 + 读回 ----------
    cpu_write(32'h0005_0100, 32'h1234_5678, 4'hF);
    cpu_read (32'h0005_0100, rd32);
    chk32(rd32, 32'h1234_5678, "CPU Q word write/read");
    n_cpu++;

    // ---------- ② Q 区 CPU 字节写 (wstrb 组合; 先清整字再叠字节, 不依赖镜像) ----------
    begin : q_byte_write
      logic [31:0] qaddr, expv;
      qaddr = 32'h0005_0140;
      cpu_write(qaddr, 32'h0, 4'hF);
      // strb=0101 写 0x11223344 只落 byte0=0x44 / byte2=0x22
      expv = 32'h0022_0044;
      cpu_write(qaddr, 32'h1122_3344, 4'b0101);
      cpu_read (qaddr, rd32);
      chk32(rd32, expv, "CPU Q byte write strb=0101");
      n_cpu++;
      // 叠加 strb=1001 写 0x99887766 -> byte0=0x66, byte3=0x99
      expv = 32'h9922_0066;
      cpu_write(qaddr, 32'h9988_7766, 4'b1001);
      cpu_read (qaddr, rd32);
      chk32(rd32, expv, "CPU Q byte write strb=1001 (accumulate)");
      n_cpu++;
    end

    // ---------- W 区 CPU 字节写 (不依赖镜像) ----------
    begin : w_byte_write
      logic [31:0] waddr, expv;
      waddr = 32'h0000_0100;
      cpu_write(waddr, 32'h1122_3344, 4'hF);
      // strb=0010 写 0xAABBCCDD 只落 byte1=0xCC -> 0x1122_CC44
      expv = 32'h1122_CC44;
      cpu_write(waddr, 32'hAABB_CCDD, 4'b0010);
      cpu_read (waddr, rd32);
      chk32(rd32, expv, "CPU W byte write strb=0010");
      n_cpu++;
    end

    // ---------- ① w 口: 64 位读 (低地址字在低 32 位), 不依赖镜像 ----------
    cpu_write(32'h0005_0200, 32'hAABB_CCDD, 4'hF);
    cpu_write(32'h0005_0204, 32'h1122_3344, 4'hF);
    npu_wread(24'h0005_0200, rd64);
    chk64(rd64, {32'h1122_3344, 32'hAABB_CCDD},
          "w port 64b read {hi,lo} (low addr word in [31:0])");
    if (has_wq_img) begin : wq_q_img_reads
      npu_wread(24'h0005_0000, rd64);
      chk64(rd64, {wq_exp((32'h5_0000 >> 2) + 1), wq_exp(32'h5_0000 >> 2)},
            "w port Q-region 64b read (image)");
      npu_wread(24'h0005_BFF8, rd64);
      chk64(rd64, {wq_exp((32'h5_BFF8 >> 2) + 1), wq_exp(32'h5_BFF8 >> 2)},
            "w port Q-region tail 64b read (image)");
    end

    // ---------- ⑥ w 口越界/空洞/A/B 区 -> 64'b0 ----------
    begin : w_invalid
      logic [23:0] addrs [0:4];
      addrs[0] = 24'h0005_C000;   // 空洞头
      addrs[1] = 24'h0005_FFF8;   // 空洞尾
      addrs[2] = 24'h0006_0000;   // A 区头
      addrs[3] = 24'h0007_FFF8;   // B 区尾
      addrs[4] = 24'h00FF_FFF8;   // 远超窗口
      for (int i = 0; i < 5; i++) begin
        npu_wread(addrs[i], rd64);
        chk64(rd64, 64'h0, $sformatf("w port unmapped @0x%06x -> 0", addrs[i]));
      end
    end

    // ---------- ③ 激活 A/B: NPU 64 位写 / 128 位读 / 不串扰 ----------
    npu_awrite(A_ADDR + 24'h0, pat64(32'd0), 2'd0);
    npu_awrite(A_ADDR + 24'h8, pat64(32'd1), 2'd0);
    npu_awrite(B_ADDR + 24'h0, pat64(32'd100), 2'd1);
    npu_awrite(B_ADDR + 24'h8, pat64(32'd101), 2'd1);

    npu_aread(A_ADDR + 24'h0, 2'd0, rd128);
    chk128(rd128, {pat64(32'd1), pat64(32'd0)},
           "A 128b read @0 (low addr word in [63:0])");
    n_act++;

    npu_aread(B_ADDR + 24'h0, 2'd1, rd128);
    chk128(rd128, {pat64(32'd101), pat64(32'd100)},
           "B 128b read @0 (not cross-talked by A)");
    n_act++;

    npu_aread(A_ADDR + 24'h0, 2'd0, rd128);
    chk128(rd128, {pat64(32'd1), pat64(32'd0)},
           "A re-read after B write (no crosstalk)");
    n_act++;

    // 高半字写: A+0x10 写低半字, A+0x18 写高半字
    npu_awrite(A_ADDR + 24'h10, pat64(32'd2), 2'd0);
    npu_awrite(A_ADDR + 24'h18, pat64(32'd3), 2'd0);
    npu_aread(A_ADDR + 24'h10, 2'd0, rd128);
    chk128(rd128, {pat64(32'd3), pat64(32'd2)}, "A 128b read @0x10 (two half writes)");
    n_act++;

    // 只写 B+0x10 低半字, 高半字保持仿真初值 0
    npu_awrite(B_ADDR + 24'h10, pat64(32'd202), 2'd1);
    npu_aread(B_ADDR + 24'h10, 2'd1, rd128);
    chk128(rd128, {64'h0, pat64(32'd202)}, "B 128b read @0x10 (high half stays zero)");
    n_act++;

    // ---------- ⑥ a 口非法 sel / 越界 -> 128'b0 ----------
    npu_aread(B_ADDR + 24'h20, 2'd0, rd128);
    chk128(rd128, 128'h0, "a port sel=0 with B addr -> 0");
    npu_aread(A_ADDR + 24'h20, 2'd1, rd128);
    chk128(rd128, 128'h0, "a port sel=1 with A addr -> 0");
    npu_aread(24'h0000_0000, 2'd0, rd128);
    chk128(rd128, 128'h0, "a port WQ addr -> 0");
    npu_aread(24'h0005_C000, 2'd0, rd128);
    chk128(rd128, 128'h0, "a port hole addr -> 0");

    // ---------- ③ CPU 读激活区 (32 位 lane 选择) ----------
    cpu_write(A_ADDR + 32'h20, 32'h0, 4'hF);
    cpu_write(A_ADDR + 32'h24, 32'h0, 4'hF);
    cpu_write(A_ADDR + 32'h28, 32'h0, 4'hF);
    cpu_write(A_ADDR + 32'h2C, 32'h0, 4'hF);
    cpu_write(A_ADDR + 32'h20, 32'hAABB_CCDD, 4'b0101);   // lane0: 00BB00DD
    cpu_read (A_ADDR + 32'h20, rd32);
    chk32(rd32, 32'h00BB_00DD, "CPU A lane0 byte write strb=0101");
    n_cpu++;
    cpu_write(A_ADDR + 32'h24, 32'hDEAD_BEEF, 4'hF);      // lane1
    cpu_read (A_ADDR + 32'h24, rd32);
    chk32(rd32, 32'hDEAD_BEEF, "CPU A lane1 word write/read");
    n_cpu++;
    npu_aread(A_ADDR + 24'h20, 2'd0, rd128);
    chk128(rd128, {64'h0, 32'hDEAD_BEEF, 32'h00BB_00DD},
           "NPU 128b read sees CPU byte-written A bytes");
    n_act++;

    // ---------- ③ CPU 写 B 区 + 读回 ----------
    cpu_write(B_ADDR + 32'h40, 32'h1122_3344, 4'hF);
    cpu_read (B_ADDR + 32'h40, rd32);
    chk32(rd32, 32'h1122_3344, "CPU B word write/read");
    n_cpu++;

    // ---------- ③ 顺序: NPU 读 B, 随后 CPU 读 A (A/B 共用一块物理阵列, 读口共享) ----------
    begin : ab_seq
      logic [127:0] nd;
      logic [31:0]  cd;
      npu_and_cpu_aread(B_ADDR + 24'h0, 2'd1, A_ADDR + 32'h24, nd, cd);
      chk128(nd, {pat64(32'd101), pat64(32'd100)}, "seq: NPU read B");
      chk32 (cd, 32'hDEAD_BEEF, "seq: CPU read A");
    end

    // ---------- ④ CPU 窗口空洞/越界: 读 0, 写忽略 ----------
    cpu_read(32'h0005_C000, rd32);
    chk32(rd32, 32'h0, "CPU read hole 0x5C000 -> 0");
    n_cpu++;
    cpu_read(32'h0005_FFF0, rd32);
    chk32(rd32, 32'h0, "CPU read hole 0x5FFF0 -> 0");
    n_cpu++;
    cpu_write(32'h0005_C000, 32'hFFFF_FFFF, 4'hF);
    cpu_read (32'h0005_C000, rd32);
    chk32(rd32, 32'h0, "CPU write hole ignored");
    n_cpu++;
    cpu_read(WIN, rd32);
    chk32(rd32, 32'h0, "CPU read addr==512KB -> 0");
    n_cpu++;
    cpu_read(32'hFFFF_FFF0, rd32);
    chk32(rd32, 32'h0, "CPU read far out-of-range -> 0");
    n_cpu++;
    cpu_write(WIN + 32'h100, 32'hDEAD_BEEF, 4'hF);
    cpu_read (WIN + 32'h100, rd32);
    chk32(rd32, 32'h0, "CPU write out-of-window ignored");
    n_cpu++;

    // ---------- ⑤ 中途复位: 控制输出归 0, 但存储内容不清 ----------
    @(negedge clk);
    rst = 1'b1;
    repeat (2) @(negedge clk);
    chk32(cpu_rdata, 32'h0, "mid-reset: cpu_rdata=0");
    chk64(w_rdata, 64'h0, "mid-reset: w_rdata=0");
    chk128(a_rdata, 128'h0, "mid-reset: a_rdata=0");
    @(negedge clk);
    rst = 1'b0;
    cpu_read(32'h0005_0100, rd32);
    chk32(rd32, 32'h1234_5678, "after reset: Q content retained");
    n_cpu++;

    // ---------- 收尾判据 (PASS/FAIL 两行必打其中一行) ----------
    $display("[MEM_TB] SUMMARY checks=%0d wq_reads=%0d act_checks=%0d cpu_checks=%0d",
             n_checks, n_wq_sweep, n_act, n_cpu);
    if (n_mismatch == 0 && n_xerr == 0)
      $display("MEM_TB: PASS (checks=%0d, mismatch=0, xerr=0)", n_checks);
    else
      $display("MEM_TB: FAIL (checks=%0d, mismatch=%0d, xerr=%0d)",
               n_checks, n_mismatch, n_xerr);
    $finish;
  end

  // ---- 看门狗: 卡死也必须有明确结论 ----
  initial begin : watchdog
    repeat (600000) @(posedge clk);
    $display("MEM_TB: FAIL (watchdog timeout after 600000 cycles)");
    $fatal(1);
  end

  // ==========================================================================
  // DUT
  // ==========================================================================
  nn_mem #(
    .W_BYTES (W_BYTES),
    .Q_BYTES (Q_BYTES),
    .A_BYTES (A_BYTES),
    .B_BYTES (B_BYTES),
    .CPU_AW  (CPU_AW)
  ) u_dut (
    .clk      (clk),
    .rst      (rst),
    .cpu_re   (cpu_re),
    .cpu_we   (cpu_we),
    .cpu_addr (cpu_addr),
    .cpu_wdata(cpu_wdata),
    .cpu_wstrb(cpu_wstrb),
    .cpu_rdata(cpu_rdata),
    .w_re     (w_re),
    .w_addr   (w_addr),
    .w_rdata  (w_rdata),
    .a_sel    (a_sel),
    .a_re     (a_re),
    .a_addr   (a_addr),
    .a_rdata  (a_rdata),
    .b_sel    (b_sel),
    .b_we     (b_we),
    .b_addr   (b_addr),
    .b_wdata  (b_wdata)
  );

endmodule
