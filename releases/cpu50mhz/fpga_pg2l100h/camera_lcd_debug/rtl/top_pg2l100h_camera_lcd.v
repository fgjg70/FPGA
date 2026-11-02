`timescale 1ns/1ps

module top_pg2l100h_camera_lcd (
    input wire sys_clk,
    input wire reset_n,
    input wire [3:0] keys_n,
    input wire uart_rxd,
    output wire uart_txd,
    output wire [3:0] led,
    output wire [7:0] lcd_r,
    output wire [7:0] lcd_g,
    output wire [7:0] lcd_b,
    output wire lcd_dclk,
    output wire lcd_hsync,
    output wire lcd_vsync,
    output wire lcd_de,
    output wire touch_sclk,
    output wire touch_cs_n,
    output wire touch_mosi,
    input wire touch_busy,
    output wire cam_scl,
    inout wire cam_sda,
    input wire cam_vsync,
    input wire [7:0] cam_data,
    output wire cam_rclk,
    output wire cam_we,
    output wire cam_oe_n,
    output wire cam_wrst_n,
    output wire cam_rrst_n
);
    wire clk_27m;
    wire pll_locked;
    wire [7:0] debug_led;
    wire [4:0] red_565;
    wire [5:0] green_565;
    wire [4:0] blue_565;

    pg2l100h_clock clock_gen (
        .clk_50m(sys_clk), .reset(!reset_n), .clk_27m(clk_27m), .locked(pll_locked)
    );

    assign lcd_r = {red_565, red_565[4:2]};
    assign lcd_g = {green_565, green_565[5:4]};
    assign lcd_b = {blue_565, blue_565[4:2]};
    assign led = debug_led[3:0];

    top_camera_lcd_debug debug (
        .clk_27m(clk_27m), .reset_n(reset_n && pll_locked),
        .keys_n({2'b11, keys_n}), .uart_rxd(uart_rxd), .uart_txd(uart_txd),
        .led(debug_led), .lcd_r(red_565), .lcd_g(green_565), .lcd_b(blue_565),
        .lcd_dclk(lcd_dclk), .lcd_hsync(lcd_hsync), .lcd_vsync(lcd_vsync), .lcd_de(lcd_de),
        .touch_sclk(touch_sclk), .touch_cs_n(touch_cs_n), .touch_mosi(touch_mosi),
        .touch_busy(touch_busy), .touch_miso(1'b0), .touch_irq_n(1'b1),
        .cam_scl(cam_scl), .cam_sda(cam_sda), .cam_vsync(cam_vsync), .cam_data(cam_data),
        .cam_rclk(cam_rclk), .cam_we(cam_we), .cam_oe_n(cam_oe_n),
        .cam_wrst_n(cam_wrst_n), .cam_rrst_n(cam_rrst_n)
    );
endmodule
