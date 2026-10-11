# ============================================================================
# daVinciPro.xdc — 正点原子 达芬奇Pro (XC7A100T-FGG484) 引脚与时序约束
# 引脚取值直接来自厂商文件 DaVinci_Pro_PIN.xdc, 未做任何猜测。
# ============================================================================

# ---- 时序: 板载 50 MHz 系统时钟 ----
create_clock -period 20.000 -name sys_clk [get_ports sys_clk]

# ---- 时序: MMCM 输出的核心时钟 (top_a100t.sv 的 u_bufg_sys/O) ----
# 约束写法与 RTL 里的 MMCME2_BASE 逐项对齐, 不做人脑换算:
#   RTL   : CLKFBOUT_MULT_F = 21.0, DIVCLK_DIVIDE = 1, CLKOUT0_DIVIDE_F = 8.0
#   XDC   : -multiply_by 21 -divide_by 8   ->  50 MHz * 21 / 8 = 131.25 MHz
#   阶梯记录(全部实测): VCO 1050 + N=14/11/10/8 -> 75 / 95.45 / 105 / 131.25 MHz
#   131.25 档实测 WNS -0.173(差 0.173ns ⇒ 时序门已拒绝写 bitstream), 达成 fmax 128.34;
#   对照组 125MHz(VCO1000+N=8) 只达成 119.6 ⇒ **约束与工具结果是非单调的**,
#   所以选档要看"达成 fmax"而不是"目标更低就更保险"。
# 时钟名从 sys_clk_75 改成**频率无关**的 sys_clk_core: 本轮在阶梯上迭代,
#   名字里带频率会每改一次档就过期一次(本工程最忌讳的"标签与事实不一致")。
# 周期 = 1/131.25 MHz = 7.619 ns. 下面这行是**声明性**的:
#   它告诉 STA "这个 net 是 sys_clk 的 21/14 倍频", 相位与 sys_clk 对齐,
#   跨时钟域路径 (keyin 50 MHz 域 -> 75 MHz 域, 目前没有功能通路) 因此可分析。
# 用 create_generated_clock 而不是 create_clock -period 13.333: 前者带
#   -source 关系, 工具会把相位/抖动与源时钟关联; 后者会造出一个与源无关的
#   新时钟, 跨域路径会被当成异步路径而**不再被分析** (静默丢掉检查)。
# -source 必须给**端口/引脚**对象, 不能给 clock 对象:
#   实测 [get_clocks sys_clk] 会报
#     CRITICAL WARNING [Constraints 18-611/18-612]:
#     "list of objects specified for option 'source' contains '1' objects of
#      types '(clock)' other than the types '(port,pin)' supported" -> 约束不生效,
#     时钟会退回 Vivado 自动推导名 (实测叫 sys_clk_raw), 报告里看不到 sys_clk_75。
#   改成 [get_ports sys_clk] (与上面 create_clock 的源是同一个对象) 才成立。
# 该行不得含非 ASCII 字符, 否则 Vivado 2018.3 可能解析失败。
create_generated_clock -name sys_clk_core \
  -source [get_ports sys_clk] \
  -multiply_by 75 -divide_by 32 \
  [get_pins u_bufg_sys/O]

# ---- 引脚 ----
set_property -dict {PACKAGE_PIN R4 IOSTANDARD LVCMOS15} [get_ports sys_clk]
set_property -dict {PACKAGE_PIN U7 IOSTANDARD LVCMOS15} [get_ports sys_rst_n]

set_property -dict {PACKAGE_PIN V9 IOSTANDARD LVCMOS15} [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN Y8 IOSTANDARD LVCMOS15} [get_ports {led[1]}]
set_property -dict {PACKAGE_PIN Y7 IOSTANDARD LVCMOS15} [get_ports {led[2]}]
set_property -dict {PACKAGE_PIN W7 IOSTANDARD LVCMOS15} [get_ports {led[3]}]

set_property -dict {PACKAGE_PIN D17 IOSTANDARD LVCMOS33} [get_ports uart_txd]
set_property -dict {PACKAGE_PIN E14 IOSTANDARD LVCMOS33} [get_ports uart_rxd]

# ---- R4 不是专用时钟引脚, 厂商 XDC 同样需要这一行 ----
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets sys_clk]

# ---- 未使用引脚不驱动 (避免误报) ----
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLNONE [current_design]
