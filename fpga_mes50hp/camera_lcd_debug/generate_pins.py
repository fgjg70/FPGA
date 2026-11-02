import csv
from pathlib import Path


ROOT = Path(__file__).resolve().parent
HEADER_BALLS = [
    "AB13", "Y13", "AB11", "Y11", "W11", "V11", "AB10", "AA10",
    "Y10", "W10", "T11", "R11", "Y12", "W12", "U12", "T12",
    "U10", "T10", "AB9", "Y9", "V9", "U9", "U8", "T8", "W8",
    "V7", "AB8", "AA8", "Y6", "W6", "AB5", "Y5", "AB4", "AA4",
]
PMOD_BALLS = ["AB6", "AA6", "AB7", "Y7", "Y8", "W9", "U6", "T7"]


def pin_rows():
    rows = []

    def add(port, ball, direction, connector, pin, peripheral, target, signal):
        rows.append(dict(port=port, ball=ball, direction=direction,
                         board_connector=connector, board_pin=str(pin),
                         peripheral=peripheral, peripheral_pin=str(target), signal=signal))

    add("clk_27m", "K21", "INPUT", "ONBOARD", "27MHz", "BOARD", "", "27MHz")
    add("reset_n", "K18", "INPUT", "ONBOARD", "KEY1", "BOARD", "", "reset active low")
    for index, ball in enumerate(["L15", "J17", "K16", "J16", "J19", "H20"]):
        add(f"keys_n[{index}]", ball, "INPUT", "ONBOARD", f"KEY{index+2}", "BOARD", "", "key active low")
    for index, ball in enumerate(["B2", "A2", "B3", "A3", "C5", "A5", "F7", "F8"]):
        add(f"led[{index}]", ball, "OUTPUT", "ONBOARD", f"LED{index+1}", "BOARD", "", "LED active high")
    add("uart_rxd", "R8", "INPUT", "ONBOARD", "USB-UART", "BOARD", "", "FPGA RX")
    add("uart_txd", "R9", "OUTPUT", "ONBOARD", "USB-UART", "BOARD", "", "FPGA TX")

    header = []
    for index in range(5):
        header.append((f"lcd_r[{index}]", "OUTPUT", "AN430 J3", 6+index, f"R{index+3}"))
    for index in range(6):
        header.append((f"lcd_g[{index}]", "OUTPUT", "AN430 J3", 13+index, f"G{index+2}"))
    for index in range(5):
        header.append((f"lcd_b[{index}]", "OUTPUT", "AN430 J3", 22+index, f"B{index+3}"))
    header.extend([
        ("lcd_dclk", "OUTPUT", "AN430 J3", 27, "LCD_DCLK"),
        ("lcd_hsync", "OUTPUT", "AN430 J3", 28, "LCD_HSYNC"),
        ("lcd_vsync", "OUTPUT", "AN430 J3", 29, "LCD_VSYNC"),
        ("lcd_de", "OUTPUT", "AN430 J3", 30, "LCD_DE"),
        ("touch_sclk", "OUTPUT", "AN430 J3", 31, "SPI_DCLK reserved, idle 0"),
        ("touch_cs_n", "OUTPUT", "AN430 J3", 32, "SPI_CS reserved, idle 1"),
        ("touch_mosi", "OUTPUT", "AN430 J3", 33, "SPI_DIN reserved, idle 0"),
        ("touch_busy", "INPUT", "AN430 J3", 34, "SPI_BUSY raw input"),
        ("touch_miso", "INPUT", "AN430 J3", 35, "SPI_DOUT raw input"),
        ("touch_irq_n", "INPUT", "AN430 J3", 36, "PENIRQ active low"),
        ("cam_scl", "OUTPUT", "OV7670 P1", 3, "SIO_C"),
        ("cam_sda", "INOUT", "OV7670 P1", 4, "SIO_D open drain"),
        ("cam_vsync", "INPUT", "OV7670 P1", 5, "VSYNC"),
        ("cam_rclk", "OUTPUT", "OV7670 P1", 18, "FIFO_RCK"),
        ("cam_we", "OUTPUT", "OV7670 P1", 19, "FIFO_WR / WR_CTR active high"),
        ("cam_oe_n", "OUTPUT", "OV7670 P1", 20, "FIFO_OE active low"),
        ("cam_wrst_n", "OUTPUT", "OV7670 P1", 21, "FIFO_WRST active low"),
        ("cam_rrst_n", "OUTPUT", "OV7670 P1", 22, "FIFO_RRST active low"),
    ])
    if len(header) != 34:
        raise ValueError("The 40-pin header must use exactly 34 GPIOs")
    for pin, (ball, mapping) in enumerate(zip(HEADER_BALLS, header), start=3):
        port, direction, peripheral, target, signal = mapping
        add(port, ball, direction, "40PIN J8 (manual drawing J16)", pin, peripheral, target, signal)
    for index, ball in enumerate(PMOD_BALLS):
        add(f"cam_data[{index}]", ball, "INPUT", "PMOD J12 (manual drawing J11)",
            index+1, "OV7670 P1", 14-index, f"D{index}")
    if len({row["ball"] for row in rows}) != len(rows):
        raise ValueError("Duplicate FPGA ball assignment")
    if len({row["port"] for row in rows}) != len(rows):
        raise ValueError("Duplicate port assignment")
    return rows


def generate():
    rows = pin_rows()
    timing = """create_clock -name {clk27} [get_ports {clk_27m}] -period {37.037037} -waveform {0 18.5185185}
create_generated_clock -name {lcd_pixel} -source [get_ports {clk_27m}] -divide_by 3 [get_ports {lcd_dclk}]
set_output_delay -clock [get_clocks {lcd_pixel}] -max 10 [get_ports {lcd_r[*] lcd_g[*] lcd_b[*] lcd_hsync lcd_vsync lcd_de}]
set_output_delay -clock [get_clocks {lcd_pixel}] -min 2 [get_ports {lcd_r[*] lcd_g[*] lcd_b[*] lcd_hsync lcd_vsync lcd_de}]
set_input_delay -clock [get_clocks {clk27}] -max 80 [get_ports {cam_data[*]}]
set_input_delay -clock [get_clocks {clk27}] -min 5 [get_ports {cam_data[*]}]
set_multicycle_path 3 -setup -from [get_ports {cam_data[*]}]
set_multicycle_path 2 -hold -from [get_ports {cam_data[*]}]
set_output_delay -clock [get_clocks {clk27}] -max 10 [get_ports {cam_rclk}]
set_output_delay -clock [get_clocks {clk27}] -min 0 [get_ports {cam_rclk}]
set_false_path -from [get_ports {reset_n keys_n[*] uart_rxd cam_sda cam_vsync touch_busy touch_miso touch_irq_n}]
set_false_path -to [get_ports {led[*] uart_txd touch_sclk touch_cs_n touch_mosi cam_scl cam_sda cam_we cam_oe_n cam_wrst_n cam_rrst_n}]

"""
    for row in rows:
        for attribute, value in [("PAP_IO_LOC", row["ball"]), ("PAP_IO_STANDARD", "LVCMOS33"),
                                 ("PAP_IO_VCCIO", "3.3"), ("PAP_IO_DIRECTION", row["direction"])]:
            timing += f"define_attribute {{p:{row['port']}}} {{{attribute}}} {{{value}}}\n"
    (ROOT / "mes50hp_camera_lcd.fdc").write_text(timing, encoding="utf-8")
    with (ROOT / "wiring.csv").open("w", encoding="utf-8-sig", newline="") as output:
        writer = csv.DictWriter(output, fieldnames=list(rows[0]))
        writer.writeheader()
        writer.writerows(rows)
    markdown = "# GPIO wiring\n\nGenerated by `generate_pins.py`; see README.md for power and fixed-level connections.\n\n"
    markdown += "The manual calls the 40-pin header J8 in text / J16 in its drawing, and PMOD J12 / J11. Match the actual board by pin number and FPGA ball.\n\n"
    markdown += "| Board connector | Pin | FPGA ball | RTL port | Direction at FPGA | Peripheral | Peripheral pin | Signal |\n"
    markdown += "|---|---:|---|---|---|---|---:|---|\n"
    for row in rows:
        if row["peripheral"] == "BOARD":
            continue
        markdown += "| " + " | ".join(row[field] for field in [
            "board_connector", "board_pin", "ball", "port", "direction", "peripheral", "peripheral_pin", "signal"
        ]) + " |\n"
    (ROOT / "WIRING.md").write_text(markdown, encoding="utf-8")
    print(f"Generated {len(rows)} pin assignments: 42 external GPIOs, 18 onboard signals")


if __name__ == "__main__":
    generate()
