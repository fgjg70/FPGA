`timescale 1ns/1ps

// ============================================================================
// nn_subsys.sv — AI 加速子系统顶层: NPU 寄存器 + CPU 数据窗口桥 + 引擎/存储接线
// ----------------------------------------------------------------------------
// 契约: results/ai-accel/CONTRACT.md (这是唯一事实来源)
//   §2 地址映射 / §4 控制寄存器 / §9.1 nn_mem 端口 / §9.2 nn_conv_engine 端口
//
// 结构:
//   mmio ext 总线 ──(只有 0xA000_0100..0x0148)──┐
//   core nn_* 数据窗 ───────────────────────────┤
//                                               ▼
//                                          nn_subsys
//                                          ├─ 描述符寄存器 / status / cycles
//                                          ├─ nn_mem      (大 BRAM: 权重+Q+激活 A/B)
//                                          └─ nn_conv_engine (64 MAC/拍)
//
// 【CPU 数据窗口的相位口径】
//   core 在 MEM 拍给 nn_addr/nn_we, 期望读数据在 WB 拍有效 (与 dmem 完全同口径)。
//   nn_mem 内部是**寄存读** (地址进、下一拍出) —— 所以 cpu_rdata 直接进 core 的
//   nn_rdata 端口, 中间**不能再打一拍**, 否则就变成 MMIO 那种差一拍的错误
//   (PITFALLS R32 族: "结果晚一拍"只在消费者比生产者晚 ≥2 条时才没影响)。
//
// 【busy 期间的 CPU 访问】
//   本核 ext/LSU 都没有 wait-state 机制, 无法让 CPU 停等。所以契约是:
//   NPU busy 时 CPU **不许**碰 NN 窗口; 硬件侧做最保守处理 ——
//     读: 返回 0xDEAD_BEEF (立刻能被软件/断言捕获, 而不是读到陈旧数据)
//     写: 丢弃, 并置 STATUS.err
//   这样软硬件的错误契约会**响** (sticky err), 不会静默。
// ============================================================================

module nn_subsys
  import rv32_pkg::*;
  import nn_pkg::*;
#(
  parameter int unsigned W_BYTES   = NN_W_BYTES,
  parameter int unsigned Q_BYTES   = NN_Q_BYTES,
  // 【v0.3.1】A/B 不等大: A=96KB (128 输入下最大单张量 24ch*64*64 = 98,304B),
  // B=32KB (与残差并存的张量)。两者和仍是 128KB ⇒ 总 BRAM 不变 (A24+B8=32 块)。
  // 见 results/ai-accel/CONTRACT.md §3 与 nn_pkg.sv 的预算注释。
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

  // ---- CPU 数据窗口 (接 core 的 nn_* 端口; 1 拍寄存读) ----
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
  // 1. 描述符寄存器 (软件逐层写, start 拍整体锁存进 desc_r)
  // ==========================================================================
  logic [31:0] r_op, r_src, r_dst, r_woff, r_qoff;
  logic [31:0] r_ih, r_iw, r_ic, r_oc, r_ks, r_st, r_pad, r_flags;
  logic        r_irq_en;
  logic        done_r, err_r;
  logic [7:0]  err_code_r;
  logic [31:0] cycles_r;

  // 当前寄存器拼成的"下一份描述符"
  nn_desc_t desc_next;
  assign desc_next = '{
    op     : r_op[1:0],
    flags  : r_flags[4:0],
    ks     : r_ks[3:0],
    stride : r_st[1:0],
    pad    : r_pad[2:0],   // v0.4: 3 位 (pool K=9 需要 pad=4)
    ih     : r_ih[15:0],
    iw     : r_iw[15:0],
    ic     : r_ic[15:0],
    oc     : r_oc[15:0],
    src    : r_src,
    dst    : r_dst,
    woff   : r_woff,
    qoff   : r_qoff
  };

  // 运行中的描述符 (start 拍锁存)
  nn_desc_t desc_r;

  // ==========================================================================
  // 2. 引擎 / 存储例化
  // ==========================================================================
  logic        eng_start;
  logic        eng_busy, eng_done;
  logic [31:0] eng_cycles;
  logic [7:0]  eng_err;
  logic        eng_w_re;
  logic [23:0] eng_w_addr;
  logic [63:0] eng_w_rdata;
  logic [1:0]  eng_a_sel;
  logic        eng_a_re;
  logic [23:0] eng_a_addr;
  logic [127:0] eng_a_rdata;
  logic [1:0]  eng_b_sel;
  logic        eng_b_we;
  logic [23:0] eng_b_addr;
  logic [63:0] eng_b_wdata;

  logic        cpu_we_g;
  logic [31:0] mem_cpu_rdata;
  logic [31:0] cpu_off;         // NN 窗口内字节偏移 (给 nn_mem)

  assign busy_o    = eng_busy;
  assign done_o    = done_r;
  assign err_o     = err_r;
  assign cycles_o  = cycles_r;
  assign err_code_o= err_code_r;

  // 【关键口径】core 的 nn_addr 是**绝对地址** (0x9004_0000 起),
  // 而 nn_mem 的 cpu_addr 契约是**窗口内字节偏移** (CONTRACT §9.1)。
  // 首版直接把绝对地址接过去 -> nn_mem 判定"≥512KB 越界" -> CPU 对 A/B 的
  // 读写全部静默变成读 0 / 写丢弃。现场表现: yolo_demo 的 input_csum =
  // FNV(49152 个 0) 而没有任何错误码 —— 只有 SoC 集成路径会暴露这个口径错
  // (tb_nn_mem / tb_nn_engine 直接驱动偏移, 所以它们一直是 PASS)。
  assign cpu_off    = cpu_addr - NN_BASE;

  // busy 期间 CPU 一律不许碰 NN 窗口 (见文件头)
  assign cpu_we_g  = cpu_we && !eng_busy;
  assign cpu_rdata = eng_busy ? 32'hDEAD_BEEF : mem_cpu_rdata;

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
    .a_sel     (eng_a_sel),
    .a_re      (eng_a_re),
    .a_addr    (eng_a_addr),
    .a_rdata   (eng_a_rdata),
    .b_sel     (eng_b_sel),
    .b_we      (eng_b_we),
    .b_addr    (eng_b_addr),
    .b_wdata   (eng_b_wdata)
  );

  nn_conv_engine #(
    .OC_LANES (8),
    .PX_LANES (8)
  ) u_eng (
    .clk       (clk),
    .rst       (rst),
    .desc      (desc_r),
    .start     (eng_start),
    .busy      (eng_busy),
    .done      (eng_done),
    .cycles    (eng_cycles),
    .err_code  (eng_err),
    .w_re      (eng_w_re),
    .w_addr    (eng_w_addr),
    .w_rdata   (eng_w_rdata),
    .a_sel     (eng_a_sel),
    .a_re      (eng_a_re),
    .a_addr    (eng_a_addr),
    .a_rdata   (eng_a_rdata),
    .b_sel     (eng_b_sel),
    .b_we      (eng_b_we),
    .b_addr    (eng_b_addr),
    .b_wdata   (eng_b_wdata)
  );

  // ==========================================================================
  // 3. 描述符合法性检查 (start 拍用; 不合法 -> 不启动 + err)
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
        if (desc_next.pad > 3'd2) desc_ok = 1'b0;          // conv: pad <= K/2 <= 2
      end
      NN_OP_POOL: begin
        if (!(desc_next.ks == 4'd2 || desc_next.ks == 4'd3 ||
              desc_next.ks == 4'd5 || desc_next.ks == 4'd9)) desc_ok = 1'b0;
        if (desc_next.pad > 3'd4) desc_ok = 1'b0;          // pool: K=9 时 pad=4 (darknet pad=K/2)
      end
      default: ;
    endcase
    // 缓冲边界 (W/Q/A/B 四个区在窗口内互不重叠, 这里只查"目的张量放得下")
    if (desc_next.dst >= (NN_BYTES)) desc_ok = 1'b0;
  end

  // ==========================================================================
  // 4. 寄存器读写 + 启动/完成/错误握手
  // ==========================================================================
  always @(posedge clk) begin
    if (rst) begin
      r_op <= '0; r_src <= '0; r_dst <= '0; r_woff <= '0; r_qoff <= '0;
      r_ih <= '0; r_iw <= '0; r_ic <= '0; r_oc <= '0;
      r_ks <= '0; r_st <= '0; r_pad <= '0; r_flags <= '0;
      r_irq_en <= 1'b0;
      desc_r   <= '0;
      eng_start<= 1'b0;
      done_r   <= 1'b0;
      err_r    <= 1'b0;
      err_code_r <= 8'h00;
      cycles_r <= 32'd0;
    end
    else begin
      eng_start <= 1'b0;                    // 默认单拍脉冲

      // ---- MMIO 写 ----
      if (ctl_we) begin
        case (ctl_addr)
          MMIO_NN_CTRL: begin
            r_irq_en <= ctl_wdata[1];
            if (ctl_wdata[0]) begin
              if (!eng_busy && desc_ok) begin
                eng_start <= 1'b1;
                desc_r    <= desc_next;
                done_r    <= 1'b0;
                cycles_r  <= 32'd0;
                err_r     <= 1'b0;
                err_code_r<= 8'h00;
              end
              else if (!eng_busy) begin
                err_r      <= 1'b1;
                err_code_r <= 8'hE1;        // 描述符非法
              end
              // busy 时写 start: 忽略 (不打断当前 op)
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

      // ---- MMIO 读: STATUS 读清 done/err ----
      if (ctl_re && (ctl_addr == MMIO_NN_STATUS)) begin
        done_r <= 1'b0;
        err_r  <= 1'b0;
      end

      // ---- busy 期间 CPU 误写 NN 窗口 -> 置 err ----
      // 读不置 err (core 的 LSU 每个 load 都给出地址, 无法可靠区分"读窗口"与
      // "地址落进窗口的无关读"); 读的违反契约由返回值 0xDEADBEEF 直接暴露。
      if (eng_busy && cpu_we) begin
        err_r <= 1'b1;
        err_code_r <= 8'hE2;
      end

      // ---- 引擎完成 ----
      if (eng_done) begin
        done_r   <= 1'b1;
        cycles_r <= eng_cycles;
      end
      if (eng_err != 8'h00) begin
        err_r      <= 1'b1;
        err_code_r <= eng_err;
      end
    end
  end

  // ==========================================================================
  // 5. 组合读 (与 dmem 同口径: 外设式组合读, 由 core 统一寄存一拍)
  // ==========================================================================
  always_comb begin
    ctl_rdata = 32'h0;
    case (ctl_addr)
      MMIO_NN_CTRL:   ctl_rdata = {30'h0, r_irq_en, 1'b0};
      MMIO_NN_STATUS: ctl_rdata = {28'h0, r_irq_en & done_r, err_r, done_r, eng_busy};
      MMIO_NN_CYCLES: ctl_rdata = cycles_r;
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
      MMIO_NN_DBG2:   ctl_rdata = {16'h0, err_code_r};
      default:        ctl_rdata = 32'h0;
    endcase
  end

endmodule
