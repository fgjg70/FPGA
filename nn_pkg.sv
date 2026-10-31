`timescale 1ns/1ps

// ============================================================================
// nn_pkg.sv — AI 加速子系统 (NPU) 的类型 / 常量包 —— **单一事实来源**
// ----------------------------------------------------------------------------
// 契约文档: results/ai-accel/CONTRACT.md (§3 存储布局 / §4 寄存器 / §8 激活布局)
// 方案文档: results/ai-accel/PLAN.md
//
// 【为什么把常量和描述符集中在一个 package 里】
//   本仓库已经因为"同一事实写在两个地方、只改了一处"吃过多次代价 (PITFALLS R1)。
//   nn_mem / nn_conv_engine / nn_subsys / TB / 软件头文件全部只从这一份取值;
//   软件侧 (sw/yolo_demo.c) 靠 tools/yolo/*.py 从本文件自动抄地址, 不手写常量。
//
// 【地址口径】
//   NN_BASE / NN_BYTES 在 rv32_pkg.sv (core.sv 做地址译码要用, 不能依赖本包);
//   本包只放"窗口内分区偏移"与"引擎接口类型"。
// ============================================================================

package nn_pkg;

  // --------------------------------------------------------------------------
  // NN 存储窗口内分区 (字节偏移, 相对 rv32_pkg::NN_BASE)
  // 预算 (CONTRACT §3 v0.3): W 320KB, Q 48KB(变长), A/B 各 64KB
  // --------------------------------------------------------------------------
  localparam logic [31:0] NN_W_OFF = 32'h0000_0000;   // int8 权重 (综合时 $readmemh 烧入)
  localparam logic [31:0] NN_Q_OFF = 32'h0005_0000;   // 量化参数 (变长紧凑布局, qoff 逐层给)
  localparam logic [31:0] NN_A_OFF = 32'h0006_0000;   // 激活缓冲 A (96KB)
  localparam logic [31:0] NN_B_OFF = 32'h0007_8000;   // 激活缓冲 B (32KB)

  // 【v0.3 预算 —— 由 BRAM36 的物理容量反推, 不是拍脑袋】
  //   本器件 135 × BRAM36; 行为级推断下"可按字节寻址"的可用容量是 **4KB/BRAM**
  //   (32 位宽用 1K×36、64 位宽用 512×72, parity 位无法用于字节寻址)。
  //   交付档核心已用 9 块 (imem4 + dmem4 + bht1) ⇒ NPU 只剩 126 块 = 504KB。
  //   分配: WQ 368KB(92) + A 96KB(24) + B 32KB(8) = 496KB(124) ⇒ 合计 133/135,
  //   **只剩 2 块余量** —— 任何新增片上存储都必须先报 Lead (见 results/ai-accel/PLAN.md)。
  //   WQ = W(320KB) + Q(48KB) 连续; 0x5C000..0x5FFFF 是地址空洞 (不占 BRAM, 读到 0)。
  //   【A=96K/B=32K 的由来】128 输入下最大单张量是 24ch×64×64 = 98,304 B (layer9 输出),
  //   必须放在 A; 残差并存的 32,768 B 放 B。两者和 = 128KB 不变, 所以总 BRAM 不变。
  localparam int unsigned NN_W_BYTES   = 320*1024;    // W 区 (权重)
  localparam int unsigned NN_Q_BYTES   = 48*1024;     // Q 区 (量化参数, 变长紧凑布局)
  localparam int unsigned NN_WQ_BYTES  = NN_W_BYTES + NN_Q_BYTES;   // 368KB 连续
  localparam int unsigned NN_A_BYTES   = 96*1024;     // 激活 A (最大单张量)
  localparam int unsigned NN_B_BYTES   = 32*1024;     // 激活 B

  // --------------------------------------------------------------------------
  // op 编码 (对应 MMIO_NN_OP, CONTRACT §4)
  // --------------------------------------------------------------------------
  localparam logic [1:0] NN_OP_CONV = 2'd0;   // 普通卷积 / depthwise 卷积 (k=1/3/5)
  localparam logic [1:0] NN_OP_POOL = 2'd1;   // maxpool / avgpool (本版只 max)
  localparam logic [1:0] NN_OP_COPY = 2'd2;   // 通道偏移拷贝 / 2x 最近邻上采样
  localparam logic [1:0] NN_OP_ADD  = 2'd3;   // 残差相加 dst = dst + src (int8 饱和)

  // --------------------------------------------------------------------------
  // flags 位 (对应 MMIO_NN_FLAGS)
  // --------------------------------------------------------------------------
  localparam int unsigned NN_F_DEPTHWISE = 0;  // 1 = depthwise 卷积 (OC==IC==C)
  localparam int unsigned NN_F_LEAKY     = 1;  // 1 = leaky ReLU (斜率 0.1, 已折进 M_neg)
  localparam int unsigned NN_F_ADD       = 2;  // 1 = add-mode: 结果累加到 DST 原值
  localparam int unsigned NN_F_UP2X      = 3;  // 1 = 2x 最近邻上采样 (op=COPY 时)
  localparam int unsigned NN_F_POOLMAX   = 4;  // 1 = maxpool (op=POOL 时)

  // --------------------------------------------------------------------------
  // 引擎描述符 (nn_subsys 从 MMIO 寄存器拼好, start 拍整体有效)
  //   _pad 字段只为对齐/调试可读性; 引擎不得依赖它们的取值。
  // --------------------------------------------------------------------------
  typedef struct packed {
    logic [1:0]  op;         // nn_op_e
    logic [4:0]  flags;      // NN_F_* 位
    logic [3:0]  ks;         // 卷积核 1/3/5; pool 核 2/3/5/9
    logic [1:0]  stride;     // 1 / 2
    // 【v0.4】pad 从 2 位加宽到 3 位: SPP 头的 maxpool K=9 需要 pad=4 (darknet pad=K/2),
    // 2 位装不下 → 引擎输出尺寸算错 (T-accel 实测 layer 91/92/93)。conv 的 pad ≤2,
    // pool 的 pad ≤4 (K=9)。
    logic [2:0]  pad;
    logic [15:0] ih;         // 输入高 (像素)
    logic [15:0] iw;         // 输入宽
    logic [15:0] ic;         // 输入通道 (真实值)
    logic [15:0] oc;         // 输出通道 (真实值)
    logic [31:0] src;        // 源激活缓冲字节偏移
    logic [31:0] dst;        // 目的激活缓冲字节偏移
    logic [31:0] woff;       // 该层权重区字节偏移
    logic [31:0] qoff;       // 该层量化参数区字节偏移
  } nn_desc_t;

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
