import argparse
import csv
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parent
LCD_HEADERS = {
    "J11": "AC26 AB26 Y26 W25 W23 V23 W26 V26 AC24 AB24 Y21 W21 T15 T14 Y20 W20 "
           "AB25 AA24 AA23 AA22 W19 V19 U16 U15 V14 U14 U22 V22 W24 V24 N18 U24".split(),
    "J12": "A17 A18 B19 A19 D18 C18 D19 C19 B20 A20 C21 B21 B22 A22 C22 C23 "
           "H16 G16 G17 F17 E17 E18 F18 F19 E20 D20 E21 D21 A23 A24 C24 B24".split(),
}
CAMERA = [
    ("cam_scl", "OUTPUT", 4, "Y23", "CMOS_SCL", 3, "SIO_C"),
    ("cam_sda", "INOUT", 6, "V18", "CMOS_SDA", 4, "SIO_D"),
    ("cam_vsync", "INPUT", 3, "W18", "CMOS_VSYNC", 5, "VSYNC"),
    ("cam_rclk", "OUTPUT", 16, "Y22", "CMOS_PCLK", 18, "FIFO_RCK"),
    ("cam_we", "OUTPUT", 5, "V16", "CMOS_HREF", 19, "FIFO_WR"),
    ("cam_oe_n", "OUTPUT", 7, "V17", "CMOS_RESET", 20, "FIFO_OE_N"),
    ("cam_wrst_n", "OUTPUT", 18, "Y25", "CMOS_PWDN", 21, "FIFO_WRST_N"),
    ("cam_rrst_n", "OUTPUT", 17, "AA25", "CMOS_XCLK", 22, "FIFO_RRST_N"),
]
CAMERA_DATA_BALLS = "T17 U19 T18 T19 U20 V21 T20 U21".split()
DVP18_CAMERA = [
    ("cam_scl", "OUTPUT", 3, "W18", "CMOS_VSYNC", "SCL"),
    ("cam_sda", "INOUT", 4, "Y23", "CMOS_SCL", "SDA"),
    ("cam_vsync", "INPUT", 5, "V16", "CMOS_HREF", "VS"),
    ("cam_href", "INPUT", 6, "V18", "CMOS_SDA", "HS"),
    ("cam_pclk", "INPUT", 7, "V17", "CMOS_RESET", "PCLK"),
    ("cam_xclk", "OUTPUT", 8, "T17", "CMOS_D0", "MCLK"),
    ("cam_reset_n", "OUTPUT", 17, "AA25", "CMOS_XCLK", "RESET"),
    ("cam_pwdn", "OUTPUT", 18, "Y25", "CMOS_PWDN", "PWDN"),
]
DVP18_DATA = [
    (16, "Y22", "CMOS_PCLK"), (15, "U21", "CMOS_D7"),
    (14, "T20", "CMOS_D6"), (13, "V21", "CMOS_D5"),
    (12, "U20", "CMOS_D4"), (11, "T19", "CMOS_D3"),
    (10, "T18", "CMOS_D2"), (9, "U19", "CMOS_D1"),
]


def pin_rows(lcd_header="J11", camera_interface="fifo"):
    if lcd_header not in LCD_HEADERS:
        raise ValueError("LCD header must be J11 or J12")
    rows = []

    def add(port, direction, ball, connector, pin, net, peripheral, peripheral_pin, signal, voltage="3.3"):
        rows.append(dict(port=port, direction=direction, ball=ball, voltage=voltage,
                         board_connector=connector, board_pin=str(pin), board_net=net,
                         peripheral=peripheral, peripheral_pin=str(peripheral_pin), signal=signal))

    add("sys_clk", "INPUT", "R3", "CORE", "50MHz", "SYS_CLK", "BOARD", "", "50MHz oscillator", "1.5")
    add("reset_n", "INPUT", "G25", "SW2", "", "RESET", "BOARD", "", "Reset active low")
    for index, ball in enumerate("K25 K26 P26 R26".split()):
        add(f"keys_n[{index}]", "INPUT", ball, f"SW{index+4}", "", f"KEY{index+1}",
            "BOARD", "", f"KEY{index+1} active low")
    for index, ball in enumerate("N23 N24 U26 U25".split()):
        add(f"led[{index}]", "OUTPUT", ball, f"LED{index+2}", "", f"LED{index+1}",
            "BOARD", "", f"LED{index+1} active high")
    add("uart_txd", "OUTPUT", "L24", "J9", "3-4", "UART_TX", "BOARD", "", "FPGA TX to CH340 RXD")
    add("uart_rxd", "INPUT", "L25", "J9", "1-2", "UART_RX", "BOARD", "", "CH340 TXD to FPGA RX")
    lcd_signals = []
    for color in "rgb":
        lcd_signals.extend((f"lcd_{color}[{index}]", "OUTPUT", f"LCD_{color.upper()}{index}")
                           for index in range(8))
    lcd_signals.extend([
        ("lcd_dclk", "OUTPUT", "LCD_DCLK"), ("lcd_hsync", "OUTPUT", "LCD_HSYNC"),
        ("lcd_vsync", "OUTPUT", "LCD_VSYNC"), ("lcd_de", "OUTPUT", "LCD_DE"),
        ("touch_sclk", "OUTPUT", "SPI_DCLK"), ("touch_cs_n", "OUTPUT", "SPI_CS"),
        ("touch_mosi", "OUTPUT", "SPI_DIN"), ("touch_busy", "INPUT", "SPI_BUSY"),
    ])
    for pin, (ball, signal) in enumerate(zip(LCD_HEADERS[lcd_header], lcd_signals), start=3):
        port, direction, name = signal
        add(port, direction, ball, lcd_header, pin, name, "AN430 J3", pin, name)
    if camera_interface == "dvp18":
        for port, direction, pin, ball, net, signal in DVP18_CAMERA:
            add(port, direction, ball, "J7", pin, net, "OV7670 DVP18", pin, signal)
        for index, (pin, ball, net) in enumerate(DVP18_DATA):
            add(f"cam_data[{index}]", "INPUT", ball, "J7", pin, net,
                "OV7670 DVP18", pin, f"D{index}")
    elif camera_interface == "fifo":
        for port, direction, pin, ball, net, target, signal in CAMERA:
            add(port, direction, ball, "J7", pin, net, "OV7670 P1", target, signal)
        for index, ball in enumerate(CAMERA_DATA_BALLS):
            add(f"cam_data[{index}]", "INPUT", ball, "J7", index+8, f"CMOS_D{index}",
                "OV7670 P1", 14-index, f"D{index}")
    else:
        raise ValueError("Camera interface must be fifo or dvp18")
    if len(rows) != 60 or len({row["port"] for row in rows}) != 60 or len({row["ball"] for row in rows}) != 60:
        raise ValueError("Expected 60 unique FPGA ports and balls")
    return rows


def generate(lcd_header="J11", destination=ROOT, system_clock_hz=27000000, camera_interface="fifo", cpu_clock_hz=None):
    if cpu_clock_hz not in [None, 125000000]:
        raise ValueError("The independent CPU PLL supports 125 MHz")
    if system_clock_hz not in [27000000, 50000000]:
        raise ValueError("Supported system clocks are 27 MHz and 50 MHz")
    if camera_interface == "dvp18" and system_clock_hz != 50000000:
        raise ValueError("The oversampled DVP18 receiver requires the 50 MHz system clock")
    rows = pin_rows(lcd_header, camera_interface)
    timing = """create_clock -name {clk50} [get_ports {sys_clk}] -period 20 -waveform {0 10}
create_generated_clock -name {clk27} -source [get_ports {sys_clk}] -multiply_by 27 -divide_by 50 [get_pins {clock_gen/pll/CLKOUT0}]
create_generated_clock -name {lcd_pixel} -source [get_pins {clock_gen/pll/CLKOUT0}] -divide_by 3 [get_ports {lcd_dclk}]
set_output_delay -clock [get_clocks {lcd_pixel}] -max 10 [get_ports {lcd_r[*] lcd_g[*] lcd_b[*] lcd_hsync lcd_vsync lcd_de}]
set_output_delay -clock [get_clocks {lcd_pixel}] -min 2 [get_ports {lcd_r[*] lcd_g[*] lcd_b[*] lcd_hsync lcd_vsync lcd_de}]
"""
    if camera_interface == "fifo":
        timing += """
set_input_delay -clock [get_clocks {clk27}] -max 80 [get_ports {cam_data[*]}]
set_input_delay -clock [get_clocks {clk27}] -min 5 [get_ports {cam_data[*]}]
set_multicycle_path 3 -setup -from [get_ports {cam_data[*]}]
set_multicycle_path 2 -hold -from [get_ports {cam_data[*]}]
set_output_delay -clock [get_clocks {clk27}] -max 10 [get_ports {cam_rclk}]
set_output_delay -clock [get_clocks {clk27}] -min 0 [get_ports {cam_rclk}]
set_false_path -from [get_ports {reset_n keys_n[*] uart_rxd cam_sda cam_vsync touch_busy}]
set_false_path -to [get_ports {led[*] uart_txd touch_sclk touch_cs_n touch_mosi cam_scl cam_sda cam_we cam_oe_n cam_wrst_n cam_rrst_n}]

"""
    else:
        timing += """create_generated_clock -name {camera_mclk} -source [get_ports {sys_clk}] -divide_by 4 [get_ports {cam_xclk}]
set_false_path -from [get_ports {reset_n keys_n[*] uart_rxd cam_sda touch_busy}]
set_false_path -from [get_ports {cam_pclk cam_href cam_vsync cam_data[*]}] -to [get_cells {capture/pclk_sync[0] capture/href_sync[0] capture/vsync_sync[0] capture/data_meta[*]}]
set_false_path -to [get_ports {led[*] uart_txd touch_sclk touch_cs_n touch_mosi cam_scl cam_sda cam_reset_n cam_pwdn}]

"""
    if system_clock_hz == 50000000:
        timing = timing.replace("-clock [get_clocks {clk27}]", "-clock [get_clocks {clk50}]")
        timing = timing.replace("set_multicycle_path 3 -setup", "set_multicycle_path 6 -setup")
        timing = timing.replace("set_multicycle_path 2 -hold", "set_multicycle_path 5 -hold")
        timing += """set_false_path -to [get_cells {video_bridge/request_meta video_bridge/acknowledge_meta video_bridge/frame_meta framebuffer/request_meta framebuffer/acknowledge_meta framebuffer/valid_meta}]
set_false_path -to [get_pins {video_reset_sync[*]/P framebuffer/reset_sync[*]/P}]
set_max_delay 20 -datapath_only -from [get_cells {video_bridge/held_payload[*]}] -to [get_cells {video_bridge/pending_payload[*]}]
set_min_delay 0 -from [get_cells {video_bridge/held_payload[*]}] -to [get_cells {video_bridge/pending_payload[*]}]

"""
    if cpu_clock_hz is not None:
        timing += """create_generated_clock -name {cpu125} -source [get_ports {sys_clk}] -multiply_by 5 -divide_by 2 [get_pins {cpu_clock_gen/pll/CLKOUT0}]
set_false_path -to [get_cells {system/cpu_bus/request_meta system/cpu_bus/response_meta}]
set_false_path -to [get_pins {cpu_reset_sync[*]/P}]
set_max_delay 20 -datapath_only -from [get_cells {system/cpu_bus/held_request[*]}] -to [get_cells {system/cpu_bus/active_request[*]}]
set_min_delay 0 -from [get_cells {system/cpu_bus/held_request[*]}] -to [get_cells {system/cpu_bus/active_request[*]}]
set_max_delay 8 -datapath_only -from [get_cells {system/cpu_bus/held_response[*]}] -to [get_cells {system/cpu_bus/response_data[*]}]
set_min_delay 0 -from [get_cells {system/cpu_bus/held_response[*]}] -to [get_cells {system/cpu_bus/response_data[*]}]

"""
    for row in rows:
        attributes = [("PAP_IO_LOC", row["ball"]), ("PAP_IO_STANDARD", "LVCMOS15" if row["voltage"] == "1.5" else "LVCMOS33"),
                      ("PAP_IO_VCCIO", row["voltage"]), ("PAP_IO_DIRECTION", row["direction"])]
        if row["direction"] == "OUTPUT":
            attributes.extend([("PAP_IO_DRIVE", "4"), ("PAP_IO_SLEW", "SLOW")])
        if row["port"] in ["reset_n", "uart_rxd", "cam_sda"] or row["port"].startswith("keys_n["):
            attributes.append(("PAP_IO_PULLUP", "TRUE"))
        for attribute, value in attributes:
            timing += f"define_attribute {{p:{row['port']}}} {{{attribute}}} {{{value}}}\n"
    (destination / "pg2l100h_camera_lcd.fdc").write_text(timing, encoding="utf-8")
    with (destination / "wiring.csv").open("w", encoding="utf-8-sig", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    (destination / "pinout.json").write_text(json.dumps(dict(lcd_header=lcd_header, camera_interface=camera_interface, pins=rows), indent=2)+"\n", encoding="utf-8")
    camera_description = "J7 为 18 针，22 针 AL422 FIFO 模块须按本表转接；电源为J7-1的3.3 V和J7-2的GND。"
    camera_power = "| OV7670 P1-1，VCC | J7-1，3.3 V |\n| OV7670 P1-2，GND | J7-2，GND |\n| OV7670 P1-15，RESET | 3.3 V |\n| OV7670 P1-16，PWDN | GND |\n| OV7670 P1-6，HREF；P1-17，STROBE | 不接，FIFO写入由模块HREF门控 |"
    if camera_interface == "dvp18":
        camera_description = "对应用户实拍18针DVP模块，假定模块P1与J7按1至18脚一一对应。以1脚方焊盘及3.3 V/GND为方向依据，背面视图左右镜像。模块SCL/SDA、VS/HS、PCLK/MCLK及D7至D0顺序与底板原网络名称不同，下表已按实物重新分配FPGA球号。当前不使用AL422控制信号。"
        camera_power = "| OV7670 DVP18 P1-1，3.3 V | J7-1，3.3 V |\n| OV7670 DVP18 P1-2，GND | J7-2，GND |\n| OV7670 DVP18 P1-17，RESET | J7-17，AA25，FPGA低有效复位 |\n| OV7670 DVP18 P1-18，PWDN | J7-18，Y25，FPGA固定输出0 |\n| OV7670 DVP18 P1-8，MCLK | J7-8，T17，12.5 MHz |"
    markdown = f"""# PG2L100H 接线表（LCD：{lcd_header}）

由 `generate_pins.py` 生成。依据 `ebf_pg2l100h_demo/EBF_PG2L100H676_BASEBOARD_SCH.pdf` 第 3、7、8 页，球号再与第 2、3 页 BTB 连接器对照。时钟依据同目录 HDMI 示例的 `hdmi_colorbar.fdc`。

## 摄像头接口：{camera_interface}

{camera_description}

| 板上接口 | 脚号 | 原理图网络 | FPGA 球号 | RTL 端口 | FPGA 方向 | 外设 | 外设脚号 | 外设信号 |
|---|---:|---|---|---|---|---|---:|---|
"""
    fields = ["board_connector", "board_pin", "board_net", "ball", "port", "direction", "peripheral", "peripheral_pin", "signal"]
    for row in rows:
        if row["peripheral"] != "BOARD":
            markdown += "| " + " | ".join(row[field] for field in fields) + " |\n"
    markdown += f"""
## 电源、固定电平与未使用的脚

| 外设脚 | 连接 |
|---|---|
{camera_power}
| AN430 J3-1、37、38，GND | {lcd_header} 同号脚 |
| AN430 J3-2，VCC5V | {lcd_header}-2，5 V；只给模块供电 |
| AN430 J3-39、40，D3V3 | 板端同号脚为 3.3 V；须先确认 AN430 实物电源方向，见 README |
| AN430 J3-35，SPI_DOUT；36，PENIRQ | 本工程不读取；J11 同号脚本来就是 NC，J12 也不分配这两个输入 |

LCD 使用完整 R0～R7、G0～G7、B0～B7，同号连线。32 路 LCD GPIO 加 16 路摄像头 GPIO，共 48 路板外信号。SPI_CS 保持高电平，触摸控制器不被访问。

J11 的 35、36 脚在底板原理图中为 NC，不能借这两脚读取触摸数据。J12 的 35、36 脚为 E22、H17，本版为统一调试功能同样不读取。

J9 跳帽：1-2、3-4 接通后，CH340 才与 FPGA UART 相连。SW2 是逻辑复位；SW3 是 FPGA_CONFIG_N，不能当功能按键使用。

## 板载信号

| 器件 | 网络 | 球号 | RTL 端口 | 电平 |
|---|---|---|---|---|
"""
    for row in rows:
        if row["peripheral"] == "BOARD":
            markdown += f"| {row['board_connector']} | {row['board_net']} | {row['ball']} | {row['port']} | {row['voltage']} V |\n"
    (destination / "WIRING.md").write_text(markdown, encoding="utf-8")
    print(f"Generated {len(rows)} unique pins: LCD {lcd_header}, camera J7, 48 external GPIOs")
    return rows


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Generate PG2L100H camera/LCD constraints and wiring")
    parser.add_argument("--lcd-header", choices=sorted(LCD_HEADERS), default="J11")
    parser.add_argument("--camera-interface", choices=["fifo", "dvp18"], default="fifo")
    args = parser.parse_args()
    generate(args.lcd_header, system_clock_hz=50000000 if args.camera_interface == "dvp18" else 27000000,
             camera_interface=args.camera_interface)
