`timescale 1ns/1ps

// ============================================================================
// btb.sv — 分支目标缓冲 (BTB, 512 项) + 两级流水预测口
// ----------------------------------------------------------------------------
// 【这一版改了什么 / 为什么】
//   旧版 (R1 冻结版): 64 项直接映射, 预测口是**组合查表** —— BTB LUTRAM 读 +
//   tag 比较 + 2 位 Smith/ gshare 方向判定 + 目标 mux, 全部串在
//   core.sv:772 的 `pc_target` 4:1 优先级 mux 前面, 即整条链都在**取指地址路径**上。
//   论文 RVCoreP-32IM (arXiv 2010.16171 §IV.A) 用的是 **两级流水 gshare**:
//   PHT 8192 项 + BTB 512 项, 且预测结果来自寄存器 (官方 ver053 proc.v:426
//   `always @(posedge CLK) r_btb <= w_btb;`、:425 `r_btkn_t <= ...` —— PC mux
//   只挑寄存器输出)。本版就是那个结构, 并且做到**零气泡**:
//
//     T 拍:   p2_pc = "快地址" = pc_flush ? pc_flush_pc : (pc_src ? pc_target : pc_plus4)
//             (**不含 fetch_hold**) -> 只喂 BTB 表读地址
//     T+1 拍: pc == p2_pc(T), q_hit/q_target 已是寄存器输出, q_taken 只多一级
//             2 输入 LUT (q_hit & q_ctr[1]) -> 直接进 core 的 pc_src/pc_target。
//
//   【方向表 (PHT) 的地址不一样】它吃的是 p2_pc_pht = **老的 pc_next** (含 fetch_hold)。
//    为什么见下面【候选 A 的由来】—— 那条"停顿期刷新"必须原样保留。
//
//   为什么 q_taken **不**再打一拍: 若把方向也寄存, 预测就晚于它对应的 PC,
//   每个 taken 分支多 1 拍气泡 (CoreMark 会掉 >1%, 直接违反 C-1 的 ticks 判据)。
//   这是本设计唯一的取舍点: 表读 + tag 比较移出 pc 路径, 但"hit & dir"这 1 级
//   LUT 必须留在 T+1 拍。它只依赖寄存器 (q_vld/q_tag/q_ctr), 与 p2_pc 无组合路径,
//   因此 core 的 pc_next -> p2_pc -> q_* 不构成组合环。
//
// 【容量: 512 项 + 3 位 tag = 无冲突】
//   IDX_BITS=9 -> 索引 = pc[10:2] (9 位); TAG_BITS = PC_TOP-IDX_BITS-2 = 3 位,
//   即 tag = pc[13:11]。两者合起来唯一确定 pc[13:2] —— 16 KB imem 窗口里
//   **每一行指令都有自己的槽位, 直接映射也不会有任何冲突/淘汰**
//   (这正是 512 项搭配 16 KB 窗口的"免费"收益; 老 64 项是 6 位 tag + 6 位索引,
//    同样也是全覆盖, 但只有 64 个槽 -> 冲突)。
//
// 【兼容口 pred_* 为什么恒为 0】
//   两级流水之后, "当拍 pc 进、当拍结果出"在物理上不存在 (8192 项 PHT 不可能
//   组合读)。为了不**悄悄**改变旧端口的时序语义 (Lead 的接口纪律), 旧口保留但
//   输出恒 0 = "不预测": core 若不接线, 所有 taken 分支退回 EX 重定向 ——
//   **功能完全正确, 只是慢**, 绝不会因为读错预测而跑飞。
//   接线: core 接 `.p2_pc(p2_pc_ns)` / `.p2_hold(p2_hold)` / `.p2_pc_pht(pc_next)`
//         / `.q_*(...)` (见报告接线清单)。
//
// 【候选 A 的由来: 一个"看起来等价、其实改了行为"的实测 (必读; 用户要求留轨迹)】
//   最早的方案是"停顿期用 p2_hold 把**整条**预测链 (含 bht 的 ctr_q / idx_d1 / idx_d2 /
//   pcw_d1 / pcw_d2 / ctr_d1) 一起冻结"。**实测它不是逐位等价**:
//       ticks 453,942 -> 454,996 (+0.23%) | 误判 8,020 -> 8,557 | 精度 91.95% -> 91.41%
//   二分: "只冻结、地址不改" = 同样 454,996 ⇒ **与地址无关, 是冻结本身**。
//   逐拍 trace diff 定位到**首个分歧 (可复现锚点): cycle 8283, 停顿中冻结的 PC = 0x80000e6c**
//       8282  pc=0x80000e6c  pred_taken=1  pred_target=0x80000eec   <-- 两边相同
//       8283  参考(老实现) = 0                                       |  整链冻结 = 1
//   根因: 停顿期 **GHR 仍被 EX 里刚解析的控制流推动** (更新口不受停顿影响), 而老实现的
//   查表地址 = 冻结 PC, 于是 **PHT 索引 = 冻结PC ^ 当前GHR** ⇒ 同一个 PC 的方向预测会被
//   用漂移后的 GHR **重算并刷新一次**。这条"停顿期刷新"**是现有 ticks 的组成部分**,
//   任何重构都必须原样保留 —— 这正是"看起来等价的优化其实改了行为"的教科书案例。
//   ⇒ 本版把"冻结"限制在**表项在停顿期不会变**的 BTB 输出寄存器上, 而把方向表 PHT 的读
//     地址直接接老的 pc_next (p2_pc_pht, **bht 一律不冻结**)。
//   复现: python .fpga-cache\pred-eval\run.py frozen hold   (= 逐拍 0 差异, 本版)
//         python .fpga-cache\pred-eval\run.py holdka         (= 旧方案, +537 误判)
//
// 【更新口】逐位与旧版一致 (upd_en/upd_pc/upd_taken/upd_target/upd_is_ret/
//   upd_is_cond), 方向表在 bht.sv。同拍读写同项读到旧值, 由 EX 重定向兜底。
//
// 【候选 A: 停顿期的等价边界 —— 可审计, 不是"trace 没差所以等价"】
//   老实现在停顿拍是「地址保持 + 输出重采样」; 本实现是「快地址照走 + 输出 CE 冻结」。
//   两者只可能在**停顿拍表被写**时不同。逐个来源穷举 (依据 core.sv:486
//   `btb_upd_en = is_ctrl_flow && !hold_mem && !rst && !redir_kill`
//   与 hazard_unit.sv:97-99 `pipe_stall = load_use||lsu_stall||ex_busy`,
//   `hold_mem = lsu_stall||ex_busy`):
//     · load_use_ex : EX 是 load       -> is_ctrl_flow=0  -> btb_upd_en=0   ✅
//     · lsu_stall   : hold_mem=1       -> btb_upd_en=0                       ✅
//     · ex_busy     : hold_mem=1       -> btb_upd_en=0                       ✅
//     · load_use_mem: hold_mem=0       -> EX 若是控制流 -> btb_upd_en=1       ⚠
//   残余窗口 = `load_use_mem` 停顿拍 ∧ EX 是控制流 ∧ uidx==pidx (同一 2KB 窗,
//   IDX=9 ⇒ upd_pc[10:2]==pc[10:2])。此时老实现下一拍会读到**被别名写覆盖**的表项
//   (tag 变成别的分支 ⇒ q_hit 掉 0 / 目标变成别人的), 冻结版保持旧预测。
//   ⇒ 差别**只影响预测, 不影响正确性** (误判由 EX 重定向兜底); 且冻结版在别名情形下
//     其实更"对"(不吃污染)。实测 CoreMark 503,161 拍逐拍 trace **0 差异** ⇒ 未触发。
//   【绝不】为了"可证逐位等价"去门控更新口: load_use_mem 那拍 EX 会前进, 丢一次写
//     就**永久少写一个表项**, 那才是真会改 ticks 的做法。
// ============================================================================

module btb
  import rv32_pkg::*;
#(
  parameter int unsigned IDX_BITS = 9,            // 512 项 (= 论文 BTB 容量)
  parameter int unsigned PC_TOP   = 14,           // imem 16 KB -> pc[13:0]
  parameter logic [31:0] PC_BASE  = IMEM_BASE,
  parameter int unsigned PHT_BITS = 13,           // 方向表 8192 项
  parameter int unsigned GH_BITS  = 13,           // 全局历史位宽 (0 = 纯局部)
  // 【默认值是实测选的, 不是拍脑袋】13 位历史 + 记全部控制流 (+ path history):
  //   GH=13/HIST_ALL=1 + is_cond 标记 -> CoreMark 误判 8020 (91.95%), ticks 453942
  //   对照: 纯局部(GH=0) 8916 / GH=6 12307 / GH=8 9874 / 只记条件分支(HIST_ALL=0) 8525
  //   (13 位不是"越长越好"的结论 —— 短历史在本核**陈旧 GHR**下反而更差, 见报告)
  parameter bit          HIST_ALL_CTRL = 1'b1     // 1 = JAL/JALR 也进历史; 透传给 bht
)(
  input  logic        clk,
  input  logic        rst,

  // ---- [A] 兼容口 (旧语义 = 当拍组合查表)。本实现恒为"不预测", 见文件头 ----
  input  logic [31:0] pred_pc,
  output logic        pred_hit,
  output logic        pred_taken,
  output logic [31:0] pred_target,
  output logic        pred_is_ret,

  // ---- [B] 两级流水预测口 (新增, 默认有效) ----
  //   p2_pc     = 下一拍要取的 PC **不含停顿项** (= pc_flush ? pc_flush_pc : pc_src ? pc_target : pc_plus4)
  //               -> 只喂 BTB 表读地址 (表项在停顿期不会变, 输出用 CE 冻结即可)
  //   p2_pc_pht = **老的 `pc_next`** (含停顿项) -> 只喂方向表 PHT 的读地址
  //               为什么 PHT 必须用老地址: 停顿期 GHR 会继续漂移, 老实现的预测会被
  //               用新历史"刷新"一次; 这条行为是 ticks 的一部分 (见报告: 首个分歧在
  //               cycle 8283, 冻结整条链会让 8020 -> 8557 次误判)。
  //               它只落在 BRAM 地址建立上 (不是 LUTRAM 读 + mux + FF 的 D 端) -> 不进关键路径。
  //   p2_hold   = 下一拍 pc 不前进 (= fetch_hold && !pc_flush) -> 冻结 BTB 输出寄存器
  input  logic [31:0] p2_pc,
  input  logic [31:0] p2_pc_pht,
  input  logic        p2_hold,
  output logic        q_hit,
  output logic        q_taken,
  output logic [31:0] q_target,
  output logic        q_is_ret,

  // ---- 更新口 (EX 段, 与旧版逐位一致) ----
  input  logic        upd_en,
  input  logic [31:0] upd_pc,
  input  logic        upd_taken,
  input  logic [31:0] upd_target,
  input  logic        upd_is_ret,
  input  logic        upd_is_cond,

  output logic [15:0] align_err_cnt       // 透传 bht 的对齐自证 (必须恒 0)
);

  localparam int unsigned N        = 1 << IDX_BITS;
  localparam int unsigned TAG_BITS = PC_TOP - IDX_BITS - 2;
  localparam int unsigned TGT_BITS = PC_TOP;

  // ---- 表项数组: 具名 unpacked 数组 (tb_sw 层次化读 vld/tag/is_ret, 不能改打包) ----
  logic                vld [N];
  logic [TAG_BITS-1:0] tag [N];
  logic [TGT_BITS-1:0] tgt [N];
  logic                is_ret [N];
  // 【这条 PC 上是不是"条件分支"】方向表 (PHT) 只对条件分支有意义:
  //   JAL/JALR 的方向恒为 taken, 若也去查一个冷计数器 (初值 01 = 弱不跳),
  //   第一次(以及每个新历史上下文)都会预测"不跳" -> 白送误判。
  //   实测: GH=13/HIST_ALL 时 JAL 误判 661 (纯局部模式只有 199) —— 就是被冷
  //   计数器坑的。存 1 位标记后, 非条件分支直接按 taken 预测 (目标仍取自 BTB)。
  //   标记用现成的 upd_is_cond 写, **不需要新端口**。
  logic                is_cond [N];

  // ---- 更新口索引/标签 ----
  wire [IDX_BITS-1:0] uidx = upd_pc[IDX_BITS+1:2];
  wire [TAG_BITS-1:0] utag = upd_pc[PC_TOP-1:IDX_BITS+2];

  // ---- 预测读地址 (p2_pc = 下一拍要取的 PC) ----
  wire [IDX_BITS-1:0] pidx = p2_pc[IDX_BITS+1:2];
  wire [TAG_BITS-1:0] ptag = p2_pc[PC_TOP-1:IDX_BITS+2];

  // ---- 一级流水寄存 (T 拍组合读 -> T+1 拍输出) ----
  logic                q_vld, q_isret_r, q_cond_r;
  logic [TAG_BITS-1:0] q_tag, q_tagexp;
  logic [TGT_BITS-1:0] q_tgt;

  // ---- 方向: 独立 PHT (bht.sv) ----
  logic [1:0] q_ctr;

  // ---- 方向 (PHT) 的读地址 ----
  //   直接用 core 传进来的**老 pc_next** (含停顿项): 停顿期 GHR 漂移引起的"刷新"
  //   必须保留才能 ticks 逐位不变。它只影响 BRAM 地址建立, 不影响 BTB 的 LUTRAM 读。
  wire [31:0] pht_pc = p2_pc_pht;

  bht #(.IDX_BITS(PHT_BITS), .GH_BITS(GH_BITS), .PC_TOP(PC_TOP),
        .HIST_ALL_CTRL(HIST_ALL_CTRL)) u_bht (
    .clk          (clk),
    .rst          (rst),
    .pred_pc      (pht_pc),
    .ctr_q        (q_ctr),
    .upd_en       (upd_en),
    .upd_pc       (upd_pc),
    .upd_taken    (upd_taken),
    .upd_is_cond  (upd_is_cond),
    .align_err_cnt(align_err_cnt)
  );

  // 命中要求 vld && tag —— 这条不变量与旧版一致 (fmax 论证里用到过)
  assign q_hit    = q_vld && (q_tag == q_tagexp);
  assign q_target = {PC_BASE[31:PC_TOP], q_tgt};
  assign q_is_ret = q_hit && q_isret_r;
  // 方向: 条件分支查 PHT (gshare); JAL/JALR 恒 taken。
  // q_ctr 与 q_* 同拍 (都是 T 拍地址打一拍的结果); 这 1~2 级 LUT 是零气泡的代价
  assign q_taken  = q_hit && (q_cond_r ? q_ctr[1] : 1'b1);

  // 兼容口: 恒"不预测" (见文件头)。功能正确性由 EX 重定向保证。
  assign pred_hit    = 1'b0;
  assign pred_taken  = 1'b0;
  assign pred_target = 32'd0;
  assign pred_is_ret = 1'b0;

  integer i;
  initial begin
    for (i = 0; i < N; i = i + 1) begin
      vld[i]    = 1'b0;
      tag[i]    = '0;
      tgt[i]    = '0;
      is_ret[i] = 1'b0;
      is_cond[i] = 1'b0;
    end
`ifndef SYNTHESIS
    // 自证: "改了没生效"和"算法没用"必须能分开 (PITFALLS R17 的教训)
    $display("[btb] 2-STAGE gshare ACTIVE: BTB=%0d (IDX=%0d TAG=%0d) PHT=%0d GH=%0d HIST_ALL=%0d",
             N, IDX_BITS, TAG_BITS, (1 << PHT_BITS), GH_BITS, HIST_ALL_CTRL);
    $display("[btb] legacy pred_* ports tied to NO-PREDICTION; wire p2_pc/q_* instead");
`endif
  end

  always @(posedge clk) begin
    if (rst) begin
      q_vld     <= 1'b0;
      q_isret_r <= 1'b0;
      q_cond_r  <= 1'b0;
      q_tag     <= '0;
      q_tagexp  <= '0;
      q_tgt     <= '0;
    end
    else begin
      // 更新口 (EX): 命中判定用的 tag 与目标一起写
      if (upd_en) begin
        vld[uidx]    <= 1'b1;
        tag[uidx]    <= utag;
        tgt[uidx]    <= upd_target[PC_TOP-1:0];
        is_ret[uidx] <= upd_is_ret;
        is_cond[uidx]<= upd_is_cond;
      end
      // 预测口: 组合读(地址=p2_pc 的索引) + 打一拍 -> 下一拍正好配 pc
      // 【候选 A】停顿期用 CE 冻结**整条预测链**: 此时 p2_pc 已经不含 fetch_hold,
      //   查出来的是"另一条指令"的表项, 必须丢弃; 而 pc 冻着, q_*(T) 已对应 pc(T),
      //   保持即等价 (详见 btb.sv 文件头与相位归纳)。
      if (!p2_hold) begin
        q_vld     <= vld[pidx];
        q_tag     <= tag[pidx];
        q_tagexp  <= ptag;
        q_tgt     <= tgt[pidx];
        q_isret_r <= is_ret[pidx];
        q_cond_r  <= is_cond[pidx];
      end
    end
  end

endmodule
