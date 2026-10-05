`timescale 1ns/1ps

// ============================================================================
// tb_core.sv — 五级流水线系统级自校验测试平台
// ----------------------------------------------------------------------------
// 机制:
//   - 用 IMEM_INIT 参数把汇编器产出的 hex 装入指令存储器 (相对路径基于
//     运行目录, run_core.bat 会先 cd 到 sim/);
//   - 监视 DMEM 的 tohost 地址 (DMEM_BASE + 0x1000):
//       写 1       -> 全部测试通过, 结束仿真 PASS
//       写 N+1     -> 测试 N 失败, 结束仿真 FAIL
//       0 (初值)   -> 尚未写入, 继续运行
//   - 监视 core 的 dbg_illegal 粘滞标志: 任何非法指令都判失败;
//   - 超时保护: 超过 MAX_CYCLES 未结束则报超时失败 (附当前 PC/指令)。
// 运行: sim\run_core.bat   (先跑 tools/asm.py 生成 hex)
// ============================================================================

module tb_core;
  import rv32_pkg::*;

  localparam time TCLK_HALF  = 5ns;      // 100 MHz 等效
  localparam int  MAX_CYCLES = 20000;

  // tohost 约定地址 = DMEM_BASE + 0x2000 (见 sw/link.ld)
  localparam logic [31:0] TOHOST_ADDR     = DMEM_BASE + 32'h2000;
  localparam int unsigned TOHOST_WORD_IDX = (TOHOST_ADDR - DMEM_BASE) / 4;

  logic clk = 1'b0;
  logic rst = 1'b1;
  always #(TCLK_HALF) clk = ~clk;

  int unsigned cycles   = 0;
  bit          finished = 1'b0;

  logic [31:0] dbg_pc, dbg_instr, dbg_rdata;
  logic        dbg_illegal;

  logic [31:0] dbg_id_pc;
  logic [31:0] dbg_mem_addr, dbg_mem_wdata, ext_rdata;
  logic        dbg_mem_we, ext_we, ext_re;
  logic [31:0] ext_addr, ext_wdata;
  logic [3:0]  ext_wstrb;

  core u_dut (
    .clk            (clk),
    .rst            (rst),
    .dbg_pc         (dbg_pc),
    .dbg_id_pc      (dbg_id_pc),
    .dbg_instr      (dbg_instr),
    .dbg_illegal    (dbg_illegal),
    .dbg_raddr      (5'd0),
    .dbg_rdata      (dbg_rdata),
    .dbg_mem_we     (dbg_mem_we),
    .dbg_mem_addr   (dbg_mem_addr),
    .dbg_mem_wdata  (dbg_mem_wdata),
    // 本测试平台不接外设: MMIO 读恒 0 (程序也不访问 MMIO 区)
    .ext_we         (ext_we),
    .ext_re         (ext_re),
    .ext_addr       (ext_addr),
    .ext_wdata      (ext_wdata),
    .ext_wstrb      (ext_wstrb),
    .ext_rdata      (ext_rdata)
  );

  assign ext_rdata = 32'h0;

  // tohost 观察 (直接看 DMEM 内的字; 程序不做其它解释)
  wire [31:0] tohost_word = u_dut.u_dmem.mem[TOHOST_WORD_IDX];

  initial begin
    begin
      string dump_file;
      // +dump=wave.vcd 可转储波形 (用 GTKWave 查看), 不加则不产生文件
      if ($value$plusargs("dump=%s", dump_file)) begin
        $dumpfile(dump_file);
        $dumpvars(0, tb_core);
      end
    end

    repeat (4) @(posedge clk);
    rst = 1'b0;
    $display("[tb_core] 复位释放, PC=0x%08x", PC_RESET);
  end

  always_ff @(posedge clk) begin
    if (!rst && !finished) begin
      cycles <= cycles + 1;

      if (cycles > MAX_CYCLES) begin
        finished = 1'b1;
        $display("[tb_core] FAIL: 超时 (%0d 周期), 最后 PC=0x%08x instr=0x%08x",
                 MAX_CYCLES, dbg_pc, dbg_instr);
        $fatal(1);
      end

      if (dbg_illegal) begin
        finished = 1'b1;
        $display("[tb_core] FAIL: 遇到非法指令 (PC=0x%08x instr=0x%08x)",
                 dbg_pc, dbg_instr);
        $fatal(1);
      end

      if (tohost_word == 32'd1) begin
        finished = 1'b1;
        $display("=================================================");
        $display("  全部 6 组测试通过 (算术/冒险/访存/非对齐/分支/移位)");
        $display("  执行周期: %0d", cycles);
        $display("  RESULT : PASS");
        $finish;
      end
      else if (tohost_word != 32'd0) begin
        finished = 1'b1;
        $display("[tb_core] FAIL: 测试 %0d 失败 (tohost=%0d)",
                 tohost_word - 1, tohost_word);
        $display("[tb_core] 退出时 PC=0x%08x, 周期数 %0d", dbg_pc, cycles);
        $fatal(1);
      end
    end
  end

endmodule
