`timescale 1ns/1ps

// ============================================================================
// load_store_unit.sv — 访存单元 (字节通道 + 非对齐硬件自动拆分) 【寄存读版】
// ----------------------------------------------------------------------------
// 与组合读版的唯一区别: dmem 读数据晚一拍到。为了 **不增加流水线级数、也不增加
// load-use 停顿**, 把"字节提取 + 符号扩展"整体挪到 WB 段组合完成:
//
//   非对齐(不跨字)访问:
//     N   拍: 送地址 (指令在 MEM), 同时把本次访问的规格 (off/size/unsigned/split)
//             记进 WB 影子寄存器
//     N+1 拍: 数据到, 该指令已在 WB 段 -> 用影子寄存器提取 -> 直接进写回 mux
//
//   跨字访问 (off + size_bytes > 4): 多占 2 个停顿周期
//     IDLE: 送头字地址, lsu_stall=1
//     HEAD: 头字到, 捕获到 head_word_r, 改送尾字地址, lsu_stall=1
//     TAIL: 尾字到, lsu_stall=0 (本拍末尾请求离开 MEM 并进入 WB; 继续送尾字地址,
//           好让 WB 拍 dmem_rdata 仍是尾字)
//     WB  : {尾字, 头字} >> (8*off) 合并 -> 提取 -> 写回
//
// 写回 mux 直接用本模块的 load_data (组合), 不再经 MEM/WB 寄存器打第二拍。
//
// 【统一移位法】头字(对齐)与尾字(head+4)拼 64 位按字节偏移整体移位, 一套逻辑覆盖
// 全部对齐/非对齐情况; store 用 {32'b0, wdata} << shamt 配合掩码移位选通。
// ============================================================================

module load_store_unit
  import rv32_pkg::*;
(
  input  logic clk,
  input  logic rst,

  // MEM 段访存请求 (来自 EX/MEM 流水寄存器)
  input  logic            req_read,
  input  logic            req_write,
  input  mem_size_e       req_size,
  input  logic            req_unsigned,
  input  logic [31:0]     req_addr,
  input  logic [31:0]     req_wdata,

  // ---- RV32A 原子指令 (读-改-写) ----
  // 【为什么接在 LSU 而不是另起一套】LSU 本来就有多周期 FSM (为"非对齐跨字
  // 访存 2 拍拆分"建的): 它能按相选地址、按相控写使能、并且用 lsu_stall 冻结
  // 流水线 —— 这正是 AMO 需要的全部要素。所以 AMO 接成**新增相**即可,
  // 不必去动 core.sv 的内存路径接线或 ex_mem 流水寄存器的语义
  // (本项目在"改流水寄存器语义"上吃过四轮亏, 见 IMEM_REG_READ)。
  //
  // amo_newdata: 由 EX 段 ALU 算好的"应写回内存的新值"随流水传下来。
  //              (ALU 的 ALU_AMO_* 就是算这个; a=旧值要等读回来, 所以这里
  //               传的是**已算好的结果**, 逻辑上等价于"新值"。)
  input  logic            amo_en,
  input  logic [31:0]     amo_newdata,

  // DMEM 接口 (寄存读: 地址第 N 拍, 数据第 N+1 拍)
  output logic [31:0]     dmem_addr,
  output logic [31:0]     dmem_wdata,
  output logic [3:0]      dmem_wstrb,
  output logic            dmem_we,
  input  logic [31:0]     dmem_rdata,

  // 结果 (WB 段组合有效, 直接进写回 mux) 与流水线控制
  output logic [31:0]     load_data,
  output logic            lsu_stall,
  // AMO 写相标志 (1 = 本拍 LSU 正在把"新值"写回内存)
  // 【为什么引出来】core 要用它决定"现在该不该让 AMO 新值计算单元输出" ——
  // 新值依赖 amo_old, 而 amo_old 在写相那拍才有效。所以 core 里的第二个 ALU
  // 必须在写相那拍用 {amo_old, rs2} 算, 其余时候不参与。
  output logic            amo_write_phase,
  // AMO 读回的旧值 (写相那拍有效), 供 core 的 AMO 新值计算单元使用
  output logic [31:0]     amo_old_out
);

  // AMO 用两个新相接在拆分访存状态机后面 (编码 2'd3 做 AMO_READ,
  // 再用一个独立的标志区分 WAIT, 避免把 state 加宽 -> 少动现有逻辑)
  localparam logic [1:0] S_IDLE = 2'd0, S_HEAD = 2'd1, S_TAIL = 2'd2;
  localparam logic [1:0] S_AMO  = 2'd3;      // AMO 读相 / 写相 (由 amo_wr 区分)
  logic                  amo_wr;             // 1 = 写相 (组合导出, 见下)
  logic                  amo_phase;          // 0=读相 1=写相
  logic                  amo_wait;           // 1=正在等 dmem 的寄存读出数据
  logic                  amo_active;         // AMO 序列进行中
  logic [31:0]           amo_old;            // 读回的旧值 (也是 rd 的值)
  logic [31:0]           amo_addr_r;         // AMO 的字地址 (启动拍锁存, 两相都用它)
  logic                  amo_mode_r;         // AMO 已启动 (保持到 WB 拍, 供 load_data 选择)

  logic [1:0]  state;

  logic [1:0]  off;
  logic [31:0] size_bytes;
  logic        needs_split;
  logic [31:0] head_addr, tail_addr;
  logic [63:0] store_shifted;
  logic [7:0]  size_mask, strobe8;
  logic [3:0]  head_strb, tail_strb;

  // 头字寄存器: HEAD 拍捕获, WB 拍与尾字合并
  logic [31:0] head_word_r;

  // WB 段影子: 访存指令进入 WB 时, 提取所需的规格
  logic [1:0]  off_wb;
  logic [1:0]  size_wb;
  logic        uns_wb;
  logic        split_wb;

  assign off        = req_addr[1:0];
  assign size_bytes = (req_size == MEM_BYTE) ? 32'd1 :
                      (req_size == MEM_HALF) ? 32'd2 : 32'd4;

  assign needs_split = (req_read || req_write) &&
                       (({30'd0, off} + size_bytes) > 32'd4);

  assign head_addr = {req_addr[31:2], 2'b00};
  assign tail_addr = head_addr + 32'd4;

  // 地址选择: IDLE 送头字, HEAD/TAIL 送尾字 (TAIL 继续送尾字, 让 WB 拍数据仍是尾字)
  //           AMO 两相都送**锁存下来的** AMO 地址
  // 【为什么必须锁存】AMO 序列跨多拍, 而 req_addr 来自 EX/MEM 流水寄存器 ——
  // 冻结期间它虽然不变, 但一旦流水线推进就不对了。实测第一批诊断打印里
  // 写相那拍 addr=00000000, 就是因为没有稳定的 AMO 地址来源。
  // AMO 相与地址选择: 只在 A_EN 打开时才参与, 否则完全等价于加 A 扩展之前
  // (实测: 即使休眠, AMO 的 mux/比较逻辑也落在访存路径上, fmax 61.7 -> 59.1)
`ifdef A_EN
  assign dmem_addr  = (state == S_AMO) ? amo_addr_r
                    : (state == S_IDLE) ? head_addr : tail_addr;
`else
  assign dmem_addr  = (state == S_IDLE) ? head_addr : tail_addr;
`endif

  // ---------------- store 路径 ----------------
  // 注意: store 用 *当前请求* 的 off, 不是 WB 影子的 off_wb —— 影子属于上一条
  // 已进入 WB 的访存指令, 拿它移位会把数据挪错位置 (实测基础测试直接跑挂)。
  assign store_shifted = {32'b0, req_wdata} << {off, 3'b000};
  assign size_mask     = (8'd1 << size_bytes[3:0]) - 8'd1;
  assign strobe8       = size_mask << off;
  assign head_strb     = strobe8[3:0];
  assign tail_strb     = strobe8[7:4];

  assign dmem_wdata = (state == S_AMO)  ? amo_newdata          // AMO 写相写"新值"
                    : (state == S_IDLE) ? store_shifted[31:0]
                                        : store_shifted[63:32];
  // ---- 写使能 ----
  // 原逻辑: TAIL 拍不再重复写 (跨字 store 在 IDLE 写头、HEAD 写尾即可)
  // AMO: 读相不写, 写相才写整个字 (4'b1111)
  assign dmem_wstrb = (state == S_AMO)  ? (amo_wr ? 4'b1111 : 4'b0000)
                    : (req_write && state != S_TAIL)
                      ? ((state == S_IDLE) ? head_strb : tail_strb) : 4'b0000;
  assign dmem_we    = (state == S_AMO)  ? amo_wr
                    : (req_write && (state != S_TAIL));

  // 停顿: HEAD 拍 + "IDLE 且需要拆分" 的那一拍 + AMO 的**前两相**都要停
  // AMO 三个相位: 等待(amo_wait) -> 读相(phase=0) -> 写相(phase=1, 放行)
  //
  // 【2026-10-06 修复】必须把 AMO 的 **launch 拍**(state==S_IDLE && amo_en) 也拉停,
  // 与上面"IDLE 且 needs_split"完全对称。原来漏了它, 后果是一条极隐蔽的错位:
  //
  //   launch 拍不拉 lsu_stall -> hold_mem=0 -> 流水线**多前进一拍**:
  //     EX/MEM 被后一条指令顶掉、MEM/WB 提前一拍让出 -> AMO 的 WB 落在 cyc41,
  //     而紧随 AMO 的那条 lw 的 WB 提前到 cyc44 —— 恰好是 amo_mode_r 仍为 1 的
  //     那一拍, 于是 lw 读到的是 amo_old 而不是 dmem_rdata。
  //
  // 实测证据 (amo.S 第 3 组: amoor 后面紧贴 lw t4, 0(t0)):
  //   cyc44  wb_rd=29(=t4)  wb=0xf0f0f0f0  mode_r=1   <- 该给 0xFFFFFFFF, 给了旧值
  //
  // 拉停 launch 拍后: AMO 的 WB 推到 cyc44(mode_r=1, 正确取 amo_old),
  // lw 的 WB 推到 cyc45(mode_r=0, 正确取 dmem_rdata)。
  // 代价: AMO 每个多 1 拍停顿 —— 但 A_EN 默认关闭、CoreMark 不含原子指令,
  //       对评分三项零影响 (实测 CoreMark ticks 不变)。
  assign lsu_stall  = (state == S_HEAD) || (state == S_IDLE && (needs_split || amo_en))
                   || (state == S_AMO && (amo_wait || !amo_phase));

  // ---------------------------------------------------------------------------
  // 【关键修复】AMO 的相判断改为"由状态唯一决定", 不再用自翻转触发器
  // ---------------------------------------------------------------------------
  // 第一版写成:  `if (state == S_AMO) amo_wr <= ~amo_wr;`
  // 实测**直接挂死**。AMO_TRACE 诊断打印给出根因: `st=3 wr=x` ——
  //   amo_wr **从未复位**, 而 `~x` 仍是 `x`, 于是它永远停在 X:
  //   写相判断不出来 -> dmem_we 为 X -> dmem_wstrb 为 X ->
  //   状态机卡在 S_AMO 出不来 (lsu_stall 一直是 X)。
  //
  // 这与本项目反复出现的同类坑一致 (PITFALLS R6/R8: 未初始化的状态被当成
  // "反正不会发生"): **多周期状态机的每个派生信号都必须有确定值**。
  //
  // 新写法: 用两个**复位过的**寄存器组成明确的两相 ——
  //   amo_phase : 0 = 读相(送地址读旧值), 1 = 写相(写新值)
  //   amo_active: 1 = AMO 序列进行中 (跨多拍保持, 因为 state 会停在 S_AMO)
  // 由 state 与这两个寄存器组合出 amo_wr, 不可能为 X。
  assign amo_wr = amo_active & amo_phase;
  assign amo_write_phase = amo_wr;

  // AMO 读回的旧值: 写相那拍 amo_old 已有效, core 用它算新值
  assign amo_old_out = amo_old;

  // (诊断打印已移除 —— 结论写进 results/p6-a-extension.md 第 5.11 节)

  // ---------------- load 路径 (WB 段组合) ----------------
  // 【RR2: 64 位桶形移位器 -> 2 位 off_wb 直选 4:1 字节通道】
  // 原写法: raw64 = split ? {rdata_eff, head_word_r} : {32'b0, rdata_eff},
  //         再 (raw64 >> {off_wb,3'b000})[31:0] —— 移位量只有 0/8/16/24 四种取值,
  //         却落成一棵 64 位、3 级 (8/16/32) 的可变移位树。
  // 新写法: 只做"取 4 个连续字节", 硬件就是一层 4:1 mux (选择信号 = off_wb[1:0]),
  //         没有任何移位级联。**逐位等价**已被穷举验证 (6,750,000 组
  //         rd/head/off/size/uns/split 组合, 0 处不一致; 见 .rr2_scratch/check_equiv.py)。
  //
  // 【为什么 split 要嵌进每一个字节】非 split 时 raw64 = {32'b0, rdata_eff},
  // 高 32 位是 0(不是 head_word_r), 所以 s0 = {s0_hi, rdata_eff} —— 否则
  // head_word_r 会从上方"漏"进低 4 字节, head=0xFFFFFFFF 时直接算错。
  //
  // 关键路径实测 (基线 top-1): u_lsu/rdata[31] -> [LUT5] -> net raw64[31] fo=4
  //   布线 1.040ns (占该跳 91%) -> [LUT6] mem_load_data[7]; 该 net 的 4 个负载
  //   就是桶形移位器里"bit31 会落到哪一位"的 4 个候选 LUT。本改动把那 4 个
  //   候选收敛成 1 个 4:1 字节 mux, 同时消掉移位树本身。
  // AMO 的"读回值"走同一条路: 旧值在 amo_old 里, 且 off/size 已按字对齐设好,
  // 所以下面的字节选择与符号扩展对它是恒等操作。
`ifdef A_EN
  wire [31:0] rdata_eff = amo_mode_r ? amo_old : dmem_rdata;
`else
  // A_EN 关闭时 amo_mode_r 恒为 0 (它只可能被 amo_en 置起, 见下面的时序段),
  // 所以这个 mux 对数据路是恒等的 —— 直接从数据路上摘掉, 少一级、少一根网。
  wire [31:0] rdata_eff = dmem_rdata;
`endif

  // 64 位"虚拟字", 顺序**逐位照抄基线**: raw64 = split ? {rdata_eff, head_word_r}
  //                                                  : {32'b0,    rdata_eff}
  // 即 **head_word_r 在低位端 (字节 0..3)** —— 因为跨字访问是从 head_addr 读起的,
  // head_word_r 就是低地址那半。反过来放会让所有跨字(非对齐)访存字节反序:
  // 实测 lw(off=2) 读回 0xCCDD1122 而不是 0x3344AABB。
  // 【必须声明成 64 位】写成 32 位时高 32 位被静默截断
  // (ModelSim: vopt-2697 "MSB 39 of part-select into 's0' is out of bounds")。
  wire [63:0] s0 = split_wb ? {rdata_eff, head_word_r}
                            : {32'b0,    rdata_eff};

  // 按 off_wb 取 {s0[8*off_wb +: 32]} —— 即基线的 (raw64 >> {off_wb,3'b000})[31:0]:
  // 注意每一档是"高 8 位 + 接下来的 24 位"(跨字节边界), 不是 8+8+8+8 地对齐:
  //   off=1 -> s0[39:8]  = {s0[39:32], s0[31:8]}
  //   off=2 -> s0[47:16] = {s0[47:40], s0[39:16]}
  //   off=3 -> s0[55:24] = {s0[55:48], s0[47:24]}
  // 一层 4:1 选择, 没有任何移位级联。
  // 【实测警告】这几行的位下标错了两次, 每次都是**每个字节错位**的静默错误:
  // 误写成 {s0[39:32],s0[31:24]} 时 lh(off=1) 读回 0x000000AA 而不是 0x00AABBCC
  // (应为 0xFFFFBBCC), tb_core_basic 组 4 挂。改这几行必须重跑 verify。
  wire [31:0] wr_off0 = s0[31:0];
  wire [31:0] wr_off1 = {s0[39:32], s0[31:8]};
  wire [31:0] wr_off2 = {s0[47:40], s0[39:16]};
  wire [31:0] wr_off3 = {s0[55:48], s0[47:24]};
  wire [31:0] load_raw = (off_wb == 2'd0) ? wr_off0
                       : (off_wb == 2'd1) ? wr_off1
                       : (off_wb == 2'd2) ? wr_off2
                                          : wr_off3;

  always_comb begin
    case (size_wb)
      MEM_BYTE: load_data = uns_wb ? {24'b0, load_raw[7:0]}
                                   : {{24{load_raw[7]}}, load_raw[7:0]};
      MEM_HALF: load_data = uns_wb ? {16'b0, load_raw[15:0]}
                                   : {{16{load_raw[15]}}, load_raw[15:0]};
      default:  load_data = load_raw;
    endcase
  end

  // ---------------- 时序 ----------------
  always_ff @(posedge clk or posedge rst) begin
    if (rst) begin
      state      <= S_IDLE;
      // 【AMO 相关寄存器必须一起复位】第一版漏了 amo_wr, 而它的自翻转写法
      // (`~x` = `x`) 让整个状态机卡死 (诊断打印: st=3 wr=x)。
      amo_active <= 1'b0;
      amo_wait   <= 1'b0;
      amo_phase  <= 1'b0;
      amo_old    <= 32'd0;
      amo_addr_r <= 32'd0;
      amo_mode_r <= 1'b0;
      head_word_r<= 32'd0;
      off_wb     <= 2'd0;
      size_wb    <= MEM_WORD;
      uns_wb     <= 1'b0;
      split_wb   <= 1'b0;
    end
    else begin
      case (state)
        S_IDLE:  if (amo_en)         state <= S_AMO;
                 else if (needs_split) state <= S_HEAD;
        S_HEAD:  state <= S_TAIL;
        S_AMO:   state <= amo_phase ? S_IDLE : S_AMO;   // 写相做完就放行
        default: state <= S_IDLE;
      endcase

      // ---- AMO 相位推进 (全部复位过, 不会出现 X) ----
      // 时序 (地址在启动拍就已送到 dmem):
      //   启动拍  : state=S_IDLE, amo_en=1 -> 下一拍进 S_AMO, amo_wait=1
      //   等待拍  : state=S_AMO, amo_wait=1 -> dmem 的寄存读数据在**本拍末**有效,
      //             所以这一拍末尾捕获 amo_old, 并清 amo_wait
      //   读相    : state=S_AMO, amo_wait=0, amo_phase=0 -> 本拍 amo_old 已有效,
      //             新值算得出来; 但**先不写**, 只推进到写相
      //   写相    : state=S_AMO, amo_phase=1 -> 写新值, 本拍放行, 下一拍回 IDLE
      // 【为什么要"等待 + 读相"两拍而不是一拍】dmem 是寄存读, 地址第 N 拍、
      // 数据第 N+1 拍; 而"新值"要靠数据才能算, 所以必须至少留一拍给数据、
      // 再留一拍给写。
      if (state == S_IDLE && amo_en) begin
        amo_active <= 1'b1;
        amo_wait   <= 1'b1;             // 先去等数据
        amo_phase  <= 1'b0;
        amo_addr_r <= head_addr;        // 锁存字地址 (字对齐), 全程都用它
      end
      else if (state == S_AMO) begin
        if (amo_wait)      begin amo_wait  <= 1'b0; end          // 数据到手
        else if (!amo_phase) begin amo_phase <= 1'b1; end        // 转写相
        else               begin amo_active <= 1'b0; end         // 收工
      end

      // 头字捕获: HEAD 拍末尾 dmem_rdata 就是头字
      if (state == S_HEAD) head_word_r <= dmem_rdata;
      // 【AMO 旧值捕获 —— 采样时机是本轮的关键修复】
      // dmem 是**寄存读**: 地址第 N 拍, 数据第 N+1 拍有效。
      // AMO 在启动拍就把地址送到 dmem 了, 所以数据在**等待拍**末尾有效。
      // 实测证据 (core.sv 的 [rd] 诊断打印):
      //   t=145000 addr=90003114 rdata=00000000   <- 启动拍, 数据还没出来
      //   t=155000 (等待拍) 才是有效数据
      // 原先在"读相"采样, 采到的必然是 0 -> amo_old 恒 0 -> 新值恒错。
      if (state == S_AMO && amo_wait) amo_old <= dmem_rdata;

      // 请求离开 MEM 那一拍, 记下它的规格给 WB 段用。
      // 【AMO 必须在启动那拍就记】因为放行发生在 S_AMO 的写相, 而那时
      // req_* 已经不是 AMO 的请求了 (amo_en 只在启动拍有效)。
      if (amo_en) begin
        off_wb     <= 2'd0;            // AMO 一律字对齐字访问
        size_wb    <= MEM_WORD;
        uns_wb     <= 1'b0;
        split_wb   <= 1'b0;
        amo_mode_r <= 1'b1;            // 让 WB 拍 load_data 选 amo_old
      end
      else begin
        // 【amo_mode_r 必须保持整个 AMO 序列, 不能下一拍就清】
        // 它让 WB 拍选 amo_old (AMO 的旧值) 而不是 dmem_rdata。
        // 原写法在 else 里无条件清 0 —— 而 amo_en 只在启动拍有效, 于是
        // **下一拍就被清掉了**, 等到真正的 WB 拍它已经是 0,
        // WB 去读 dmem_rdata (那时 dmem 上早就是别的地址) -> rd 错误。
        // 新写法: 只要 AMO 序列还在进行 (amo_active), 就保持为 1;
        // 序列收尾 (amo_active=0) 那一拍才落下 —— 正好在 WB 之后。
        if (amo_active) amo_mode_r <= 1'b1;
        else            amo_mode_r <= 1'b0;
        // 【不要给这里加 `!(state == S_AMO)` 守卫 —— 那是我上一轮引入的错】
        // 理由: "请求离开 MEM"那一拍**正是 AMO 的写相** (state 还是 S_AMO,
        // 写相把 lsu_stall 拉低放行)。加了 `!(state==S_AMO)` 就导致
        // **紧随 AMO 之后那条指令的 off_wb/size_wb/uns_wb/split_wb 永远不被锁存**,
        // 于是它的字节提取/符号扩展用的是上一条的规格 —— 表现为"AMO 之后那条
        // lw 读回 0"(实际是真值被错误地按旧规格截取/扩展掉了)。
        // 这正是 amoor 组失败的真正原因 (前面几轮一直在查写通路, 方向错了)。
        if ((req_read || req_write) && !lsu_stall) begin
          off_wb   <= off;
          size_wb  <= req_size;
          uns_wb   <= req_unsigned;
          split_wb <= needs_split;
        end
      end
    end
  end

endmodule
