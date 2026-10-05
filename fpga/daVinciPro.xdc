# ============================================================================
# daVinciPro.xdc — 正点原子 达芬奇Pro (XC7A100T-FGG484) 引脚与时序约束
# 引脚取值直接来自厂商文件 DaVinci_Pro_PIN.xdc, 未做任何猜测。
# ============================================================================

# ---- 时序: 板载 50 MHz 系统时钟 ----
create_clock -period 20.000 -name sys_clk [get_ports sys_clk]

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
