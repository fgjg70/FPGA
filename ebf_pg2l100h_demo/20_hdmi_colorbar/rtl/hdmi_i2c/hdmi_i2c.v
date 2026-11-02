`timescale 1ns / 1ps
// MS7210 control bus (PCSCL/PCSDA)
module hdmi_i2c (
    input wire sys_clk, // 50 MHz
    input wire sys_rst_n,
    output wire cfg_done,
    output wire sccb_scl,
    inout wire sccb_sda
);
    wire [7:0] device_id, data_in, data_out;
    wire [15:0] addr;
    wire trigger, write_read, busy, byte_over;
    wire sda_out, sda_out_en;
    ms7210_ctl controller (
        .clk(sys_clk), .rstn(sys_rst_n), .init_over(cfg_done),
        .device_id(device_id), .iic_trig(trigger), .w_r(write_read),
        .addr(addr), .data_in(data_in), .busy(busy),
        .data_out(data_out), .byte_over(byte_over)
    );
    iic_dri #(
        .CLK_FRE(27'd50_000_000), .IIC_FREQ(20'd400_000),
        .T_WR(10'd1), .ADDR_BYTE(2'd2),
        .LEN_WIDTH(8'd3), .DATA_BYTE(2'd1)
    ) driver (
        .clk(sys_clk), .rstn(sys_rst_n), .pluse(trigger),
        .device_id(device_id), .w_r(write_read), .byte_len(4'd1),
        .addr(addr), .data_in(data_in), .busy(busy),
        .byte_over(byte_over), .data_out(data_out), .scl(sccb_scl),
        .sda_in(sccb_sda), .sda_out(sda_out), .sda_out_en(sda_out_en)
    );
    // Release SDA for logic one and ACK/read cycles; board supplies pull-up.
    assign sccb_sda = (sda_out_en && !sda_out) ? 1'b0 : 1'bz;
endmodule
