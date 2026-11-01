`timescale 1ns/1ps

// ============================================================================
// nn_seq.sv — 微码序列器（v0.7 autonomous mode）
// ----------------------------------------------------------------------------
// 契约: results/ai-accel/CONTRACT.md §12 / results/ai-accel/SPEC-SPECIALIZED.md
// 作用: 从 `nn_rom_pkg::NN_ROM` 顺序取出 op 项, 逐条翻译成 `nn_conv_engine` 描述符并启动,
//       等引擎 done 后继续; 全部跑完置 done。CPU 在 MODE_AUTO 下只写一次 start。
//
// 状态机 (每项 4 拍: FETCH / ISSUE / WAIT / NEXT):
//   IDLE  --start--> FETCH (rom <= NN_ROM[idx])
//   FETCH ---------> ISSUE (desc=rom_to_desc(rom), eng_start=1)
//   ISSUE ---------> WAIT
//   WAIT  --done---> NEXT (acc_cycles += eng_cycles)
//   NEXT ----------> FETCH (idx++) / DONE
//   DONE  ---------> IDLE
//
// 【调试口径】MODE_AUTO 不做逐 op checksum（需要 CPU 参与）；验证方式:
//   MODE_CPU 逐 op 校验和 == golden（数学）; MODE_AUTO 最终输出张量 == MODE_CPU（编排）。
//   ROM 的 csum 字段保留给未来硬件 checksum 单元。
// ============================================================================
module nn_seq
  import nn_pkg::*;
  import nn_rom_pkg::*;
(
  input  logic              clk,
  input  logic              rst,
  input  logic              start,
  output logic              busy,
  output logic              done,          // 单拍完成脉冲
  output logic [31:0]       cycles,        // 所有 op 的引擎周期累加
  output logic              err,
  output logic [7:0]        err_code,

  // ---- 给引擎 ----
  output nn_pkg::nn_desc_t  eng_desc,
  output logic              eng_start,
  input  logic              eng_busy,
  input  logic              eng_done,
  input  logic [31:0]       eng_cycles,
  input  logic [7:0]        eng_err_code
);

  // 单 op 看门狗: 正常 op 最大 < 200K 拍; 这里留 4M 拍余量, 防止仿真挂死
  localparam logic [31:0] GUARD_MAX = 32'd4_000_000;

  typedef enum logic [2:0] {
    S_IDLE  = 3'd0,
    S_FETCH = 3'd1,
    S_ISSUE = 3'd2,
    S_WAIT  = 3'd3,
    S_NEXT  = 3'd4,
    S_DONE  = 3'd5,
    S_ERR   = 3'd6
  } state_e;

  state_e       st, st_n;
  logic [7:0]   idx;
  logic [31:0]  acc_cycles;
  logic [31:0]  guard;
  logic [7:0]   err_code_r;
  logic         done_r, busy_r;
  nn_rom_t      rom;
  nn_desc_t     desc_r;

  wire last_entry = (NN_ROM_LEN == 0) || (idx == 8'(NN_ROM_LEN - 1));

  // ROM 同步读 (LUTRAM/distributed ROM)
  // [2026-11-01 修复] 原来直接 `rom <= NN_ROM[idx]` 读 package 常量数组: 综合必须把
  //   "112:1 x 200-bit" 展开成纯组合 mux 树 (~7.6K LUT), 导致整机综合在
  //   "Applying XDC Timing Constraints / Timing Optimization" 卡 40+ 分钟, 且白吃 LUT。
  // 改成"常量初始化 + 同步读"的数组: Vivado 推断成分布式 ROM (LUTRAM, ~400-500 LUT),
  //   功能/时序(1 拍)完全不变, tb_nn_seq 的期望值仍来自 nn_rom_pkg::NN_ROM。
  (* rom_style = "distributed" *)
  logic [199:0] rom_mem [0:NN_ROM_DEPTH-1];
  initial begin
    for (int i = 0; i < NN_ROM_DEPTH; i++) rom_mem[i] = NN_ROM[i];
  end
  always_ff @(posedge clk) begin
    if (rst) rom <= '0;
    else     rom <= rom_mem[idx];
  end

  // kind -> (op, flags); 其它字段由 nn_rom_to_desc 填
  always_comb begin
    desc_r   = nn_rom_to_desc(rom);
    desc_r.op = NN_OP_CONV;
    unique case (rom.kind)
      NN_ROM_KIND_CONV: desc_r.op = NN_OP_CONV;
      NN_ROM_KIND_DW: begin
        desc_r.op = NN_OP_CONV;
        desc_r.flags[NN_F_DEPTHWISE] = 1'b1;
      end
      NN_ROM_KIND_POOL: begin
        desc_r.op = NN_OP_POOL;
        desc_r.flags[NN_F_POOLMAX] = 1'b1;
      end
      NN_ROM_KIND_UP2X: begin
        desc_r.op = NN_OP_COPY;
        desc_r.flags[NN_F_UP2X] = 1'b1;
      end
      NN_ROM_KIND_ADD:  desc_r.op = NN_OP_ADD;
      NN_ROM_KIND_COPY: desc_r.op = NN_OP_COPY;
      default:          desc_r.op = NN_OP_CONV;
    endcase
  end

  assign eng_desc = desc_r;
  assign eng_start = (st == S_ISSUE);
  assign busy  = busy_r;
  assign done  = done_r;
  assign cycles = acc_cycles;
  assign err   = (st == S_ERR);
  assign err_code = err_code_r;

  // 状态转移
  always_comb begin
    st_n = st;
    unique case (st)
      S_IDLE:  if (start) st_n = (NN_ROM_LEN == 0) ? S_DONE : S_FETCH;
      S_FETCH: st_n = S_ISSUE;
      S_ISSUE: st_n = S_WAIT;
      S_WAIT: begin
        if (eng_err_code != 8'd0)    st_n = S_ERR;
        else if (guard >= GUARD_MAX) st_n = S_ERR;
        else if (eng_done)           st_n = S_NEXT;
      end
      S_NEXT:  st_n = last_entry ? S_DONE : S_FETCH;
      S_DONE:  st_n = S_IDLE;
      S_ERR:   st_n = S_IDLE;          // 等新的 start 再试
      default: st_n = S_IDLE;
    endcase
  end

  // 时序
  always_ff @(posedge clk) begin
    if (rst) begin
      st         <= S_IDLE;
      idx        <= 8'd0;
      acc_cycles <= 32'd0;
      guard      <= 32'd0;
      err_code_r <= 8'd0;
      busy_r     <= 1'b0;
      done_r     <= 1'b0;
    end else begin
      st     <= st_n;
      done_r <= 1'b0;
      unique case (st)
        S_IDLE: begin
          busy_r <= 1'b0;
          if (start) begin
            idx        <= 8'd0;
            acc_cycles <= 32'd0;
            guard      <= 32'd0;
            err_code_r <= 8'd0;
            busy_r     <= 1'b1;
          end
        end
        S_WAIT: begin
          guard <= guard + 32'd1;
          if (eng_done) acc_cycles <= acc_cycles + eng_cycles;
          if (eng_err_code != 8'd0) err_code_r <= eng_err_code;
          else if (guard >= GUARD_MAX) err_code_r <= 8'hE3;  // 看门狗超时
        end
        S_NEXT: begin
          idx <= idx + 8'd1;
        end
        S_DONE: begin
          done_r <= 1'b1;
          busy_r <= 1'b0;
        end
        S_ERR: begin
          busy_r <= 1'b0;
        end
        default: ;
      endcase
    end
  end

endmodule
