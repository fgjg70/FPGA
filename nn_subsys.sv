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
    flags  : r_flags[6:0],             // v0.7: 7 位 (PACKED3/ADD_R)
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

  assign busy_o     = auto_r ? seq_busy : eng_busy;
  assign done_o     = auto_r ? seq_done : done_r;
  assign err_o      = auto_r ? seq_err  : err_r;
  assign cycles_o   = auto_r ? seq_cycles : cycles_r;
  assign err_code_o = auto_r ? seq_err_code : err_code_r;

  assign cpu_off   = cpu_addr - NN_BASE;
  assign cpu_we_g  = cpu_we && !busy_o;
  assign cpu_rdata = busy_o ? 32'hDEAD_BEEF : mem_cpu_rdata;

  // 引擎描述符/启动源选择
  assign eng_desc  = auto_r ? desc_seq : desc_r;
  assign eng_start = auto_r ? eng_start_seq : eng_start_cpu;

  // ==========================================================================
  // 3. nn_mem v0.7 (W 320KB 128b 读 / Q 48KB LUTRAM 64b 读 / A,B 128b)
  // ==========================================================================
  nn_mem #(
    .W_BYTES (W_BYTES),
    .Q_BYTES (Q_BYTES),
    .A_BYTES (A_BYTES),
    .B_BYTES (B_BYTES)
  ) u_mem (
    .clk       (clk),
    .rst       (rst),
    .cpu_re    (cpu_re),
    .cpu_we    (cpu_we_g),
    .cpu_addr  (cpu_off),
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
    .dbg_wdata (32'd0)
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
    .start      (seq_start),
    .busy       (seq_busy),
    .done       (seq_done),
    .cycles     (seq_cycles),
    .err        (seq_err),
    .err_code   (seq_err_code),
    .eng_desc   (desc_seq),
    .eng_start  (eng_start_seq),
    .eng_busy   (eng_busy),
    .eng_done   (eng_done),
    .eng_cycles (eng_cycles),
    .eng_err_code(eng_err)
  );

  // ==========================================================================
  // 6. 描述符合法性检查 (MODE_CPU start 拍用; 不合法 -> 不启动 + err)
  // ==========================================================================
  logic desc_ok;
  always_comb begin
    desc_ok = 1'b1;
    if (desc_next.ic == 0 || desc_next.ic > 256) desc_ok = 1'b0;
    if (desc_next.oc == 0 || desc_next.oc > 256) desc_ok = 1'b0;
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
    if (desc_next.dst >= NN_BYTES) desc_ok = 1'b0;
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

      // ---- MODE_CPU: 引擎完成 ----
      if (!auto_r) begin
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
      default:        ctl_rdata = 32'h0;
    endcase
  end

endmodule
