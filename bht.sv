`timescale 1ns/1ps

// ============================================================================
// bht.sv — 方向预测表 (PHT): 8192 项 × 2 位饱和计数器
// ----------------------------------------------------------------------------
// 【为什么是 8192 项】论文 RVCoreP-32IM (arXiv 2010.16171 §IV.A):
//   "two-stage pipeline gshare branch prediction with a pattern history table
//    (PHT) of 8,192 entries and a BTB of 512 entries."
//   本工程 P4 那次 gshare 失败 (精度 89% -> 74%) 的真因**不是 gshare 方法错**,
//   而是把 6 位历史异或进了 **64 项**表: 同一个分支被摊到 2^6 个计数器上,
//   每个都学不到 (results/p4-gshare.md 的"冷却效应")。表容量是根因。
//
// 【索引】idx = PC[IDX_BITS:1] ^ (GHR & GH_MASK)
//   · 从 bit1 起取 13 位而不是 [IDX_BITS+1:2]: 本核 imem 只有 16 KB
//     (pc[13:0] = 4096 条指令), 13 位索引若从 bit2 起就只有 12 位有效 PC,
//     8192 项里有一半永远读不到。从 bit1 起取, 再与历史异或 -> 8192 项全可达。
//   · GH_BITS=0 退化成"纯局部 2 位"(按 PC 索引); 这是给论文配置留的对照组。
//
// 【两级流水的两个关键点】
//   ① 读地址提前一拍: 地址在 T 拍给出 (= core 的 pc_next = "下一拍要取的 PC"),
//      T+1 拍 ctr_q 有效, 正好配 T+1 拍的 pc。1 拍读延迟被完全吸收 -> 0 气泡。
//      BRAM 必须寄存读 (PITFALLS 三.11: 组合读推不出 BRAM), 这里正好是寄存读。
//   ② 写回索引随流水带 2 拍: 同一条指令要到 T+2 拍进 EX 才解析出真实方向。
//      P4 的实现是那时用**当前** GHR 重算索引 —— 写回的计数器根本不是预测时
//      读的那一个, 学习永远对不上 (这也是 P4 看起来"gshare 没用"的原因之一)。
//      本实现把读索引 idx_d1/idx_d2 带下来, 写回与预测**逐位同一个索引**。
//      索引链长 2 拍的原因: pc(T+1) 的索引在 T 拍形成, 它在 T+1 拍进 ID、
//      T+2 拍进 EX (core 的 ID/EX 在 pc 那一拍就锁存), 所以 2 拍。
//   ③ pcw_d2/align_bad 是**自证**: 若 2 拍前查表的 PC 不等于此刻 EX 的 PC,
//      说明对齐假设被破坏 (例如流水线结构改了), 这时退回"当前 GHR 重算"并把
//      计数打到 align_err_cnt —— 避免静默地写错计数器。正常必须恒 0。
//
// 【复位策略】(本工程对 initial 敏感, 见 PITFALLS 语法章 vopt-7061)
//   PHT 必须落 BRAM 才省 LUT (8192×2 用分布式 RAM 要 ~500 LUT), 而 BRAM 整块
//   无法同步复位。所以:
//     · 内容用 **initial** 初始化 (Vivado/ModelSim 都支持 BRAM 初值);
//     · 初值 2'b01 = 弱不跳, 与旧 Smith 一致 -> 首次遇到的分支预测"不跳";
//     · mem **只被 `always` 驱动, 绝不用 `always_ff`** (vopt-7061: initial 与
//       always_ff 同驱动一个变量是 LRM 违规);
//     · rst 只复位流水/自检寄存器, 不复位 mem —— 复位后 2 拍内索引链就干净,
//       而复位期 (boot_done=0) 根本不会有 upd_en, 所以不需要清表。
//
// 【面积】8192×2 bit = 16 Kb = **1 块 RAMB18** (8K×2 正好是 RAMB18 的原生形状)。
// ============================================================================

module bht
  import rv32_pkg::*;
#(
  parameter int unsigned IDX_BITS = 13,       // 8192 项 (= 论文 PHT 容量)
  parameter int unsigned GH_BITS  = 13,       // 全局历史有效位宽, 0..IDX_BITS
  parameter int unsigned PC_TOP   = 14,       // imem 窗口位宽 (pc[PC_TOP-1:0])
  parameter bit          HIST_ALL_CTRL = 1'b1 // 1 = JAL/JALR 也进历史 (实测更好, 见 btb.sv)
)(
  input  logic        clk,
  input  logic        rst,

  // 预测读口: T 拍给地址 (core 的 pc_next); T+1 拍 ctr_q 有效
  input  logic [31:0] pred_pc,
  output logic [1:0]  ctr_q,

  // 更新口 (EX 段; 与 btb 更新口同拍)
  input  logic        upd_en,
  input  logic [31:0] upd_pc,
  input  logic        upd_taken,
  input  logic        upd_is_cond,

  output logic [15:0] align_err_cnt       // 自证: 索引/PC 对齐错次数, 必须恒 0
);

  localparam int unsigned N      = 1 << IDX_BITS;
  localparam int unsigned PW     = PC_TOP - 2;                 // pc[PC_TOP-1:2]
  // 历史掩码: 0 位 -> 0, IDX_BITS 位 -> 全 1。用"右移"构造, 避免 {0{1'b0}} 这种
  // 零次复制 (Verilog 不允许, 而 GH_BITS==IDX_BITS 时零次复制一定会出现)。
  localparam logic [IDX_BITS-1:0] GH_MASK =
      (GH_BITS >= IDX_BITS) ? {IDX_BITS{1'b1}}
                            : ({IDX_BITS{1'b1}} >> (IDX_BITS - GH_BITS));

  // ---- PHT: 8192 × 2 位饱和计数器 (BRAM, 寄存读) ----
  (* ram_style = "block" *) logic [1:0] mem [N];

  // ---- 全局历史寄存器 (GHR) ----
  logic [IDX_BITS-1:0] ghr;                  // 恒 IDX_BITS 位宽, 索引时按 GH_MASK 截取

  // ---- 读索引 (组合, 地址路径) ----
  wire [IDX_BITS-1:0] rd_idx = pred_pc[IDX_BITS:1] ^ (ghr & GH_MASK);
  wire [PW-1:0]       pc_w   = pred_pc[PC_TOP-1:2];

  // ---- 写回索引: 随流水带 2 拍 ----
  logic [IDX_BITS-1:0] idx_d1, idx_d2;
  logic [PW-1:0]       pcw_d1, pcw_d2;
  logic [1:0]          ctr_d1;               // 读到的计数器带 1 拍 (读口已含 1 拍)

  wire                 align_bad = (pcw_d2 != upd_pc[PC_TOP-1:2]);
  wire [IDX_BITS-1:0]  wr_idx    = align_bad ? (upd_pc[IDX_BITS:1] ^ (ghr & GH_MASK))
                                             : idx_d2;

  // 2 位饱和计数器 (到边界保持, 不环绕)
  wire [1:0] ctr_new = upd_taken ? ((ctr_d1 == 2'b11) ? 2'b11 : ctr_d1 + 2'b01)
                                 : ((ctr_d1 == 2'b00) ? 2'b00 : ctr_d1 - 2'b01);

  integer i;
  initial begin
    for (i = 0; i < N; i = i + 1) mem[i] = 2'b01;      // 弱不跳
  end

  always @(posedge clk) begin
    if (rst) begin
      ctr_q         <= 2'b01;
      ghr           <= '0;
      idx_d1        <= '0;
      idx_d2        <= '0;
      pcw_d1        <= '0;
      pcw_d2        <= '0;
      ctr_d1        <= 2'b01;
      align_err_cnt <= 16'd0;
    end
    else begin
      // 写口 (T+2 拍 = 该指令在 EX): 用 2 拍前的**读索引**, 不用当前 GHR 重算
      if (upd_en) mem[wr_idx] <= ctr_new;
      // 读口 (T 拍地址 -> T+1 拍数据)。同拍读写同址读到旧值 (read-first),
      // 由 EX 段重定向兜底, 与旧设计逐位同策略。
      ctr_q <= mem[rd_idx];

      // 索引/计数器/PC 一起随流水走
      idx_d1 <= rd_idx;      idx_d2 <= idx_d1;
      pcw_d1 <= pc_w;        pcw_d2 <= pcw_d1;
      ctr_d1 <= ctr_q;

      if (upd_en) begin
        // 【历史记什么】默认只记条件分支 (教科书 gshare)。
        // P4 曾测"只记条件分支更差", 但那是在**写回索引算错**的前提下测的,
        // 结论不可用; 本次用 HIST_ALL_CTRL 参数重测 (见报告)。
        if (HIST_ALL_CTRL || upd_is_cond)
          ghr <= {ghr[IDX_BITS-2:0], upd_taken};

        if (align_bad) begin
          align_err_cnt <= align_err_cnt + 16'd1;
`ifndef SYNTHESIS
          if (align_err_cnt < 16'd4)
            $display("[bht] ALIGN MISMATCH: carried PC=0x%08x vs EX pc=0x%08x (t=%0t)",
                     {pcw_d2, 2'b00}, upd_pc, $time);
`endif
        end
      end
    end
  end

endmodule
