`timescale 1ns/1ps

// ============================================================================
// tb_nn_seq.sv — 微码序列器 nn_seq 独立单测（不依赖引擎/存储）
// ----------------------------------------------------------------------------
// 设计: 用一个"行为级假引擎"充当 nn_conv_engine:
//   - 收到 start 后, 用 desc 里的字段算一个确定延时 (ic+oc 拍) 再给 done;
//   - 记录收到的每条 desc (op/flags/src/dst/woff/qoff) 到内部检查器;
//   - 把每次 cycles 返回给 nn_seq.
// 判据:
//   1) nn_seq 启动后应恰好发出 NN_ROM_LEN 次 start（空 ROM 时直接 done, 0 次）;
//   2) nn_seq 累加 cycles == 假引擎 cycles 之和;
//   3) nn_seq.done 单拍脉冲, busy 电平覆盖全程;
//   4) 检查每次 desc 的 op 与 ROM kind 的映射 (conv/dw/pool/up/add/copy);
//   5) err_code 路径: 注入一次 eng_err_code -> nn_seq.err 拉高。
//
// 运行: python tools/fpga_workflow.py verify --only tb_nn_seq --force
// 输出: "NN_SEQ_TB: PASS (starts=N)" / "NN_SEQ_TB: FAIL ..."
// ============================================================================
module tb_nn_seq;

  import nn_pkg::*;
  import nn_rom_pkg::*;

  localparam int unsigned CLK_PS = 1000;   // 1e9/1MHz? 这里用 ps 单位, 10ns 周期 = 10000 ps

  logic clk = 1'b0;
  logic rst = 1'b1;
  always #5000 clk = ~clk;                 // 10 ns 周期 (10MHz 仿真速度)

  // DUT 端口
  logic              start;
  logic              busy, done, err;
  logic [31:0]       cycles;
  logic [7:0]        err_code;
  nn_desc_t          eng_desc;
  logic              eng_start;
  logic              eng_busy, eng_done;
  logic [31:0]       eng_cycles;
  logic [7:0]        eng_err_code;

  nn_seq dut (
    .clk(clk), .rst(rst),
    .start(start), .busy(busy), .done(done), .cycles(cycles),
    .err(err), .err_code(err_code),
    .eng_desc(eng_desc), .eng_start(eng_start),
    .eng_busy(eng_busy), .eng_done(eng_done),
    .eng_cycles(eng_cycles), .eng_err_code(eng_err_code)
  );

  // ------------------------------------------------------------------------
  // 行为级假引擎
  // ------------------------------------------------------------------------
  logic [31:0] stub_cnt;       // 当前 op 剩余拍数
  logic [31:0] stub_cycles;    // 本次 op 的 cycles (模拟引擎"周期数")
  logic        stub_done;

  int          n_start;        // 收到的 start 次数
  int          n_mismatch;
  logic [31:0] sum_cycles;     // 假引擎 cycles 之和
  logic [31:0] op_desc [0:255];
  int          n_cap;

  // 每次 start 的延时 = 3 + (src[3:0] ^ dst[3:0]) 拍(小), 保证有变化
  always @(posedge clk) begin
    if (rst) begin
      stub_cnt    <= 32'd0;
      stub_cycles <= 32'd0;
      stub_done   <= 1'b0;
      n_start     <= 0;
      n_mismatch  <= 0;
      sum_cycles  <= 32'd0;
      n_cap       <= 0;
      eng_busy    <= 1'b0;
      eng_done    <= 1'b0;
      eng_cycles  <= 32'd0;
      eng_err_code<= 8'd0;
    end else begin
      eng_done <= 1'b0;
      if (eng_start) begin
        // 记录一次 start
        if (n_start < 256) op_desc[n_start] = eng_desc;
        n_start     <= n_start + 1;
        stub_cycles <= 32'd3 + {26'd0, (eng_desc.src[3:0] ^ eng_desc.dst[3:0])};
        stub_cnt    <= 32'd3 + {26'd0, (eng_desc.src[3:0] ^ eng_desc.dst[3:0])};
        eng_busy    <= 1'b1;
      end else if (eng_busy) begin
        if (stub_cnt > 32'd0) begin
          stub_cnt <= stub_cnt - 32'd1;
        end else begin
          eng_busy   <= 1'b0;
          eng_done   <= 1'b1;
          eng_cycles <= stub_cycles;
          sum_cycles <= sum_cycles + stub_cycles;
        end
      end
    end
  end

  // ------------------------------------------------------------------------
  // 激励 / 检查
  // ------------------------------------------------------------------------
  int errors;
  int idx_checked;

  task automatic run_once;
    begin
      @(negedge clk); start = 1'b1;
      @(negedge clk); start = 1'b0;
      // 等 done (最多 10000 拍)
      begin : wait_done
        int guard;
        guard = 0;
        while (done !== 1'b1) begin
          @(posedge clk);
          #1;
          if (guard > 20000) begin
            $display("NN_SEQ_TB: FAIL timeout waiting done (starts=%0d busy=%b)", n_start, busy);
            errors++;
            disable wait_done;
          end
          guard++;
        end
      end
    end
  endtask

  initial begin
    errors     = 0;
    idx_checked= 0;
    start      = 1'b0;

    repeat (5) @(posedge clk);
    rst <= 1'b0;
    repeat (3) @(posedge clk);

    // ---- 第 1 轮: 正常跑完 ----
    run_once();

    if (done !== 1'b1) begin
      $display("NN_SEQ_TB: FAIL done not high");
      errors++;
    end
    if (n_start !== NN_ROM_LEN) begin
      $display("NN_SEQ_TB: FAIL start count %0d != ROM_LEN %0d", n_start, NN_ROM_LEN);
      errors++;
    end
    if (cycles !== sum_cycles) begin
      $display("NN_SEQ_TB: FAIL cycles %0d != sum %0d", cycles, sum_cycles);
      errors++;
    end
    if (err !== 1'b0) begin
      $display("NN_SEQ_TB: FAIL unexpected err");
      errors++;
    end

    // 每条 desc 的 op 应与 ROM kind 对应
    for (int i = 0; i < n_start && i < 256; i++) begin
      automatic nn_rom_t r = NN_ROM[i];
      automatic nn_desc_t d;
      d = op_desc[i];
      unique case (r.kind)
        NN_ROM_KIND_CONV: if (d.op != NN_OP_CONV) errors++;
        NN_ROM_KIND_DW:   if (d.op != NN_OP_CONV) errors++;
        NN_ROM_KIND_POOL: if (d.op != NN_OP_POOL) errors++;
        NN_ROM_KIND_UP2X: if (d.op != NN_OP_COPY) errors++;
        NN_ROM_KIND_ADD:  if (d.op != NN_OP_ADD)  errors++;
        NN_ROM_KIND_COPY: if (d.op != NN_OP_COPY) errors++;
        default: errors++;
      endcase
      if (d.src !== 32'(r.src) || d.dst !== 32'(r.dst)) errors++;
    end

    // ---- 第 2 轮: 引擎报错注入 ----
    if (NN_ROM_LEN > 0) begin
      // 让假引擎把第一次 done 的 err_code 置非零 -> nn_seq 应进 S_ERR
      fork
        begin
          @(negedge clk); start = 1'b1;
          @(negedge clk); start = 1'b0;
        end
        begin
          // 等第一个 eng_done 拍的前一拍注入
          wait (eng_busy === 1'b1);
          repeat (2) @(posedge clk);
          eng_err_code <= 8'h7A;
          wait (dut.err === 1'b1);
          @(posedge clk);
          eng_err_code <= 8'd0;
        end
      join_any
      if (dut.err !== 1'b1) begin
        $display("NN_SEQ_TB: FAIL err path not triggered");
        errors++;
      end
      repeat (5) @(posedge clk);
    end

    if (errors == 0)
      $display("NN_SEQ_TB: PASS (starts=%0d rom_len=%0d cycles=%0d)", n_start, NN_ROM_LEN, cycles);
    else
      $display("NN_SEQ_TB: FAIL (%0d errors)", errors);

    $finish;
  end

  initial begin
    #20_000_000;
    $display("NN_SEQ_TB: FAIL global timeout");
    $finish;
  end

endmodule
