`timescale 1ns/1ps

// ============================================================================
// nn_subsys.sv — AI 加速子系统顶层 (v0.7: 双执行模式 + 128 MAC 引擎 + Q LUTRAM)
// ----------------------------------------------------------------------------
// 契约: results/ai-accel/CONTRACT.md §12 (v0.7) / results/ai-accel/SPEC-SPECIALIZED.md
// 冻结: results/ai-accel/MODEL-FREEZE.md (模型/权重/层序列不可变)
//
// 结构:
//   mmio ext 总线 (0xA000_0100..0x0148) ─┐
//   core nn_* 数据窗 (A/B only) ────────┤
//                                        ▼
//                                   nn_subsys
//                                   ├─ 控制/状态/cycles
//                                   ├─ nn_seq      (MODE_AUTO: 微码 ROM 自主执行)
//                                   ├─ nn_mem v0.7 (W 320KB BRAM / Q 48KB LUTRAM / A,B)
//                                   └─ nn_conv_engine v3 (128 MAC/拍)
//
// 执行模式 (CONTRACT §12.5):
//   MODE_CPU  (CTRL.auto=0): 与 v0.5 完全一致 —— CPU 逐 op 写描述符 + start, 轮询 done。
//   MODE_AUTO (CTRL.auto=1): CPU 只写一次 start; nn_seq 按 nn_rom_pkg::NN_ROM 自主跑完,
//                            完成后 STATUS.done=1、CYCLES=总周期; CPU 期间可做别的事。
//   两种模式共用同一引擎/存储, 数值语义完全相同 (dual-mode 回归的硬件基础)。
//
// 【CPU 数据窗口的相位口径】core 在 MEM 拍给地址, 期望读数据 WB 拍有效 (与 dmem 同口径)。
//   nn_mem 是寄存读 (地址进、下一拍出), 所以 cpu_rdata 直接进 core, 中间不能再打拍。
//
// 【busy 期间的 CPU 访问】CPU 不许碰 NN 窗口:
//   读 -> 0xDEAD_BEEF; 写 -> 丢弃并置 STATUS.err (sticky)。
// ============================================================================

module nn_subsys
  import rv32_pkg::*;
  import nn_pkg::*;
#(
  parameter int unsigned W_BYTES   = NN_W_BYTES,
  parameter int unsigned Q_BYTES   = NN_Q_BYTES,
  parameter int unsigned A_BYTES   = NN_A_BYTES,
  parameter int unsigned B_BYTES   = NN_B_BYTES
)(
  input  logic        clk,
  input  logic        rst,

  // ---- MMIO 控制寄存器接口 (组合读; 顶层已按地址段选通) ----
  input  logic        ctl_we,
  input  logic        ctl_re,
  input  logic [31:0] ctl_addr,
  input  logic [31:0] ctl_wdata,
  input  logic [3:0]  ctl_wstrb,
  output logic [31:0] ctl_rdata,

  // ---- CPU 数据窗口 (接 core 的 nn_* 端口; 1 拍寄存读; 只映射 A/B) ----
  input  logic        cpu_re,
  input  logic        cpu_we,
  input  logic [31:0] cpu_addr,
  input  logic [31:0] cpu_wdata,
  input  logic [3:0]  cpu_wstrb,
  output logic [31:0] cpu_rdata,

  // ---- 观测 (ILA / LED / 调试) ----
  output logic        busy_o,
  output logic        done_o,
  output logic        err_o,
  output logic [31:0] cycles_o,
  output logic [7:0]  err_code_o
);

  // ==========================================================================
  // 1. 描述符寄存器 (MODE_CPU 用; 软件逐层写, start 拍整体锁存)
  // ==========================================================================
  logic [31:0] r_op, r_src, r_dst, r_woff, r_qoff;
  logic [31:0] r_ih, r_iw, r_ic, r_oc, r_ks, r_st, r_pad, r_flags;
  logic        r_irq_en;
  logic        auto_r;                 // 当前执行模式 (start 拍锁存)
  logic        done_r, err_r;
  logic [7:0]  err_code_r;
  logic [31:0] cycles_r;

  nn_desc_t desc_next;
  assign desc_next = '{
    op     : r_op[1:0],
    flags  : r_flags[7:0],             // v0.8: 8 位 (v0.7 PACKED3/ADD_R + RELU)
    ks     : r_ks[3:0],
    stride : r_st[1:0],
    pad    : r_pad[2:0],
    ih     : r_ih[15:0],
    iw     : r_iw[15:0],
    ic     : r_ic[15:0],
    oc     : r_oc[15:0],
    src    : r_src,
    dst    : r_dst,
    woff   : r_woff,
    qoff   : r_qoff
  };

  nn_desc_t desc_r;                    // MODE_CPU 运行中的描述符

  // ==========================================================================
  // 2. 引擎 / 存储 / 序列器
  // ==========================================================================
  // 引擎控制 (CPU 模式 or nn_seq 模式, 二选一)
  logic        eng_start_cpu, eng_start_seq;
  logic        eng_start;
  nn_desc_t    eng_desc;
  logic        eng_busy, eng_done;
  logic [31:0] eng_cycles;
  logic [7:0]  eng_err;

  logic        eng_w_re;
  logic [23:0] eng_w_addr;
  logic [127:0] eng_w_rdata;
  logic        eng_q_re;
  logic [12:0] eng_q_addr;
  logic [63:0] eng_q_rdata;
  logic [1:0]  eng_a_sel;
  logic        eng_a_re;
  logic [23:0] eng_a_addr;
  logic [127:0] eng_a_rdata;
  logic [1:0]  eng_b_sel;
  logic        eng_b_we;
  logic [23:0] eng_b_addr;
  logic [127:0] eng_b_wdata;
  logic [15:0] eng_b_wstrb;

  // nn_seq <-> 本模块
  nn_desc_t    desc_seq;               // nn_seq 输出的描述符
  logic        seq_start;
  logic        seq_busy, seq_done;
  logic [31:0] seq_cycles;
  logic        seq_err;
  logic [7:0]  seq_err_code;

  logic        cpu_we_g;
  logic [31:0] mem_cpu_rdata;
  logic [31:0] cpu_off;

  // 【v0.7 集成 bug 修复 2026-11-01】done/err 必须是**粘滞**的寄存器状态,
  // 不能直接接 seq_done/seq_err 单拍脉冲: CPU 轮询 STATUS 是"每 2~4 拍读一次",
  // 单拍脉冲会被漏掉 -> 程序永远等不到 done (MODE_AUTO 实测: ROM 跑完 idx=112 但 CPU 卡死)。
  // MODE_CPU 一直是 done_r (粘滞) 所以没暴露; 这里让两种模式共用 done_r/err_r。
  assign done_o     = done_r;
  assign err_o      = err_r;

  // 引擎描述符/启动源选择（[v1 · S1] job 运行期内也走 MODE_AUTO 的 seq 通路）
  // 注：这两条 assign 在 job 块之后统一定义（引用 j_pending，避免前向引用）。

  // ==========================================================================
  // [v1 · S1 / task-13] Job 级接口（CPU-NPU 解耦第一版；单时钟，0 core 改动）
  // --------------------------------------------------------------------------
  // 设计: results/bottlecap/reports/CPU-NPU-DECOUPLE.md §4 / M5-JOB-IF.md
  // 流程: CPU 写 IN/OUT/MODEL/FRAME/LEN + doorbell
  //       -> nn_seq 自主跑完整 ROM（MODE_AUTO 同一引擎/ROM 路径）
  //       -> 从 JOB_OUT_ADDR 拷贝 payload 到 2KB 结果邮箱（header 最后写）
  //       -> done/err/cycles/frame 粘滞 -> CPU 读邮箱 + ACK -> 可接下一 job
  // 兼容: legacy MODE_CPU/MODE_AUTO **逐位不变** —— 所有新增逻辑只在 doorbell
  //       之后生效；busy/cpu_rdata 的增量在 legacy 下恒为 +0/false。
  // 资源: 邮箱 = distributed RAM 512×32（16Kb ≈256 LUT6），**BRAM 增量 0**；
  //       寄存器约 14×32 + 状态机/计数器。
  // ==========================================================================
  localparam int unsigned NN_MB_WORDS     = 512;   // 2KB / 4B
  localparam int unsigned NN_MB_PAY_WORD  = 8;     // payload 起始字（字节 +0x20）
  localparam logic [31:0] NN_MB_MAGIC_VAL = 32'h4E50_5552;  // "NPUR"

  logic [31:0] j_in_r, j_out_r, j_model_r, j_frame_r, j_len_r;
  logic        j_pending, j_copy;             // job 运行中 / 邮箱拷贝中
  logic        j_ever;                        // 首次 doorbell 后置位（邮箱映射启用）
  logic        j_done, j_err, j_timeout;      // 粘滞（NN_ACK 清）
  logic [7:0]  j_err_code;
  logic [31:0] j_cycles, j_frame_no;
  logic [31:0] j_jobs_done, j_drop_cnt;
  logic        j_mb_sel;                      // CPU 当前访问落在邮箱窗口
  logic [31:0] j_mb_rdata;
  (* ram_style = "distributed" *) logic [31:0] j_mb [0:NN_MB_WORDS-1];

  // mailbox-copy FSM（payload：1 字/拍；header 8 字各 1 拍）
  typedef enum logic [2:0] {
    MC_IDLE = 3'd0, MC_REQ = 3'd1, MC_RD = 3'd2, MC_HDR = 3'd3, MC_DONE = 3'd4
  } mc_state_e;
  mc_state_e   mc_st;
  logic [31:0] j_copy_addr;
  logic [10:0] j_copy_cnt;                    // payload 字计数（≤504）
  logic [10:0] j_len_words;
  logic [3:0]  j_hdr_idx;
  logic        job_start_pulse;               // doorbell -> nn_seq.start（单拍）
  wire         seq_start_all = seq_start | job_start_pulse;

  // copy 期间由 FSM 占用 nn_mem 的 CPU 读口（REQ/RD 两态；CPU 侧被 busy 挡住）
  wire         mc_mem_active = (mc_st == MC_REQ) || (mc_st == MC_RD);
  wire         mem_cpu_re    = mc_mem_active ? 1'b1 : cpu_re;
  wire [31:0]  mem_cpu_addr  = mc_mem_active ? j_copy_addr : cpu_off;

  // nn_seq 的 job 级只读状态（task-13 新增输出）
  logic [7:0]  seq_done_ops;
  logic        seq_job_timeout;
  logic [31:0] seq_cycles_lat;

  // 邮箱读口（1 拍寄存读，与 nn_mem/dimem 同口径）
  // 【必须同时寄存 select（j_mb_sel_r）】core 的 nn_* 是"地址第 N 拍、数据 N+1 拍有效"：
  //   WB 拍上的 cpu_off 已经是下一条指令的地址，若用组合 j_mb_sel 回选，
  //   mailbox/AB 交替访问（如逐字节比对）会在 WB 拍选错源 —— 实测表现为
  //   "rd32 连读正确、rd8 交替读全 0"。与 nn_mem 的 cpu_sel_r/cpu_lane_r 同因同治。
  logic j_mb_sel_r;
  always_ff @(posedge clk) begin
    j_mb_rdata <= j_mb[cpu_off[10:2]];
    j_mb_sel_r <= j_mb_sel;
  end
`ifndef SYNTHESIS
  initial begin
    for (int i = 0; i < NN_MB_WORDS; i++) j_mb[i] = 32'd0;   // 消 X（写前读不在协议内）
  end
`endif

  // --------------------------------------------------------------------------
  // job 寄存器 + 完成握手 + 邮箱拷贝 FSM（全部在同一时钟域；legacy 下全静止）
  // --------------------------------------------------------------------------
  always @(posedge clk) begin
    if (rst) begin
      j_in_r <= '0; j_out_r <= '0; j_model_r <= '0; j_frame_r <= '0; j_len_r <= '0;
      j_pending <= 1'b0; j_copy <= 1'b0; j_ever <= 1'b0;
      j_done <= 1'b0; j_err <= 1'b0; j_timeout <= 1'b0; j_err_code <= 8'h00;
      j_cycles <= 32'd0; j_frame_no <= 32'd0;
      j_jobs_done <= 32'd0; j_drop_cnt <= 32'd0;
      mc_st <= MC_IDLE; j_copy_addr <= 32'd0; j_copy_cnt <= 11'd0;
      j_len_words <= 11'd0; j_hdr_idx <= 4'd0;
      job_start_pulse <= 1'b0; seq_cycles_lat <= 32'd0;
    end
    else begin
      job_start_pulse <= 1'b0;               // 默认单拍

      // ---- job 寄存器写 / doorbell / ack（MMIO 段 0xA000_0150..）----
      if (ctl_we) begin
        unique case (ctl_addr)
          MMIO_NN_JOB_IN_ADDR:  j_in_r    <= ctl_wdata;
          MMIO_NN_JOB_OUT_ADDR: j_out_r   <= ctl_wdata;
          MMIO_NN_JOB_MODEL:    j_model_r <= ctl_wdata;
          MMIO_NN_JOB_FRAME:    j_frame_r <= ctl_wdata;
          MMIO_NN_JOB_LEN:      j_len_r   <= ctl_wdata;
          MMIO_NN_JOB_DOORBELL: if (ctl_wdata[0]) begin
            // 忙 / 结果未 ACK 时：丢弃 + 计数（盘古"忙时丢快照"语义）
            if (busy_o || j_done || j_pending || j_copy) begin
              j_drop_cnt <= j_drop_cnt + 32'd1;
            end
            else begin
              j_ever     <= 1'b1;
              j_done     <= 1'b0;
              j_err      <= 1'b0;
              j_timeout  <= 1'b0;
              j_err_code <= 8'h00;
              j_cycles   <= 32'd0;
              j_frame_no <= j_frame_r;
              if (j_model_r[7:0] != 8'd0) begin
                // S1 只支持 model 0（YOLO-C128 ROM）; 其它模型号立即完成 + E7
                j_err      <= 1'b1;
                j_err_code <= 8'hE7;
                j_done     <= 1'b1;
              end
              else if ((j_len_r > 32'd2016) || (j_len_r[1:0] != 2'b00)) begin
                // 邮箱长度非法 -> E1（不启动 seq）
                j_err      <= 1'b1;
                j_err_code <= 8'hE1;
                j_done     <= 1'b1;
              end
              else begin
                j_pending       <= 1'b1;
                j_len_words     <= j_len_r[12:2];
                job_start_pulse <= 1'b1;
              end
            end
          end
          MMIO_NN_JOB_ACK: if (ctl_wdata[0]) begin
            j_done     <= 1'b0;
            j_err      <= 1'b0;
            j_timeout  <= 1'b0;
            j_err_code <= 8'h00;
          end
          default: ;
        endcase
      end

      // ---- seq 完成 / 错误 -> job 收尾 ----
      if (j_pending) begin
        if (seq_job_timeout || seq_err) begin
          // 超时（E4）或引擎/描述符错误（E3/E5/引擎码）：不拷贝 payload（无可信结果）
          j_pending   <= 1'b0;
          j_err       <= 1'b1;
          j_err_code  <= seq_job_timeout ? 8'hE4 : seq_err_code;
          j_timeout   <= seq_job_timeout;
          j_cycles    <= seq_cycles;
          j_jobs_done <= j_jobs_done + 32'd1;
          j_done      <= 1'b1;
        end
        else if (seq_done) begin
          j_pending      <= 1'b0;
          j_copy         <= 1'b1;
          j_cycles       <= seq_cycles;
          seq_cycles_lat <= seq_cycles;
          j_frame_no     <= j_frame_r;
          j_err          <= 1'b0;
          j_err_code     <= 8'h00;
          j_jobs_done    <= j_jobs_done + 32'd1;
          j_copy_addr    <= j_out_r;
          j_copy_cnt     <= 11'd0;
          j_hdr_idx      <= 4'd0;
          mc_st          <= (j_len_words == 11'd0) ? MC_HDR : MC_REQ;
        end
      end

      // ---- 邮箱拷贝 FSM ----
      case (mc_st)
        MC_REQ: begin
          // 第 1 个读地址已在上一拍由 mem_cpu_addr 送出；现在推进到第 2 个
          j_copy_addr <= j_copy_addr + 32'd4;
          j_copy_cnt  <= 11'd0;
          mc_st       <= MC_RD;
        end
        MC_RD: begin
          j_mb[NN_MB_PAY_WORD + j_copy_cnt] <= mem_cpu_rdata;
          if ((j_copy_cnt + 11'd1) >= j_len_words) begin
            mc_st <= MC_HDR;
          end
          else begin
            j_copy_cnt  <= j_copy_cnt + 11'd1;
            j_copy_addr <= j_copy_addr + 32'd4;
          end
        end
        MC_HDR: begin
          // header 最后写（magic 字 0 也在最后阶段才写 => CPU 见 done 时邮箱完整）
          case (j_hdr_idx)
            4'd0: j_mb[0] <= NN_MB_MAGIC_VAL;
            4'd1: j_mb[1] <= j_frame_r;
            4'd2: j_mb[2] <= j_model_r;
            4'd3: j_mb[3] <= seq_cycles_lat;
            4'd4: j_mb[4] <= {24'd0, j_err_code};
            4'd5: j_mb[5] <= j_out_r;
            4'd6: j_mb[6] <= j_len_r;
            default: j_mb[7] <= 32'd0;
          endcase
          if (j_hdr_idx == 4'd7) mc_st <= MC_DONE;
          else                   j_hdr_idx <= j_hdr_idx + 4'd1;
        end
        MC_DONE: begin
          j_copy <= 1'b0;
          j_done <= 1'b1;
          mc_st  <= MC_IDLE;
        end
        default: ;
      endcase
    end
  end

  // ---- [v1 · S1] busy / CPU 窗口 / 邮箱映射（legacy 下 j_pending/j_copy/j_ever 恒 0）----
  assign busy_o    = (auto_r ? seq_busy : eng_busy) | j_pending | j_copy;
  assign cpu_we_g  = cpu_we && !busy_o;
  assign cpu_off   = cpu_addr - NN_BASE;
  // 首次 doorbell 后：NN 窗口前 2KB 偏移映射到结果邮箱（W 区是 ROM，CPU 原本读 0）
  assign j_mb_sel  = j_ever && (cpu_off < 32'h0000_0800);
  assign cpu_rdata = busy_o ? 32'hDEAD_BEEF
                            : (j_mb_sel_r ? j_mb_rdata : mem_cpu_rdata);
  // ---- [v1 · S1] 数据通路选择：job 运行期内同样走 nn_seq（MODE_AUTO 同一通路）----
  assign eng_desc   = (auto_r || j_pending) ? desc_seq : desc_r;
  assign eng_start  = (auto_r || j_pending) ? eng_start_seq : eng_start_cpu;
  assign cycles_o   = (auto_r || j_pending) ? seq_cycles : cycles_r;
  assign err_code_o = (auto_r || j_pending) ? seq_err_code : err_code_r;

  // ==========================================================================
  // 3. nn_mem v0.7 + M2 (W 320KB 128b 读 / Q 48KB LUTRAM 64b 读 / A,B 128b)
  //    [M2] 新增流式端口 (w_mode/w_bank_sel/wfill_*/q_bank_sel/qfill_*) 在本版
  //    只做 tie-off: 默认 w_mode=0 => v0.7 ROM 路径逐位不变; 真正的预取/银行翻转
  //    接线在 M5 由 nn_seq/nn_wload 完成 (rtl-integ)。这里不引入任何寄存器/MMIO。
  // ==========================================================================
  nn_mem #(
    .W_BYTES (W_BYTES),
    .Q_BYTES (Q_BYTES),
    .A_BYTES (A_BYTES),
    .B_BYTES (B_BYTES)
  ) u_mem (
    .clk       (clk),
    .rst       (rst),
    // [v1 · S1] 邮箱拷贝 FSM 期间由本模块占用 CPU 读口（mc_mem_active）；其余时刻原样透传
    .cpu_re    (mem_cpu_re),
    .cpu_we    (cpu_we_g),
    .cpu_addr  (mem_cpu_addr),
    .cpu_wdata (cpu_wdata),
    .cpu_wstrb (cpu_wstrb),
    .cpu_rdata (mem_cpu_rdata),
    .w_re      (eng_w_re),
    .w_addr    (eng_w_addr),
    .w_rdata   (eng_w_rdata),
    .q_re      (eng_q_re),
    .q_addr    (eng_q_addr),
    .q_rdata   (eng_q_rdata),
    .a_sel     (eng_a_sel),
    .a_re      (eng_a_re),
    .a_addr    (eng_a_addr),
    .a_rdata   (eng_a_rdata),
    .b_sel     (eng_b_sel),
    .b_we      (eng_b_we),
    .b_addr    (eng_b_addr),
    .b_wdata   (eng_b_wdata),
    .b_wstrb   (eng_b_wstrb),
    // v0.7 debug 装载口: module-level TB 用它初始化/回读 W、Q; SoC 中恒 0
    .dbg_we    (1'b0),
    .dbg_space (1'b0),
    .dbg_addr  (17'd0),
    .dbg_wdata (32'd0),
    // [M2] 流式 W/Q tie-off: 0 => w_mode=ROM (v0.7 兼容), 填充口关闭, 活动银行 0
    .w_mode      (1'b0),
    .w_bank_sel  (1'b0),
    .wfill_we    (1'b0),
    .wfill_addr  (18'd0),
    .wfill_wdata (64'd0),
    .q_bank_sel  (1'b0),
    .qfill_we    (1'b0),
    .qfill_addr  (13'd0),
    .qfill_wdata (64'd0)
  );

  // ==========================================================================
  // 4. nn_conv_engine v3 (128 MAC/拍)
  // ==========================================================================
  nn_conv_engine #(
    .OC_LANES (16),
    .PX_LANES (8)
  ) u_eng (
    .clk       (clk),
    .rst       (rst),
    .desc      (eng_desc),
    .start     (eng_start),
    .busy      (eng_busy),
    .done      (eng_done),
    .cycles    (eng_cycles),
    .err_code  (eng_err),
    .w_re      (eng_w_re),
    .w_addr    (eng_w_addr),
    .w_rdata   (eng_w_rdata),
    .q_re      (eng_q_re),
    .q_addr    (eng_q_addr),
    .q_rdata   (eng_q_rdata),
    .a_sel     (eng_a_sel),
    .a_re      (eng_a_re),
    .a_addr    (eng_a_addr),
    .a_rdata   (eng_a_rdata),
    .b_sel     (eng_b_sel),
    .b_we      (eng_b_we),
    .b_addr    (eng_b_addr),
    .b_wdata_128 (eng_b_wdata),
    .b_wstrb   (eng_b_wstrb)
  );

  // ==========================================================================
  // 5. nn_seq (MODE_AUTO 微码序列器)
  // ==========================================================================
  nn_seq u_seq (
    .clk        (clk),
    .rst        (rst),
    // [v1 · S1] legacy CTRL 启动 或 job doorbell（job_start_pulse）二选一
    .start      (seq_start_all),
    .busy       (seq_busy),
    .done       (seq_done),
    .cycles     (seq_cycles),
    .err        (seq_err),
    .err_code   (seq_err_code),
    // [v1 · S1] job 级只读状态（看门狗超时/完成 op 数）
    .done_ops     (seq_done_ops),
    .job_timeout  (seq_job_timeout),
    .eng_desc   (desc_seq),
    .eng_start  (eng_start_seq),
    .eng_busy   (eng_busy),
    .eng_done   (eng_done),
    .eng_cycles (eng_cycles),
    .eng_err_code(eng_err),
    // ==========================================================================
    // [v1 · M6c / task-17] band / streaming 控制端口 tie-off
    //   本模块（M5-S1 单时钟 job 版）不接 DDR3/band 路径: ROM 的 tile=0 时
    //   nn_seq 只走 legacy/M6c 内置直通, 这些输入取值不影响 legacy 行为。
    //   输入全部并联常量; 输出悬空（等 M6 全链路集成时由 rtl-integ 重接）:
    //     pre_start/pre_* -> nn_wload; d_* / band_start -> nn_tilecache;
    //     w_bank_sel/q_bank_sel -> nn_mem 流式 bank; band_idx/n/active -> ILA。
    // ==========================================================================
    .pre_busy       (1'b0),
    .pre_done       (1'b1),
    .pre_err        (1'b0),
    .band_ready     (1'b1),
    .band_done      (1'b1),
    .tile_err       (8'd0),
    .w_ddr_base     (32'd0),
    .q_ddr_base     (32'd0),
    .arena_ddr_base (32'd0)
  );

  // ==========================================================================
  // 6. 描述符合法性检查 (MODE_CPU start 拍用; 不合法 -> 不启动 + err)
  //    [M2/M5 集成级放宽, Lead 2026-11-03 授权]
  //    1) IC/OC 上限 256 -> 1023: 瓶盖模型最大通道 864 (MobileNetV2 expansion),
  //       旧 256 检查会拒掉 106 op 中的 33 个; 引擎 ic 字段 10-bit / icb_n 7-bit
  //       (rtl-engine M1 补齐) 支持到 1023。
  //    2) dst 上限 NN 窗口 (NN_BYTES=512KB) -> 4MB: v1 流式模式的 dst 是 DDR3
  //       arena 相对偏移 (22-bit / 4MB 窗口, 见 ROM-V1); ROM 模式下 YOLO 的
  //       dst < 0x80000 不受影响。硬件只做合法性检查, 不参与寻址。
  // ==========================================================================
  logic desc_ok;
  always_comb begin
    desc_ok = 1'b1;
    if (desc_next.ic == 0 || desc_next.ic > 1023) desc_ok = 1'b0;
    if (desc_next.oc == 0 || desc_next.oc > 1023) desc_ok = 1'b0;
    if (desc_next.ih == 0 || desc_next.iw == 0)  desc_ok = 1'b0;
    case (desc_next.op)
      NN_OP_CONV: begin
        if (!(desc_next.ks == 4'd1 || desc_next.ks == 4'd3 || desc_next.ks == 4'd5)) desc_ok = 1'b0;
        if (!(desc_next.stride == 2'd1 || desc_next.stride == 2'd2)) desc_ok = 1'b0;
        if (desc_next.pad > 3'd2) desc_ok = 1'b0;
      end
      NN_OP_POOL: begin
        if (!(desc_next.ks == 4'd2 || desc_next.ks == 4'd3 ||
              desc_next.ks == 4'd5 || desc_next.ks == 4'd9)) desc_ok = 1'b0;
        if (desc_next.pad > 3'd4) desc_ok = 1'b0;
      end
      default: ;
    endcase
    if (desc_next.dst >= 32'd4_194_304) desc_ok = 1'b0;   // 4MB DDR3 arena 窗口
  end

  // ==========================================================================
  // 7. 寄存器读写 + 启动/完成/错误握手
  // ==========================================================================
  always @(posedge clk) begin
    if (rst) begin
      r_op <= '0; r_src <= '0; r_dst <= '0; r_woff <= '0; r_qoff <= '0;
      r_ih <= '0; r_iw <= '0; r_ic <= '0; r_oc <= '0;
      r_ks <= '0; r_st <= '0; r_pad <= '0; r_flags <= '0;
      r_irq_en <= 1'b0;
      auto_r   <= 1'b0;
      desc_r   <= '0;
      eng_start_cpu <= 1'b0;
      seq_start     <= 1'b0;
      done_r   <= 1'b0;
      err_r    <= 1'b0;
      err_code_r <= 8'h00;
      cycles_r <= 32'd0;
    end
    else begin
      eng_start_cpu <= 1'b0;               // 默认单拍脉冲
      seq_start     <= 1'b0;

      // ---- MMIO 写 ----
      if (ctl_we) begin
        case (ctl_addr)
          MMIO_NN_CTRL: begin
            r_irq_en <= ctl_wdata[1];
            if (ctl_wdata[0]) begin
              if (!busy_o) begin
                auto_r <= ctl_wdata[1];
                if (ctl_wdata[1]) begin
                  // MODE_AUTO: 一次启动 nn_seq, 自主跑完
                  seq_start <= 1'b1;
                  done_r    <= 1'b0;
                  err_r     <= 1'b0;
                end else if (desc_ok) begin
                  // MODE_CPU: 逐 op
                  eng_start_cpu <= 1'b1;
                  desc_r        <= desc_next;
                  done_r        <= 1'b0;
                  cycles_r      <= 32'd0;
                  err_r         <= 1'b0;
                  err_code_r    <= 8'h00;
                end else begin
                  err_r      <= 1'b1;
                  err_code_r <= 8'hE1;      // 描述符非法
                end
              end
              // busy 时写 start: 忽略 (不打断当前任务)
            end
          end
          MMIO_NN_OP:    r_op    <= ctl_wdata;
          MMIO_NN_SRC:   r_src   <= ctl_wdata;
          MMIO_NN_DST:   r_dst   <= ctl_wdata;
          MMIO_NN_WOFF:  r_woff  <= ctl_wdata;
          MMIO_NN_QOFF:  r_qoff  <= ctl_wdata;
          MMIO_NN_IH:    r_ih    <= ctl_wdata;
          MMIO_NN_IW:    r_iw    <= ctl_wdata;
          MMIO_NN_IC:    r_ic    <= ctl_wdata;
          MMIO_NN_OC:    r_oc    <= ctl_wdata;
          MMIO_NN_KS:    r_ks    <= ctl_wdata;
          MMIO_NN_ST:    r_st    <= ctl_wdata;
          MMIO_NN_PAD:   r_pad   <= ctl_wdata;
          MMIO_NN_FLAGS: r_flags <= ctl_wdata;
          default: ;
        endcase
      end

      // ---- MMIO 读 STATUS: 读清 done/err ----
      if (ctl_re && (ctl_addr == MMIO_NN_STATUS)) begin
        done_r <= 1'b0;
        err_r  <= 1'b0;
      end

      // ---- busy 期间 CPU 误写 NN 窗口 -> 置 err ----
      if (busy_o && cpu_we) begin
        err_r      <= 1'b1;
        err_code_r <= 8'hE2;
      end

      // ---- MODE_CPU: 引擎完成（[v1 · S1] job 运行期内 j_pending=1，走下面 MODE_AUTO/seq 分支）----
      if (!auto_r && !j_pending) begin
        if (eng_done) begin
          done_r   <= 1'b1;
          cycles_r <= eng_cycles;
        end
        if (eng_err != 8'h00) begin
          err_r      <= 1'b1;
          err_code_r <= eng_err;
        end
      end else begin
        // ---- MODE_AUTO: 序列器完成 ----
        if (seq_done) done_r <= 1'b1;
        if (seq_err) begin
          err_r      <= 1'b1;
          err_code_r <= seq_err_code;
        end
      end
    end
  end

  // ==========================================================================
  // 8. 组合读
  // ==========================================================================
  always_comb begin
    ctl_rdata = 32'h0;
    case (ctl_addr)
      MMIO_NN_CTRL:   ctl_rdata = {29'h0, auto_r, r_irq_en, 1'b0};
      MMIO_NN_STATUS: ctl_rdata = {28'h0, r_irq_en & done_o, err_o, done_o, busy_o};
      MMIO_NN_CYCLES: ctl_rdata = cycles_o;
      MMIO_NN_OP:     ctl_rdata = r_op;
      MMIO_NN_SRC:    ctl_rdata = r_src;
      MMIO_NN_DST:    ctl_rdata = r_dst;
      MMIO_NN_WOFF:   ctl_rdata = r_woff;
      MMIO_NN_QOFF:   ctl_rdata = r_qoff;
      MMIO_NN_IH:     ctl_rdata = r_ih;
      MMIO_NN_IW:     ctl_rdata = r_iw;
      MMIO_NN_IC:     ctl_rdata = r_ic;
      MMIO_NN_OC:     ctl_rdata = r_oc;
      MMIO_NN_KS:     ctl_rdata = r_ks;
      MMIO_NN_ST:     ctl_rdata = r_st;
      MMIO_NN_PAD:    ctl_rdata = r_pad;
      MMIO_NN_FLAGS:  ctl_rdata = r_flags;
      MMIO_NN_DBG0:   ctl_rdata = {24'h0, eng_err};
      MMIO_NN_DBG1:   ctl_rdata = {16'h0, desc_r.ic, desc_r.oc};
      MMIO_NN_DBG2:   ctl_rdata = {16'h0, err_code_o};
      // ---- [v1 · S1] job 级接口（0xA000_0150..; 定义见 rv32_pkg:404-420 / M5-JOB-IF.md §2）----
      MMIO_NN_JOB_ID:       ctl_rdata = 32'h4E50_3101;     // "NP1"
      // [0]busy [1]done [2]err [3]pending [4]model_ready [6]timeout [7]mbox_valid
      // [15:8]err_code [23:16]done_ops(debug)
      MMIO_NN_JOB_STATUS:   ctl_rdata = {8'd0, seq_done_ops,
                                         ((j_done | j_err) ? j_err_code : 8'h00),
                                         j_done, j_timeout, 1'b0, 1'b1,
                                         j_pending, j_err, j_done, busy_o};
      MMIO_NN_JOB_FRAME_NO: ctl_rdata = j_frame_no;
      MMIO_NN_JOB_CYCLES:   ctl_rdata = j_cycles;
      MMIO_NN_JOB_IN_ADDR:  ctl_rdata = j_in_r;
      MMIO_NN_JOB_OUT_ADDR: ctl_rdata = j_out_r;
      MMIO_NN_JOB_MODEL:    ctl_rdata = j_model_r;
      MMIO_NN_JOB_FRAME:    ctl_rdata = j_frame_r;
      MMIO_NN_JOB_DOORBELL: ctl_rdata = {31'd0, j_pending};
      MMIO_NN_JOB_ERR_CODE: ctl_rdata = {24'd0, j_err_code};
      MMIO_NN_JOB_LEN:      ctl_rdata = j_len_r;
      MMIO_NN_JOB_DONE_CNT: ctl_rdata = j_jobs_done;
      MMIO_NN_JOB_DROP_CNT: ctl_rdata = j_drop_cnt;
      default:        ctl_rdata = 32'h0;
    endcase
  end

endmodule
