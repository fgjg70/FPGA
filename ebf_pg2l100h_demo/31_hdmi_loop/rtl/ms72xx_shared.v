`timescale 1ns/1ps
// The baseboard connects MS7200 and MS7210 to a single control bus.
module ms72xx_shared(input clk,input rst_n,output init_over,output scl,inout sda);
    wire rx_done,tx_done;
    reg tx_active;
    reg rx_pending,tx_pending,rx_previous,tx_previous;
    reg owner,inflight,busy_seen,start;
    wire [7:0] rx_id,tx_id,rx_data,tx_data,read_data;
    wire [15:0] rx_addr,tx_addr;
    wire rx_trigger,tx_trigger,rx_write,tx_write,busy,byte_over;
    wire sda_out,sda_enable;
    wire rx_busy=rx_pending || (inflight && !owner);
    wire tx_busy=tx_pending || (inflight && owner);
    // Queue both controllers' requests; retain ownership through the STOP.
    // This also allows RX frequency polling after TX initialization.
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin
            rx_pending<=0;tx_pending<=0;rx_previous<=0;tx_previous<=0;
            owner<=1;inflight<=0;busy_seen<=0;start<=0;
        end else begin
            rx_previous<=rx_trigger;tx_previous<=tx_trigger;start<=0;
            if (rx_trigger && !rx_previous) rx_pending<=1;
            if (tx_trigger && !tx_previous) tx_pending<=1;
            if (inflight) begin
                if (busy) busy_seen<=1;
                if (busy_seen && !busy) begin inflight<=0;busy_seen<=0;end
            end else if (!busy && (rx_pending || tx_pending)) begin
                owner<=tx_pending && (!rx_pending || !owner);
                if (tx_pending && (!rx_pending || !owner)) tx_pending<=0;
                else rx_pending<=0;
                inflight<=1;start<=1;
            end
        end
    always @(posedge clk or negedge rst_n)
        if (!rst_n) tx_active<=0;
        else if (rx_done && !busy) tx_active<=1;
    assign init_over=tx_active && tx_done;
    ms7200_ctl rx(
        .clk(clk),.rstn(rst_n),.init_over(rx_done),.device_id(rx_id),
        .iic_trig(rx_trigger),.w_r(rx_write),.addr(rx_addr),.data_in(rx_data),
        .busy(rx_busy),.data_out(read_data),.byte_over(inflight && !owner && byte_over));
    ms7210_ctl tx(
        .clk(clk),.rstn(rst_n && tx_active),.init_over(tx_done),.device_id(tx_id),
        .iic_trig(tx_trigger),.w_r(tx_write),.addr(tx_addr),.data_in(tx_data),
        .busy(tx_busy),.data_out(read_data),.byte_over(inflight && owner && byte_over));
    iic_dri #(.CLK_FRE(27'd10_000_000),.IIC_FREQ(20'd400_000),
        .T_WR(10'd1),.ADDR_BYTE(2'd2),.LEN_WIDTH(8'd3),.DATA_BYTE(2'd1)) driver(
        .clk(clk),.rstn(rst_n),.pluse(start),
        .device_id(owner ? tx_id : rx_id),.w_r(owner ? tx_write : rx_write),
        .byte_len(4'd1),.addr(owner ? tx_addr : rx_addr),
        .data_in(owner ? tx_data : rx_data),.busy(busy),.byte_over(byte_over),
        .data_out(read_data),.scl(scl),.sda_in(sda),.sda_out(sda_out),.sda_out_en(sda_enable));
    assign sda=(sda_enable && !sda_out) ? 1'b0 : 1'bz;
endmodule
