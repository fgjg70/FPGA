`timescale 1ns/1ps

// ============================================================================
// btb.sv — 分支目标缓冲 + 方向预测器
// ----------------------------------------------------------------------------
// 直接映射, 2^IDX_BITS 项。每项: {valid, tag, target, ctr[1:0]}
//   预测口 (IF 段): 由 pc 组合读, 命中且方向说 taken -> 预测 taken, 取 target。
//   更新口 (EX 段): 控制流指令解析完成后写入真实结果 (目标 + 方向)。
//
// 方向预测器有两种实现, 由 BTB_GSHARE 宏选择:
//
//   (a) 不定义 BTB_GSHARE —— 纯局部 2 位 Smith
//       方向计数器索引 == 表项索引。简单、面积小。
//
//   (b) 定义 BTB_GSHARE —— gshare (P4 优化, 默认开启)
//       方向计数器索引 = 表项索引 ^ 全局分支历史 GHR。
//       **这是实测选出来的方向, 不是拍脑袋**:
//       把条件分支的误判拆开量过 (tb_sw 里层次化读本模块的阵列, 纯观测):
//         条件分支总数 = 70135
//         BTB 有表项   = 67457 (96%)     <-- 表命中率很高, 容量不是问题
//         条件分支误判 =  6055
//           其中 无表项(容量/冲突) = 1185 (19%)
//           其中 有表项但方向判反  = 4870 (80%)   <-- 真正的主因
//       即 **96% 的分支在表里, 80% 的误判是方向预测错了**。
//       所以扩 BTB / 改组相联收益很小, 该改的是方向预测器。
//       (本文件旧注释曾断言"64 项冲突是误判主因" —— 已被上面这组实测推翻,
//        见 skills/fpga-riscv-a100t/PITFALLS.md R16。)
//
// 【gshare 的一个关键细节】表项查找 (vld/tag) **仍用纯 pidx**, 只有方向计数器
// 异或 GHR。若连 tag 索引也异或历史, 同一个分支在不同历史下会落到不同表项,
// 互相踢掉, 命中率反而崩。
//
// 【目标位宽压缩】PC 始终落在 imem 窗口 [PC_BASE, PC_BASE+2^PC_TOP), 所以目标
//   只需存低 PC_TOP 位, 高位由 PC_BASE 补回。64 项时这一步把每项从 41 位压到
//   23 位, 于是**扩到 128 项的 LUT 开销反而和原来 64 项差不多**。
//
// 预测口组合读 + 更新口时钟沿写: 同拍读写同项读到旧值, 由 EX 段重定向兜底。
// ============================================================================

module btb
  import rv32_pkg::*;
#(
  parameter int unsigned    IDX_BITS = 6,          // 64 项
  parameter int unsigned    PC_TOP   = 14,         // imem 16KB -> pc[13:0] 可变
  parameter logic [31:0]    PC_BASE  = IMEM_BASE
)(
  input  logic        clk,
  input  logic        rst,

  // 预测口 (IF 段, 组合读)
  input  logic [31:0] pred_pc,
  output logic        pred_hit,
  output logic        pred_taken,
  output logic [31:0] pred_target,

  // 更新口 (EX 段)
  input  logic        upd_en,
  input  logic [31:0] upd_pc,
  input  logic        upd_taken,
  input  logic [31:0] upd_target
);

  localparam int unsigned N        = 1 << IDX_BITS;
  localparam int unsigned TAG_BITS = PC_TOP - IDX_BITS - 2;
  localparam int unsigned TGT_BITS = PC_TOP;

  // ---- 表项数组 (两种模式共用) ----
  logic                vld [N];
  logic [TAG_BITS-1:0] tag [N];
  logic [TGT_BITS-1:0] tgt [N];

  // ---- 索引/标签 (声明必须在使用之前) ----
  wire [IDX_BITS-1:0] pidx = pred_pc[IDX_BITS+1:2];
  wire [TAG_BITS-1:0] ptag = pred_pc[PC_TOP-1:IDX_BITS+2];
  wire [IDX_BITS-1:0] uidx = upd_pc [IDX_BITS+1:2];
  wire [TAG_BITS-1:0] utag = upd_pc [PC_TOP-1:IDX_BITS+2];

  // 表项命中: 始终用纯 pidx (理由见文件头)
  assign pred_hit    = vld[pidx] && (tag[pidx] == ptag);
  assign pred_target = {PC_BASE[31:PC_TOP], tgt[pidx]};

  integer i;

`ifdef BTB_GSHARE
  // ========================================================================
  // gshare: 方向计数器索引 = 表项索引 ^ 全局分支历史
  // ========================================================================
  localparam int unsigned GH_BITS = IDX_BITS;

  logic [GH_BITS-1:0] ghr;                        // 全局分支历史 (最近的方向)
  logic [1:0]         dctr [N];                   // 方向计数器表

  wire [IDX_BITS-1:0] p_dir_idx = pidx ^ ghr;
  wire [IDX_BITS-1:0] u_dir_idx = uidx ^ ghr;

  assign pred_taken = pred_hit && dctr[p_dir_idx][1];

  initial begin
    for (i = 0; i < N; i++) begin
      vld[i]  = 1'b0;
      tag[i]  = '0;
      tgt[i]  = '0;
      dctr[i] = 2'b01;                            // 弱不跳
    end
    ghr = '0;
    // 一次性自证: 确认这个宏真的生效了 (否则"gshare 没效果"会被误判成算法无用,
    // 而实际是宏没定义 —— 这类"改了半天没生效"必须有自证手段)
    $display("[btb] GSHARE direction predictor ACTIVE (GH_BITS=%0d, N=%0d)", GH_BITS, N);
  end

  always @(posedge clk) begin
    if (rst) begin
      for (i = 0; i < N; i++) vld[i] <= 1'b0;
      ghr <= '0;
    end
    else if (upd_en) begin
      vld[uidx] <= 1'b1;
      tag[uidx] <= utag;
      tgt[uidx] <= upd_target[PC_TOP-1:0];
      // 饱和计数器: 到边界就保持, 不环绕
      if (dctr[u_dir_idx] == 2'b11 && upd_taken)
        dctr[u_dir_idx] <= 2'b11;
      else if (dctr[u_dir_idx] == 2'b00 && !upd_taken)
        dctr[u_dir_idx] <= 2'b00;
      else
        dctr[u_dir_idx] <= upd_taken ? dctr[u_dir_idx] + 2'b01
                                     : dctr[u_dir_idx] - 2'b01;
      ghr <= {ghr[GH_BITS-2:0], upd_taken};
    end
  end

`else
  // ========================================================================
  // 纯局部 2 位 Smith: 方向计数器索引 == 表项索引
  // ========================================================================
  logic [1:0] ctr [N];

  assign pred_taken = pred_hit && ctr[pidx][1];

  initial begin
    for (i = 0; i < N; i++) begin
      vld[i] = 1'b0;
      tag[i] = '0;
      tgt[i] = '0;
      ctr[i] = 2'b01;                            // 弱不跳
    end
  end

  always @(posedge clk) begin
    if (rst) begin
      for (i = 0; i < N; i++) vld[i] <= 1'b0;
    end
    else if (upd_en) begin
      vld[uidx] <= 1'b1;
      tag[uidx] <= utag;
      tgt[uidx] <= upd_target[PC_TOP-1:0];
      if (vld[uidx] && (tag[uidx] == utag)) begin
        if (upd_taken) ctr[uidx] <= (ctr[uidx] == 2'b11) ? 2'b11 : ctr[uidx] + 2'b01;
        else           ctr[uidx] <= (ctr[uidx] == 2'b00) ? 2'b00 : ctr[uidx] - 2'b01;
      end
      else begin
        ctr[uidx] <= upd_taken ? 2'b10 : 2'b01;
      end
    end
  end

`endif

endmodule
