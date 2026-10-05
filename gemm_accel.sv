`timescale 1ns/1ps

// ============================================================================
// gemm_accel.sv — int8 矩阵乘加加速单元 (AI 应用场景的硬件加速)
// ----------------------------------------------------------------------------
// 算 C = A x B, int8 输入 / int32 累加, 尺寸软件可配 (M/K/N)。
//
// 【为什么是 GEMM】神经网络推理里耗时占比绝对主导的算子 (全连接是它, 卷积
//   im2col 化之后也是它)。加速它最能支撑"AI 模型性能"这一评分维度。
//
// 【为什么用本地缓冲】本核 dmem 只有**一个读口且被 CPU 的 LSU 独占**:
//     · 加速单元若直接读 dmem, 就要和 CPU 争口;
//     · 单口意味着每拍最多取一个操作数 -> 并行度被访存带宽卡死;
//     · 结果写回还需要写口。
//   所以本单元自带片上缓冲 (A/B/C), CPU 用 MMIO 把数据推入、算完读出来。
//   好处: **零访存冲突, 不动已经上板验证过的 CPU/存储子系统**, 且能独立验证。
//   代价: 软件要搬运数据, 这部分开销必须算进加速比 (软件会如实统计)。
//
// 【本版并行度: 1 MAC/拍】先把**接口、时序、正确性**做扎实。
//   扩展路径 (见 results/p5-ai-accelerator.md): 一次读 A 的一行 + B 的一列
//   打进寄存器组, 就能开 PAR 路并行。DSP 余量充足 (当前 8/240), 但本单元
//   故意**不用 DSP** —— int8xint8 的乘法器很小, 综合落成 LUT 即可, 这样也
//   不会去挤乘法路径的时序预算。
//
// 【缓冲窗口】PkgMode 的 arena 从 MMIO_GEMM_ARENA 起 2KB, 按字访问:
//     +0x000 .. +0x0FF   A[64]  字   (256 个 int8, 16x16 行主序)
//     +0x100 .. +0x1FF   B[64]  字
//     +0x200 .. +0x5FF   C[256] 字   (256 个 int32)
//   窗口用 addr[31:11] 译码 (2KB 对齐), 区域用 addr[9:2] 划分。
//
// 【正确性约定】累加器 32 位; int8 x int8 每项最多 2^14, K <= 2^17 不溢出,
//   对本项目规模绰绰有余。
// ============================================================================

module gemm_accel
  import rv32_pkg::*;
#(
  parameter int unsigned MAXD = 32,
  parameter int unsigned AW   = 64,
  parameter int unsigned BW   = 64,
  parameter int unsigned CW   = 256
)(
  input  logic        clk,
  input  logic        rst,

  input  logic        sel,
  input  logic        we,
  input  logic        re,
  input  logic [31:0] addr,
  input  logic [3:0]  wstrb,
  input  logic [31:0] wdata,
  output logic [31:0] rdata,

  output logic        busy,
  output logic        irq
);

  // 2KB 对齐的缓冲窗口; 窗口内字偏移用 addr[9:2]
  wire        in_arena = (addr[31:11] == MMIO_GEMM_ARENA[31:11]);
  wire [7:0]  aoff     = addr[9:2];

  wire is_A = in_arena && (aoff < 8'd64);
  wire is_B = in_arena && (aoff >= 8'd64)  && (aoff < 8'd128);
  wire is_C = in_arena && (aoff >= 8'd128);

  logic [31:0] r_m, r_k, r_n;
  logic        r_irq_en;
  logic        done_r;
  logic [31:0] cycles_r;

  logic [31:0] a_buf [AW];
  logic [31:0] b_buf [BW];
  logic [31:0] c_buf [CW];

  typedef enum logic [1:0] { S_IDLE, S_CLEAR, S_MAC, S_STORE } state_e;
  state_e st;
  logic [31:0] i_idx, j_idx, k_idx;
  logic signed [31:0] acc;

  assign busy = (st != S_IDLE);

  // ---- 组合取操作数 (A[i][k] / B[k][j], 按字节寻址, 小端字内布局) ----
  wire [31:0] a_byte_idx = i_idx * r_k + k_idx;
  wire [31:0] b_byte_idx = k_idx * r_n + j_idx;

  logic signed [7:0] a_val, b_val;
  always_comb begin
    case (a_byte_idx[1:0])
      2'd0:    a_val = a_buf[a_byte_idx[7:2]][7:0];
      2'd1:    a_val = a_buf[a_byte_idx[7:2]][15:8];
      2'd2:    a_val = a_buf[a_byte_idx[7:2]][23:16];
      default: a_val = a_buf[a_byte_idx[7:2]][31:24];
    endcase
    case (b_byte_idx[1:0])
      2'd0:    b_val = b_buf[b_byte_idx[7:2]][7:0];
      2'd1:    b_val = b_buf[b_byte_idx[7:2]][15:8];
      2'd2:    b_val = b_buf[b_byte_idx[7:2]][23:16];
      default: b_val = b_buf[b_byte_idx[7:2]][31:24];
    endcase
  end

  // ---- 读数据 ----
  always_comb begin
    rdata = 32'h0;
    if (sel && re) begin
      if      (addr == MMIO_GEMM_STATUS) rdata = {30'h0, done_r, busy};
      else if (addr == MMIO_GEMM_M)      rdata = r_m;
      else if (addr == MMIO_GEMM_K)      rdata = r_k;
      else if (addr == MMIO_GEMM_N)      rdata = r_n;
      else if (addr == MMIO_GEMM_CYCLES) rdata = cycles_r;
      else if (is_C)                     rdata = c_buf[aoff - 8'd128];
      else if (is_A)                     rdata = a_buf[aoff];
      else if (is_B)                     rdata = b_buf[aoff - 8'd64];
    end
  end

  assign irq = done_r && r_irq_en;

  // ---- 写 + 运算 ----
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      st       <= S_IDLE;
      r_m      <= '0;
      r_k      <= '0;
      r_n      <= '0;
      r_irq_en <= 1'b0;
      done_r   <= 1'b0;
      cycles_r <= '0;
      i_idx    <= '0;
      j_idx    <= '0;
      k_idx    <= '0;
      acc      <= '0;
    end
    else begin
      if (sel && we) begin
        if (addr == MMIO_GEMM_CTRL) begin
          r_irq_en <= wdata[1];
          // start: 只在 IDLE 受理, 且参数必须合法 —— 否则状态机会被搅乱。
          // (m*k)、(k*n)、(m*n) 都受缓冲容量约束, 越界就是软件 bug, 直接拒绝。
          if (wdata[0] && st == S_IDLE &&
              r_m != 0 && r_k != 0 && r_n != 0 &&
              r_m <= MAXD[31:0] && r_k <= MAXD[31:0] && r_n <= MAXD[31:0] &&
              (r_m * r_k) <= 32'd256 && (r_k * r_n) <= 32'd256 && (r_m * r_n) <= 32'd256) begin
            st       <= S_CLEAR;
            i_idx    <= '0;
            j_idx    <= '0;
            k_idx    <= '0;
            acc      <= '0;
            done_r   <= 1'b0;
            cycles_r <= '0;
          end
        end
        else if (addr == MMIO_GEMM_M) r_m <= wdata;
        else if (addr == MMIO_GEMM_K) r_k <= wdata;
        else if (addr == MMIO_GEMM_N) r_n <= wdata;
        else if (is_A) begin
          if (wstrb[0]) a_buf[aoff][7:0]   <= wdata[7:0];
          if (wstrb[1]) a_buf[aoff][15:8]  <= wdata[15:8];
          if (wstrb[2]) a_buf[aoff][23:16] <= wdata[23:16];
          if (wstrb[3]) a_buf[aoff][31:24] <= wdata[31:24];
        end
        else if (is_B) begin
          if (wstrb[0]) b_buf[aoff - 8'd64][7:0]   <= wdata[7:0];
          if (wstrb[1]) b_buf[aoff - 8'd64][15:8]  <= wdata[15:8];
          if (wstrb[2]) b_buf[aoff - 8'd64][23:16] <= wdata[23:16];
          if (wstrb[3]) b_buf[aoff - 8'd64][31:24] <= wdata[31:24];
        end
      end
      // 读 STATUS 清 done
      if (sel && re && addr == MMIO_GEMM_STATUS) done_r <= 1'b0;

      case (st)
        S_IDLE: ;
        S_CLEAR: begin
          acc   <= '0;
          k_idx <= '0;
          st    <= S_MAC;
        end
        S_MAC: begin
          // acc 在 S_CLEAR 已清零, 所以这里可以无条件累加
          acc <= acc + ($signed(a_val) * $signed(b_val));
          if (k_idx + 1 < r_k) k_idx <= k_idx + 1;
          else                 st    <= S_STORE;
        end
        S_STORE: begin
          c_buf[i_idx * r_n + j_idx] <= acc;
          if (j_idx + 1 < r_n) begin
            j_idx <= j_idx + 1;
            st    <= S_CLEAR;
          end
          else begin
            j_idx <= '0;
            if (i_idx + 1 < r_m) begin
              i_idx <= i_idx + 1;
              st    <= S_CLEAR;
            end
            else begin
              st     <= S_IDLE;
              done_r <= 1'b1;
            end
          end
        end
        default: st <= S_IDLE;
      endcase

      if (busy) cycles_r <= cycles_r + 1'b1;
    end
  end

endmodule
