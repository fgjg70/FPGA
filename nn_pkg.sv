`timescale 1ns/1ps

// ============================================================================
// nn_pkg.sv — AI 加速子系统 (NPU) 的类型 / 常量包 —— **单一事实来源**
// ----------------------------------------------------------------------------
// 契约文档: results/ai-accel/CONTRACT.md (§3 存储布局 / §4 寄存器 / §8 激活布局)
// 方案文档: results/ai-accel/PLAN.md
// 冻结记录: results/ai-accel/MODEL-FREEZE.md
// 特化规格: results/ai-accel/SPEC-SPECIALIZED.md (v0.7 autonomous mode)
//
// 【为什么把常量和描述符集中在一个 package 里】
//   本仓库已经因为"同一事实写在两个地方、只改了一处"吃过多次代价 (PITFALLS R1)。
//   nn_mem / nn_conv_engine / nn_subsys / TB / 软件头文件全部只从这一份取值;
//   软件侧 (sw/yolo_demo.c) 靠 tools/yolo/*.py 从本文件自动抄地址, 不手写常量。
//
// 【地址口径】
//   NN_BASE / NN_BYTES 在 rv32_pkg.sv (core.sv 做地址译码要用, 不能依赖本包);
//   本包只放"窗口内分区偏移"与"引擎接口类型"。
//
// 【v0.7 变更 (2026-11-01, 用户 D1-D5 决策后)】
//   1. Q 区 (48KB) 迁**分布式 RAM (LUTRAM)**, 不再与 W 共用 368KB 连续阵列;
//      W 独立 320KB (80 BRAM36), Q 独立 12,288×32b LUTRAM + 独立 64b 读口。
//   2. CPU 窗口收缩为 **A/B only** (W/Q 不可由 CPU 访问)。
//   3. 新增 flags.PACKED3 (conv0 输入 3B/像素) 与 flags.ADD_R (shortcut add 的 per-tensor R)。
//   4. 新增 nn_rom_t: 微码 ROM 项 (nn_seq 读取, 每条 = 一次完整 op 的硬件参数), 深度 128。
//   5. 引擎 v3: 128 MAC/拍 (16 OC lanes × 8 px), 权重读 128b / 激活写 128b。
// ============================================================================

package nn_pkg;

  // --------------------------------------------------------------------------
  // NN 存储窗口内分区 (字节偏移, 相对 rv32_pkg::NN_BASE)
  // 预算 (CONTRACT §3 v0.7): W 320KB(BRAM) + Q 48KB(LUTRAM) + A 96KB + B 32KB
  // --------------------------------------------------------------------------
  localparam logic [31:0] NN_W_OFF  = 32'h0000_0000;   // int8 权重 (综合时 $readmemh 烧入, 80 BRAM)
  localparam logic [31:0] NN_Q_OFF  = 32'h0005_0000;   // [v0.7] 仅地址口径; Q 实现为 LUTRAM, NPU 独立口
  localparam logic [31:0] NN_A_OFF  = 32'h0006_0000;   // 激活缓冲 A (96KB)
  localparam logic [31:0] NN_B_OFF  = 32'h0007_8000;   // 激活缓冲 B (32KB)

  // 【BRAM 物理约束】本器件 135 × BRAM36; 行为级推断下"可按字节寻址"的可用容量是 4KB/BRAM。
  //   交付档核心 9 块 + W 320KB(80) + A 96KB(24) + B 32KB(8) = 121 块 ⇒ 余 14 块给视频链路。
  //   Q 走 LUTRAM 后不再占 BRAM; 320 档的中间激活放 DDR3 (tile 缓存用释放出的 BRAM)。
  localparam int unsigned NN_W_BYTES   = 320*1024;    // W 区 (权重)
  localparam int unsigned NN_Q_BYTES   = 48*1024;     // Q 区 (量化参数, 变长紧凑布局)
  localparam int unsigned NN_A_BYTES   = 96*1024;     // 激活 A (最大单张量)
  localparam int unsigned NN_B_BYTES   = 32*1024;     // 激活 B
  localparam int unsigned NN_W_WORDS   = NN_W_BYTES / 4;      // 81,920 个 32-bit 字 (BRAM 初始化口径)
  localparam int unsigned NN_Q_WORDS   = NN_Q_BYTES / 4;      // 12,288 个 32-bit 字 (LUTRAM)

  // CPU 窗口 (v0.7): 只映射 A/B; 其余地址读 0 / 写忽略。
  localparam logic [31:0] NN_CPU_A_OFF = NN_A_OFF;
  localparam logic [31:0] NN_CPU_B_OFF = NN_B_OFF;

  // --------------------------------------------------------------------------
  // op 编码 (对应 MMIO_NN_OP, CONTRACT §4)
  // --------------------------------------------------------------------------
  localparam logic [1:0] NN_OP_CONV = 2'd0;   // 普通卷积 / depthwise 卷积 (k=1/3/5)
  localparam logic [1:0] NN_OP_POOL = 2'd1;   // maxpool (本版只 max)
  localparam logic [1:0] NN_OP_COPY = 2'd2;   // 通道偏移拷贝 / 2x 最近邻上采样
  localparam logic [1:0] NN_OP_ADD  = 2'd3;   // 残差相加 dst = dst + src (int8 饱和 / v0.7 支持 ADD_R)

  // --------------------------------------------------------------------------
  // flags 位 (对应 MMIO_NN_FLAGS)
  // --------------------------------------------------------------------------
  localparam int unsigned NN_F_DEPTHWISE = 0;  // 1 = depthwise 卷积 (OC==IC==C)
  localparam int unsigned NN_F_LEAKY     = 1;  // 1 = leaky ReLU (斜率 0.1, 已折进 M_neg)
  localparam int unsigned NN_F_ADD       = 2;  // 1 = add-mode: 结果累加到 DST 原值
  localparam int unsigned NN_F_UP2X      = 3;  // 1 = 2x 最近邻上采样 (op=COPY 时)
  localparam int unsigned NN_F_POOLMAX   = 4;  // 1 = maxpool (op=POOL 时)
  // [v0.7 新增]
  localparam int unsigned NN_F_PACKED3   = 5;  // 1 = 输入激活按 3B/像素 packed 寻址 (conv0 专用)
  localparam int unsigned NN_F_ADD_R     = 6;  // 1 = add 用 per-tensor 源 requant: out=clamp(q_d+(((q_s-zp_s)*R)>>KADD))

  // --------------------------------------------------------------------------
  // 引擎描述符 (nn_subsys / nn_seq 从 ROM/MMIO 拼好, start 拍整体有效)
  //   _pad 字段只为对齐/调试可读性; 引擎不得依赖它们的取值。
  // --------------------------------------------------------------------------
  typedef struct packed {
    logic [1:0]  op;         // nn_op_e
    logic [6:0]  flags;      // NN_F_* 位 (v0.7: 5→7 位, 容纳 PACKED3/ADD_R)
    logic [3:0]  ks;         // 卷积核 1/3/5; pool 核 2/3/5/9
    logic [1:0]  stride;     // 1 / 2
    logic [2:0]  pad;        // conv pad ≤2; pool pad ≤4 (K=9)
    logic [15:0] ih;         // 输入高 (像素)
    logic [15:0] iw;         // 输入宽
    logic [15:0] ic;         // 输入通道 (真实值)
    logic [15:0] oc;         // 输出通道 (真实值)
    logic [31:0] src;        // 源激活缓冲字节偏移
    logic [31:0] dst;        // 目的激活缓冲字节偏移
    logic [31:0] woff;       // 该层权重区字节偏移 (v0.7: 相对 W 区基址)
    logic [31:0] qoff;       // 该层量化参数区字节偏移 (v0.7: 相对 Q 区基址)
  } nn_desc_t;

  // --------------------------------------------------------------------------
  // [v0.7] 微码 ROM 项 (nn_seq 读取): 一条 = 一次完整 op
  //   - 由 tools/nn_gen_rom.py 从 plan.json 生成 nn_rom.svh (localparam 数组);
  //   - kind 是"高层 kind" (conv/dwconv/pool/upsample/add/copy), nn_seq 映射成 op+flags;
  //   - src/dst 是窗口内字节偏移 (A/B 区, <128KB ⇒ 17 位足够);
  //   - woff 相对 W 区基址 (≤320KB ⇒ 19 位), qoff 相对 Q 区基址 (≤48KB ⇒ 16 位);
  //   - aux0/aux1: add 时 aux0=R(≤65535), aux1=KADD; 其它 kind 为 0;
  //   - csum: golden FNV-1a (debug 模式逐 op 比对用; demo 模式忽略).
  // --------------------------------------------------------------------------
  localparam int unsigned NN_ROM_DEPTH = 128;        // 128 项 (108 op + 展开 copy + 余量)
  localparam int unsigned NN_ROM_KIND_CONV  = 0;
  localparam int unsigned NN_ROM_KIND_DW    = 1;
  localparam int unsigned NN_ROM_KIND_POOL  = 2;
  localparam int unsigned NN_ROM_KIND_UP2X  = 3;
  localparam int unsigned NN_ROM_KIND_ADD   = 4;
  localparam int unsigned NN_ROM_KIND_COPY  = 5;

  typedef struct packed {
    logic [3:0]  kind;       // NN_ROM_KIND_*
    logic [6:0]  flags;      // NN_F_* (PACKED3/ADD_R/LEAKY/DEPTHWISE/POOLMAX/UP2X)
    logic [3:0]  ks;         // 卷积核 1/3/5; pool 核 2/3/5/9
    logic [2:0]  pad;
    logic [1:0]  stride;
    logic [9:0]  ic;         // 真实输入通道 (≤1024)
    logic [9:0]  oc;         // 真实输出通道
    logic [8:0]  ih;         // 输入高 (≤511)
    logic [8:0]  iw;         // 输入宽
    logic [16:0] src;        // A/B 窗口内字节偏移 (<128KB)
    logic [16:0] dst;
    logic [18:0] woff;       // W 区字节偏移 (<320KB)
    logic [15:0] qoff;       // Q 区字节偏移 (<48KB)
    logic [15:0] aux0;       // add: R
    logic [15:0] aux1;       // add: KADD
    logic [31:0] csum;       // golden FNV (debug)
  } nn_rom_t;                // 4+7+4+3+2+10+10+9+9+17+17+19+16+16+16+32 = 191 bit (打包 192)

  // --------------------------------------------------------------------------
  // ROM 项 → 引擎描述符 (纯组合; nn_seq 用)
  // --------------------------------------------------------------------------
  function automatic nn_desc_t nn_rom_to_desc(input nn_rom_t r);
    nn_desc_t d;
    d.op   = NN_OP_CONV;
    d.flags = r.flags;
    d.ks   = r.ks;
    d.stride = (r.stride == 2'd0) ? 2'd1 : r.stride;
    d.pad  = r.pad;
    d.ih   = 16'(r.ih);
    d.iw   = 16'(r.iw);
    d.ic   = 16'(r.ic);
    d.oc   = 16'(r.oc);
    d.src  = 32'(r.src);
    d.dst  = 32'(r.dst);
    d.woff = 32'(r.woff);
    d.qoff = 32'(r.qoff);
    return d;
  endfunction

  // --------------------------------------------------------------------------
  // 小工具函数 (可综合, 供引擎算地址; 纯组合无状态)
  // --------------------------------------------------------------------------
  function automatic int unsigned nn_pad8(input int unsigned c);
    nn_pad8 = ((c + 7) / 8) * 8;
  endfunction

  function automatic logic [23:0] nn_act_off(input logic [15:0] x,
                                            input logic [15:0] y,
                                            input logic [15:0] w,
                                            input logic [15:0] c8,
                                            input logic [15:0] cb);
    // 激活布局: addr = ((y*w + x)*c8 + cb) * 8 + c_byte  (CONTRACT §8, 64 位字)
    // 这里返回"64 位字"的字节偏移 (不含 c_byte)
    nn_act_off = 24'(((y * w + x) * c8 + cb) * 8);
  endfunction

endpackage
