`timescale 1ns/1ps
// Portable board checks. Uses a behavioral clock model, not the vendor PLL.
module clk_gen(input clkin1, input rst, output reg clkout0=0, output wire clkout0_n, output reg lock=0);
    assign clkout0_n = ~clkout0;
    always #(1000.0/148.5/2.0) clkout0 = ~clkout0;
    always @(posedge clkin1 or posedge rst)
        if (rst) lock <= 0;
        else lock <= 1;
endmodule

module tb_board_check;
    reg sys_clk=0, sys_rst_n=0;
    always #10 sys_clk=~sys_clk;
    wire scl, pix_clk, chip_reset, hs, vs, de;
    tri1 sda;
    wire [23:0] rgb;
    hdmi_colorbar dut(sys_clk, sys_rst_n, scl, sda, pix_clk,
                      chip_reset, hs, vs, rgb, de);
    integer cycles=0, pixels=0, lines=0, hs_pixels=0, vs_lines=0;
    integer bit_index, bar_index, sampled_h, sampled_v;
    reg [23:0] bar_color [0:9];
    initial begin
        bar_color[0]=24'hf80000; bar_color[1]=24'hf88000;
        bar_color[2]=24'hf8fc00; bar_color[3]=24'h00fc00;
        bar_color[4]=24'h00fcf8; bar_color[5]=24'h0000f8;
        bar_color[6]=24'hf800f8; bar_color[7]=24'h000000;
        bar_color[8]=24'hf8fcf8; bar_color[9]=24'hd0d0d0;
    end
    reg [7:0] first_byte;
    initial begin
        #200; sys_rst_n=1;
        while (!chip_reset) begin @(posedge sys_clk); #2; cycles=cycles+1; end
        if (cycles < 50000 || cycles > 50010)
            $fatal(1,"MS7210 reset delay incorrect: %0d",cycles);
        @(negedge sda); // I2C START
        if (scl !== 1) $fatal(1,"Invalid I2C START");
        for (bit_index=7; bit_index>=0; bit_index=bit_index-1) begin
            @(posedge scl); first_byte[bit_index]=sda;
        end
        if (first_byte !== 8'hb2) $fatal(1,"Wrong MS7210 address: %h",first_byte);
        @(negedge dut.pixel_clk);
        wait (dut.vga_ctrl_inst.cnt_h==0 && dut.vga_ctrl_inst.cnt_v==0);
        repeat (2200*1125) begin
            @(posedge dut.pixel_clk);
            sampled_h=dut.vga_ctrl_inst.cnt_h;
            sampled_v=dut.vga_ctrl_inst.cnt_v;
            @(posedge pix_clk); #0.001;
            if (hs !== (sampled_h<44) || vs !== (sampled_v<5))
                $fatal(1,"Registered sync alignment incorrect");
            if (de) begin
                pixels=pixels+1;
                bar_index=(sampled_h-192)/192;
                if (rgb!==bar_color[bar_index])
                    $fatal(1,"Colorbar mismatch at x=%0d bar=%0d rgb=%h",sampled_h-192,bar_index,rgb);
            end
            if (hs) hs_pixels=hs_pixels+1;
            if (sampled_h==0) begin
                if (vs) vs_lines=vs_lines+1;
                if (sampled_v>=41 && sampled_v<1121)
                    lines=lines+1;
            end
            if (!de && rgb!==24'd0) $fatal(1,"Nonblack blanking pixel");
            if (de && sampled_h==192 && rgb!==24'hf80000)
                $fatal(1,"First colorbar pixel incorrect");
        end
        if (pixels!=1920*1080 || lines!=1080 || hs_pixels!=44*1125 || vs_lines!=5)
            $fatal(1,"Frame incorrect: pixels=%0d lines=%0d hs=%0d vs=%0d",pixels,lines,hs_pixels,vs_lines);
        sys_rst_n=0; #2;
        if (chip_reset!==0) $fatal(1,"Button did not assert chip reset");
        $display("PASS: 1ms reset, MS7210 address B2, 1920x1080 frame, sync polarity, blanking and all ten colorbar spans.");
        $finish;
    end
    initial begin #40000000; $fatal(1,"Timeout"); end
endmodule
