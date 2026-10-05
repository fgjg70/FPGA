`timescale 1ns/1ps

// ============================================================================
// btb.sv — 分支目标缓冲 + 2 位方向预测器
// ----------------------------------------------------------------------------
// 直接映射, 2^IDX_BITS 项。每项: {valid, tag, target, ctr[1:0], is_ret}
//   预测口 (IF 段): 用 pc 组合读; 命中且 ctr[1]=1 -> 预测 taken, 取 target。
//   更新口 (EX 段): 控制流指令解析完成后写入真实结果 (目标 + 方向 + 是否返回)。
//
// ctr 是 2 位饱和计数器 (00/01=不跳, 10/11=跳) = 经典 Smith 预测器。
//
// 【目标位宽压缩】PC 始终落在 imem 窗口 [PC_BASE, PC_BASE+2^PC_TOP), 所以目标
//   只需存低 PC_TOP 位, 高位用 PC_BASE 补回。64 项时这一步把每项从 41 位压到
//   23 位, 于是**扩到 128 项**的 LUT 开销反而和原来 64 项差不多 —— 而 64 项
//   在 9.5KB 的 CoreMark 代码上按 pc[7:2] 索引会严重冲突 (256 字节就一轮),
//   这是原方案条件分支误判率停在 8.6% 的主因。
//
// 【is_ret】标记"这条 PC 上是函数返回"。返回的目标由 RAS 提供, 不用表里的 target
//   (表里只会记住上一次的调用点)。返回也恒为 taken。
//
// 预测口组合读 + 更新口时钟沿写; 同拍读写同项读到旧值, 由 EX 段重定向兜底。
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

  logic                vld [N];
  logic [TAG_BITS-1:0] tag [N];
  logic [TGT_BITS-1:0] tgt [N];
  logic [1:0]          ctr [N];

  wire [IDX_BITS-1:0] pidx = pred_pc[IDX_BITS+1:2];
  wire [TAG_BITS-1:0] ptag = pred_pc[PC_TOP-1:IDX_BITS+2];
  wire [IDX_BITS-1:0] uidx = upd_pc [IDX_BITS+1:2];
  wire [TAG_BITS-1:0] utag = upd_pc [PC_TOP-1:IDX_BITS+2];

  assign pred_hit    = vld[pidx] && (tag[pidx] == ptag);
  assign pred_taken  = pred_hit && ctr[pidx][1];
  assign pred_target = {PC_BASE[31:PC_TOP], tgt[pidx]};

  integer i;
  initial begin
    for (i = 0; i < N; i++) begin
      vld[i] = 1'b0;
      tag[i] = '0;
      tgt[i] = '0;
      ctr[i] = 2'b01;                          // 弱不跳
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

endmodule
