`timescale 1ns/1ps

// ============================================================================
// nn_seq.sv — 微码序列器（v0.7 autonomous + v1 job + M6c band/streaming）
// ----------------------------------------------------------------------------
// 契约: results/ai-accel/CONTRACT.md §12 / results/ai-accel/SPEC-SPECIALIZED.md
// 作用: 从 `nn_rom_pkg::NN_ROM` 顺序取 op 项, 翻译成 `nn_conv_engine` 描述符并启动,
//       等引擎 done 后继续; 全部跑完置 done。CPU 只写一次 start（MODE_AUTO/job）。
//
// legacy 状态机 (rom.tile[7:4]==0, e.g. YOLO 112-op、瓶盖 op0 单张量):
//   IDLE --start--> FETCH -> ISSUE -> WAIT --eng_done--> NEXT -> FETCH / DONE
//
// 【v1 · S1 Job 模式（task-13）】job 级看门狗 + done_ops 只读输出。
//
// 【v1 · M6c Band 模式（task-17）】rom.tile[1]=band_en==1 的 op 走 band/流式路径:
//   per op:
//     - 若本 op 权重尚未预取 → S_PRE0: 发 pre_start 把本层 W/Q 预取到 nn_mem 非活动
//       bank; 等 pre_done 后翻转 bank、w_ptr/q_ptr += wlen/qlen。
//     - 首个 band 发出 **下一 op 的 pre_start**（重叠预取）; op 结束时 S_PRE_END 等
//       pre_done、翻转 bank、指针累加。
//   per band (M4-TILECACHE.md 附录 A):
//     out_r0 = b*band_rows; br = min(band_rows, oh-out_r0);
//     in_rows = (br-1)*stride + k; band_row0 = out_r0*stride - pad;
//     rd0 = max(band_row0,0); rd1 = min(band_row0+in_rows, ih);
//     in_rows/in_pad_top/in_rd_rows/in_base(=arena+src+rd0*in_stride)/out_base 逐 band 算;
//     S_BAND_INIT(band_start) -> S_BAND_FILL(等 band_ready) -> S_BAND_ENG(引擎 start,
//     desc: pad=0, iw=iw+2*pad, ih=in_rows, src=dst=0) -> S_BAND_DRAIN(等 eng_done)
//     -> S_BAND_FLUSH(等 band_done) -> 下一 band / 下一 op.
//   路径 A 口径: tilecache 物化竖直+水平 pad（in_row_bytes=(iw+2*pad)*ic_pad）,
//   PACKED3 例外（tile[2]=1: 行字节 iw*3, 引擎保留 rom.pad; 见报告"已知限制"）。
//   zp_in: conv/dwconv 取 rom.aux0[7:0]（符号扩展, converter 写入; add/copy 的 aux
//   另有语义 -> zp_in=0, 其 band 无竖直 pad）。
//   预取长度检查: wlen<=131072, qlen<=8192; 越界/pre_err/tile_err -> err E6。
//   非 band op（tile=0）在同一个 job 中仍走 legacy 直通（混合 ROM: 瓶盖 op0 用
//   tile=0 整张量路径, op1..105 走 band; 指针仍按 wlen 累加以保持流对齐）。
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

  // ---- [v1 · S1] job 级状态（只读输出）----
  output logic [7:0]        done_ops,
  output logic              job_timeout,

  // ---- 给引擎 ----
  output nn_pkg::nn_desc_t  eng_desc,
  output logic              eng_start,
  input  logic              eng_busy,
  input  logic              eng_done,
  input  logic [31:0]       eng_cycles,
  input  logic [7:0]        eng_err_code,

  // ==========================================================================
  // [v1 · M6c] band / streaming 控制（仅在 rom.tile[7:4]!=0 时使用）
  // nn_subsys 初版 tie-off: pre_busy=0, pre_done=1, pre_err=0, band_ready=1,
  // band_done=1, tile_err=0, *_ddr_base=0。输出可悬空。
  // ==========================================================================
  input  logic              pre_busy,      // 未用（保留）
  input  logic              pre_done,      // 1 拍脉冲
  input  logic              pre_err,       // 与 pre_done 同拍有效
  input  logic              band_ready,    // fill 完成
  input  logic              band_done,     // 1 拍脉冲: flush 完成
  input  logic [7:0]        tile_err,
  input  logic [31:0]       w_ddr_base,    // 流式 W 镜像 DDR 基址
  input  logic [31:0]       q_ddr_base,    // 流式 Q 镜像 DDR 基址
  input  logic [31:0]       arena_ddr_base,// 激活 arena DDR 基址
  output logic              pre_start,
  output logic [31:0]       pre_src_addr,
  output logic [17:0]       pre_wlen,
  output logic [31:0]       pre_qsrc_addr,
  output logic [12:0]       pre_qlen,
  output logic              pre_bank,
  output logic              w_bank_sel,
  output logic              q_bank_sel,
  output logic [31:0]       d_in_base,
  output logic [15:0]       d_in_rows,
  output logic [15:0]       d_in_row_bytes,
  output logic [15:0]       d_in_stride,
  output logic [15:0]       d_in_pad_top,
  output logic [15:0]       d_in_rd_rows,
  output logic [7:0]        d_zp_in,
  output logic              d_add_mode,
  output logic [31:0]       d_aux_base,
  output logic [15:0]       d_aux_stride,
  output logic [15:0]       d_aux_pad_top,
  output logic [15:0]       d_aux_rd_rows,
  output logic [31:0]       d_out_base,
  output logic [15:0]       d_out_rows,
  output logic [15:0]       d_out_row_bytes,
  output logic [15:0]       d_out_stride,
  output logic              band_start,
  output logic [15:0]       band_idx,      // 当前 op 内 band 序号（调试）
  output logic [15:0]       band_n,        // 当前 op 的 n_bands（调试）
  output logic              band_active
);

  // 单 op 看门狗: 正常 op < 200K 拍; 留 4M 拍余量防止仿真挂死
  localparam logic [31:0] GUARD_MAX = 32'd4_000_000;
  // job 级看门狗: YOLO 1.19M / 瓶盖 band 模式远小于 64M
  localparam logic [31:0] JOB_GUARD_MAX = 32'd64_000_000;
  // 预取长度上限（M3-WSTREAM: W<=128KiB, Q shadow<=8KiB）
  localparam logic [17:0] PRE_WLEN_MAX = 18'd131_072;
  localparam logic [13:0] PRE_QLEN_MAX = 14'd8_192;   // 8192 needs 14 bit (2^13)

  typedef enum logic [4:0] {
    S_IDLE       = 5'd0,
    S_FETCH      = 5'd1,
    S_ISSUE      = 5'd2,
    S_WAIT       = 5'd3,
    S_NEXT       = 5'd4,
    S_DONE       = 5'd5,
    S_ERR        = 5'd6,
    S_TIMEOUT    = 5'd7,
    // M6c band 路径
    S_PRE0       = 5'd8,   // 发本 op 的 pre_start
    S_PRE0_WAIT  = 5'd9,   // 等本 op 预取完成
    S_BAND_INIT  = 5'd10,  // band 描述符准备 + band_start（b==0 时发下一 op 预取）
    S_BAND_FILL  = 5'd11,  // 等 band_ready
    S_BAND_ENG   = 5'd12,  // 引擎 start（1 拍）
    S_BAND_DRAIN = 5'd13,  // 等 eng_done
    S_BAND_FLUSH = 5'd14,  // 等 band_done
    S_OP_END     = 5'd15,  // op 结束
    S_PRE_END    = 5'd16   // 等下一 op 预取完成 + 翻 bank
  } state_e;

  state_e       st, st_n;
  logic [7:0]   idx;
  logic [31:0]  acc_cycles;
  logic [31:0]  guard;
  logic [7:0]   err_code_r;
  logic         done_r, busy_r;
  logic [31:0]  job_guard;
  logic         job_timeout_r;
  logic [7:0]   done_ops_r;
  nn_rom_t      rom;
  nn_rom_t      rom_la;        // 下一 op（重叠预取 look-ahead）
  nn_desc_t     desc_r;

  // M6c band 状态寄存器（声明提前: 组合逻辑要用）
  logic [6:0]   band_b;        // band 序号（0..127; n_bands 最大 112）
  logic [17:0]  wlen_r, wlen_next;
  logic [12:0]  qlen_r, qlen_next;
  logic [31:0]  w_ptr, q_ptr;
  logic         cur_bank;
  logic         pre_pending;   // 已发下一 op 的 pre_start, 等 pre_done
  logic         cur_ready;     // 本 op 权重已就位（预取完成或上一 op 期间预取好）
  logic         pre_seen;      // pre_done 粘滞（预取可在 band 计算期间提前完成）
  logic         pre_err_r;     // pre_err 粘滞
  logic         oband;         // 本 op 是否 band 模式（rom.tile[1]=band_en）

  wire last_entry = (NN_ROM_LEN == 0) || (idx == 8'(NN_ROM_LEN - 1));
  wire has_next   = (NN_ROM_LEN != 0) && (idx != 8'(NN_ROM_LEN - 1));
  wire [7:0] idx_la = has_next ? (idx + 8'd1) : idx;

  // ROM 同步读（BRAM ROM, 双读口: 当前项 + look-ahead 下一项）
  (* rom_style = "block" *)
  logic [$bits(nn_pkg::nn_rom_t)-1:0] rom_mem [0:NN_ROM_DEPTH-1];
  initial begin
    for (int i = 0; i < NN_ROM_DEPTH; i++) rom_mem[i] = NN_ROM[i];
  end
  always_ff @(posedge clk) begin
    if (rst) begin
      rom    <= '0;
      rom_la <= '0;
    end else begin
      rom    <= rom_mem[idx];
      rom_la <= rom_mem[idx_la];
    end
  end

  // tile 字段: tile[7:0]!=0 即启用 tiling; band_rows = tile[7:4]+1 (1..16)
//   [3]=add_mode [2]=packed3_stream [1:0] rsvd -> 对 B=1 的非 add op 用 tile[0]=1 表示 tiling
assign oband = rom.tile[1];   // [Lead 2026-11-04] band_en = tile[1] (tile==0 => whole/直通)

  // ==========================================================================
  // band 几何（M4-TILECACHE.md 附录 A）
  // ==========================================================================
  wire p3_stream = rom.tile[2] || rom.flags[NN_F_PACKED3];
  wire kind_add  = (rom.kind == NN_ROM_KIND_ADD);
  wire kind_copy = (rom.kind == NN_ROM_KIND_COPY);
  wire kind_up   = (rom.kind == NN_ROM_KIND_UP2X);
  wire kind_pool = (rom.kind == NN_ROM_KIND_POOL);

  wire [3:0]  k_g   = (kind_add || kind_copy) ? 4'd1 : (rom.ks == 4'd0 ? 4'd1 : rom.ks);
  wire [1:0]  st_g  = (kind_add || kind_copy || (rom.stride == 2'd0)) ? 2'd1 : rom.stride;
  wire [2:0]  pad_g = (kind_add || kind_copy) ? 3'd0
                    : (kind_pool && (rom.pad == 3'd0)) ? ((k_g - 4'd1) >> 1) : rom.pad;
  wire [15:0] ic8_g = 16'(((rom.ic) + 16'd7) & 16'hFFF8);
  wire [15:0] oc8_g = 16'(((rom.oc) + 16'd7) & 16'hFFF8);
  wire [15:0] ih_g  = 16'(rom.ih);
  wire [15:0] iw_g  = 16'(rom.iw);
  wire [31:0] oh32  = kind_up ? (32'(ih_g) * 2)
                    : (32'(ih_g) + 32'(pad_g) * 2 - 32'(k_g)) / 32'(st_g) + 32'd1;
  wire [31:0] ow32  = kind_up ? (32'(iw_g) * 2)
                    : (32'(iw_g) + 32'(pad_g) * 2 - 32'(k_g)) / 32'(st_g) + 32'd1;
  // band_rows = tile[7:4]+1 (1..16); upsample 强制偶数（band 相对原点数学等价）
  wire [4:0]  br_raw = 5'(rom.tile[7:4]) + 5'd1;
  wire [4:0]  br_eff = (kind_up && br_raw[0]) ? (br_raw - 5'd1) : br_raw;
  wire [4:0]  br_use = (br_eff == 5'd0) ? 5'd2 : br_eff;
  wire [15:0] n_bands16 = 16'((oh32 + 32'(br_use) - 32'd1) / 32'(br_use));
  wire [15:0] out_r0 = 16'(32'(band_b) * 32'(br_use));
  wire [15:0] br_cur = 16'((32'(out_r0) >= oh32) ? 32'd0
                    : ((oh32 - 32'(out_r0)) > 32'(br_use) ? 32'(br_use)
                                                          : (oh32 - 32'(out_r0))));
  wire [15:0] in_row_bytes = p3_stream ? (16'(iw_g) * 16'd3)
                           : kind_up   ? (16'(iw_g) * ic8_g)
                           : 16'((16'(iw_g) + {13'd0, pad_g} * 16'd2) * ic8_g);
  wire [15:0] in_stride = p3_stream ? (16'(iw_g) * 16'd3) : (16'(iw_g) * ic8_g);
  wire [15:0] out_row_bytes = 16'(ow32) * oc8_g;
  wire [15:0] in_rows_up = 16'(16'(br_cur) >> 1) + 16'd1;
  wire [15:0] in_rows_cv = 16'(16'(br_cur - 16'd1) * {14'd0, st_g} + {12'd0, k_g});
  wire [15:0] in_rows    = kind_up ? in_rows_up : in_rows_cv;
  // band_row0 = out_r0*stride - pad（有符号）
  wire signed [17:0] band_row0_s = $signed({2'b00, out_r0}) * $signed({16'd0, st_g})
                                   - $signed({15'd0, pad_g});
  wire [15:0] abs1 = 16'(band_row0_s + $signed({2'b00, in_rows}));
  wire [15:0] rd0  = kind_up ? 16'(out_r0 >> 1)
                    : ((band_row0_s < 18'sd0) ? 16'd0 : 16'(band_row0_s));
  wire [15:0] rd1  = kind_up ? ((16'(rd0 + in_rows) > ih_g) ? ih_g : 16'(rd0 + in_rows))
                             : ((abs1 > ih_g) ? ih_g : abs1);
  // pad_top = rd0 - band_row0（band_row0<0 时补 zp 行; ≥0 时为 0）
  wire [15:0] in_pad_top = kind_up ? 16'd0
                         : ((band_row0_s < 18'sd0) ? 16'(-band_row0_s) : 16'd0);
  wire [15:0] in_rd_rows = (rd1 > rd0) ? 16'(rd1 - rd0) : 16'd0;
  wire [31:0] in_base_c  = 32'(arena_ddr_base) + 32'(rom.src) + 32'(rd0) * 32'(in_stride);
  wire [31:0] out_base_c = 32'(arena_ddr_base) + 32'(rom.dst) + 32'(out_r0) * 32'(out_row_bytes);

  assign d_in_base       = in_base_c;
  assign d_in_rows       = in_rows;
  assign d_in_row_bytes  = in_row_bytes;
  assign d_in_stride     = in_stride;
  assign d_in_pad_top    = in_pad_top;
  assign d_in_rd_rows    = in_rd_rows;
  // zp_in: conv/dwconv 用 aux0[7:0]（Lead 裁决; 符号扩展语义, 8 位位型直接送）
  assign d_zp_in         = (p3_stream || kind_add || kind_copy) ? 8'd0 : rom.aux0[7:0];
  assign d_add_mode      = kind_add;
  assign d_aux_base      = out_base_c;         // ADD: dst 累加带
  assign d_aux_stride    = out_row_bytes;
  assign d_aux_pad_top   = 16'd0;
  assign d_aux_rd_rows   = kind_add ? br_cur : 16'd0;
  assign d_out_base      = out_base_c;
  assign d_out_rows      = br_cur;
  assign d_out_row_bytes = out_row_bytes;
  assign d_out_stride    = out_row_bytes;

  wire wlen_bad    = (rom.wlen > PRE_WLEN_MAX) || (14'(rom.qlen) > PRE_QLEN_MAX);
  wire wlen_la_ok  = (rom_la.wlen <= PRE_WLEN_MAX) && (14'(rom_la.qlen) <= PRE_QLEN_MAX);
  wire la_band     = rom_la.tile[1];

  // ==========================================================================
  // 引擎描述符: legacy = nn_rom_to_desc; band = 路径 A 覆写
  // ==========================================================================
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

  nn_desc_t band_desc;
  always_comb begin
    band_desc      = desc_r;
    band_desc.ih   = in_rows;
    band_desc.iw   = p3_stream ? iw_g : 16'(iw_g + {13'd0, pad_g} * 16'd2);
    band_desc.pad  = p3_stream ? rom.pad : 3'd0;
    band_desc.src  = 32'd0;
    band_desc.dst  = 32'd0;
    band_desc.woff = 32'd0;
    band_desc.qoff = 32'd0;
  end

  assign eng_desc  = oband ? band_desc : desc_r;
  assign eng_start = ((st == S_ISSUE) && !oband) || (st == S_BAND_ENG);
  assign busy      = busy_r;
  assign done      = done_r;
  assign cycles    = acc_cycles;
  assign err       = (st == S_ERR);
  assign err_code  = err_code_r;
  assign done_ops  = done_ops_r;
  assign job_timeout = job_timeout_r;

  assign band_active = (st inside {S_PRE0, S_PRE0_WAIT, S_BAND_INIT, S_BAND_FILL,
                                   S_BAND_ENG, S_BAND_DRAIN, S_BAND_FLUSH,
                                   S_OP_END, S_PRE_END});
  assign band_idx = {9'd0, band_b};
  assign band_n   = band_active ? n_bands16 : 16'd0;

  // ==========================================================================
  // 预取命令（单拍脉冲: S_PRE0=本 op 首预取; S_BAND_INIT 且 b==0=下一 op 重叠预取）
  // ==========================================================================
  wire pre_issue = (st == S_PRE0) ||
                   ((st == S_BAND_INIT) && (band_b == 7'd0) && has_next &&
                    la_band && !pre_pending);
  assign pre_start = pre_issue;
  // 地址: S_PRE0 -> 本 op 基址 (w_ptr 已是本 op 流偏移); S_BAND_INIT -> 下一 op 基址
  assign pre_src_addr  = (st == S_PRE0) ? (32'(w_ddr_base) + 32'(w_ptr))
                                        : (32'(w_ddr_base) + 32'(w_ptr) + 32'(wlen_r));
  assign pre_qsrc_addr = (st == S_PRE0) ? (32'(q_ddr_base) + 32'(q_ptr))
                                        : (32'(q_ddr_base) + 32'(q_ptr) + 32'(qlen_r));
  assign pre_wlen      = (st == S_PRE0) ? wlen_r : wlen_next;
  assign pre_qlen      = (st == S_PRE0) ? qlen_r : qlen_next;
  assign pre_bank      = ~cur_bank;
  assign w_bank_sel    = cur_bank;
  assign q_bank_sel    = cur_bank;
  assign band_start    = (st == S_BAND_INIT);

  // ==========================================================================
  // 状态转移
  // ==========================================================================
  always_comb begin
    st_n = st;
    unique case (st)
      S_IDLE:  if (start) st_n = (NN_ROM_LEN == 0) ? S_DONE : S_FETCH;
      // S_FETCH/S_ISSUE 与旧状态机一致; oband 在 S_ISSUE 判定（此时 rom/rom_la 有效）
      S_FETCH: st_n = S_ISSUE;
      S_ISSUE: st_n = !oband ? S_WAIT
                    : (cur_ready ? S_BAND_INIT : S_PRE0);
      S_WAIT: begin
        if (eng_err_code != 8'd0)            st_n = S_ERR;
        else if (job_guard >= JOB_GUARD_MAX) st_n = eng_busy ? S_TIMEOUT : S_DONE;
        else if (guard >= GUARD_MAX)         st_n = S_ERR;
        else if (eng_done)                   st_n = S_NEXT;
      end
      S_NEXT:  st_n = last_entry ? S_DONE : S_FETCH;
      S_DONE:  st_n = S_IDLE;
      S_ERR:   st_n = S_IDLE;
      S_TIMEOUT: st_n = eng_busy ? S_TIMEOUT : S_DONE;
      // ---- M6c band ----
      S_PRE0:      st_n = (wlen_bad || !wlen_la_ok && has_next && la_band) ? S_ERR : S_PRE0_WAIT;
      S_PRE0_WAIT: begin
        if (job_guard >= JOB_GUARD_MAX)  st_n = S_TIMEOUT;
        else if (guard >= GUARD_MAX)     st_n = S_ERR;
        else if (pre_seen)               st_n = pre_err_r ? S_ERR : S_BAND_INIT;
      end
      S_BAND_INIT: st_n = ((band_b == 7'd0) && has_next && la_band && !wlen_la_ok)
                           ? S_ERR : S_BAND_FILL;
      S_BAND_FILL: begin
        if (tile_err != 8'd0)            st_n = S_ERR;
        else if (job_guard >= JOB_GUARD_MAX) st_n = S_TIMEOUT;
        else if (guard >= GUARD_MAX)     st_n = S_ERR;
        else if (band_ready)             st_n = S_BAND_ENG;
      end
      S_BAND_ENG:  st_n = S_BAND_DRAIN;
      S_BAND_DRAIN: begin
        if (eng_err_code != 8'd0)        st_n = S_ERR;
        else if (job_guard >= JOB_GUARD_MAX) st_n = eng_busy ? S_TIMEOUT : S_DONE;
        else if (guard >= GUARD_MAX)     st_n = S_ERR;
        else if (eng_done)               st_n = S_BAND_FLUSH;
      end
      S_BAND_FLUSH: begin
        if (tile_err != 8'd0)            st_n = S_ERR;
        else if (job_guard >= JOB_GUARD_MAX) st_n = S_TIMEOUT;
        else if (guard >= GUARD_MAX)     st_n = S_ERR;
        else if (band_done)              st_n = (band_b + 7'd1 >= 7'(n_bands16))
                                                 ? S_OP_END : S_BAND_INIT;
      end
      S_OP_END:   st_n = pre_pending ? S_PRE_END : (last_entry ? S_DONE : S_FETCH);
      S_PRE_END: begin
        if (job_guard >= JOB_GUARD_MAX)  st_n = S_TIMEOUT;
        else if (guard >= GUARD_MAX)     st_n = S_ERR;
        else if (pre_seen)               st_n = pre_err_r ? S_ERR
                                                         : (last_entry ? S_DONE : S_FETCH);
      end
      default: st_n = S_IDLE;
    endcase
  end

  // ==========================================================================
  // 时序
  // ==========================================================================
  wire wait_any = (st == S_PRE0_WAIT) || (st == S_BAND_FILL) || (st == S_BAND_DRAIN) ||
                  (st == S_BAND_FLUSH) || (st == S_PRE_END);
  always_ff @(posedge clk) begin
    if (rst) begin
      st <= S_IDLE; idx <= 8'd0; acc_cycles <= 32'd0; guard <= 32'd0;
      err_code_r <= 8'd0; busy_r <= 1'b0; done_r <= 1'b0;
      job_guard <= 32'd0; job_timeout_r <= 1'b0; done_ops_r <= 8'd0;
      band_b <= 7'd0; wlen_r <= 18'd0; qlen_r <= 13'd0;
      wlen_next <= 18'd0; qlen_next <= 13'd0;
      w_ptr <= 32'd0; q_ptr <= 32'd0; cur_bank <= 1'b0;
      pre_pending <= 1'b0; cur_ready <= 1'b0;
      pre_seen <= 1'b0; pre_err_r <= 1'b0;
    end else begin
      st     <= st_n;
      done_r <= 1'b0;
      // 预取完成可在任意状态到来（op N 计算期间预取 op N+1）-> 粘滞捕获
      if (pre_done) begin
        pre_seen  <= 1'b1;
        pre_err_r <= pre_err;
      end
      if (pre_issue) pre_seen <= 1'b0;
      // 看门狗（legacy S_WAIT / band 等待态）
      if ((st == S_WAIT) || wait_any) begin
        guard     <= guard + 32'd1;
        job_guard <= job_guard + 32'd1;
      end
      // 超时/错误码
      if (st == S_WAIT) begin
        if (eng_err_code != 8'd0)                          err_code_r <= eng_err_code;
        else if (guard >= GUARD_MAX)                       err_code_r <= 8'hE3;
      end
      if (wait_any && (guard >= GUARD_MAX) && (err_code_r == 8'd0)) begin
        err_code_r <= ((st == S_PRE0_WAIT) || (st == S_PRE_END) ||
                       (st == S_BAND_FILL) || (st == S_BAND_FLUSH)) ? 8'hE6 : 8'hE3;
      end
      if ((st == S_PRE0_WAIT || st == S_PRE_END) && pre_seen && pre_err_r)
        err_code_r <= 8'hE6;
      if ((st == S_BAND_FILL || st == S_BAND_FLUSH) && (tile_err != 8'd0))
        err_code_r <= 8'hE6;
      if ((st == S_PRE0) && (wlen_bad || (!wlen_la_ok && has_next && la_band)))
        err_code_r <= 8'hE6;
      if ((st == S_BAND_INIT) && (band_b == 7'd0) && has_next && la_band && !wlen_la_ok)
        err_code_r <= 8'hE6;
      if (job_guard >= JOB_GUARD_MAX) begin
        job_timeout_r <= 1'b1;
        err_code_r    <= 8'hE4;
      end

      unique case (st)
        S_IDLE: begin
          busy_r <= 1'b0;
          if (start) begin
            idx        <= 8'd0;
            acc_cycles <= 32'd0;
            guard      <= 32'd0;
            err_code_r <= 8'd0;
            busy_r     <= 1'b1;
            job_guard     <= 32'd0;
            job_timeout_r <= 1'b0;
            done_ops_r    <= 8'd0;
            band_b <= 7'd0; w_ptr <= 32'd0; q_ptr <= 32'd0;
            cur_bank <= 1'b0; pre_pending <= 1'b0; cur_ready <= 1'b0;
            wlen_next <= 18'd0; qlen_next <= 13'd0;
          end
        end
        S_ISSUE: begin
          // 锁存本 op 长度 + 下一 op 长度（look-ahead 重叠预取用）
          band_b    <= 7'd0;      // 每个 op 的 band 序号从 0 开始（预取好的 op 直接进 BAND_INIT）
          wlen_r    <= rom.wlen;
          qlen_r    <= rom.qlen;
          wlen_next <= rom_la.wlen;
          qlen_next <= rom_la.qlen;
          if (!oband) begin
            done_ops_r <= done_ops_r + 8'd1;   // legacy op 计数
            cur_ready  <= 1'b0;                // 下一个 band op 需要重新预取
          end
        end
        S_WAIT: begin
          if (eng_done) acc_cycles <= acc_cycles + eng_cycles;
        end
        S_NEXT: begin
          idx <= idx + 8'd1;
          // 混合 ROM: legacy op 也推进流指针（保持后续 band op 的 W/Q 对齐）
          w_ptr <= w_ptr + 32'(wlen_r);
          q_ptr <= q_ptr + 32'(qlen_r);
        end
        // ---- M6c band ----
        S_PRE0: ;   // pre_start 已在组合侧发出（单拍）
        S_PRE0_WAIT: begin
          if (pre_seen && !pre_err_r) begin
            cur_bank    <= ~cur_bank;
            cur_ready   <= 1'b1;
            band_b      <= 7'd0;
            pre_pending <= 1'b0;
            pre_seen    <= 1'b0;
          end
        end
        S_BAND_INIT: begin
          if ((band_b == 7'd0) && has_next && la_band) pre_pending <= 1'b1;
        end
        S_BAND_DRAIN: begin
          if (eng_done) acc_cycles <= acc_cycles + eng_cycles;
        end
        S_BAND_FLUSH: begin
          if (band_done) begin
            if (band_b + 7'd1 >= 7'(n_bands16)) begin
              done_ops_r <= done_ops_r + 8'd1;   // op 完成（一 op 只计一次）
            end else begin
              band_b <= band_b + 7'd1;
            end
          end
        end
        S_OP_END: begin
          // 本 op 完成: 流指针推进到下一 op 基址（下一 op 的预取地址=旧 w_ptr+wlen_r）
          w_ptr <= w_ptr + 32'(wlen_r);
          q_ptr <= q_ptr + 32'(qlen_r);
          if (pre_pending) begin
            // 等 S_PRE_END 完成预取后再翻 bank / 推进 idx
          end else begin
            cur_ready <= 1'b0;
            if (!last_entry) idx <= idx + 8'd1;
          end
        end
        S_PRE_END: begin
          if (pre_seen && !pre_err_r) begin
            cur_bank    <= ~cur_bank;
            cur_ready   <= 1'b1;
            pre_pending <= 1'b0;
            pre_seen    <= 1'b0;
            if (!last_entry) idx <= idx + 8'd1;
          end
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
