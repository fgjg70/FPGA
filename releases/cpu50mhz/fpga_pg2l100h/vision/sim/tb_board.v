`timescale 1ns/1ps

module tb_board;
    reg sys_clk = 0;
    always #10 sys_clk = !sys_clk;
    reg reset_n = 0;
    reg [3:0] keys_n = 4'hf;
    wire [3:0] led;
    wire [7:0] red;
    wire [7:0] green;
    wire [7:0] blue;
    wire dclk;
    wire de;
    wire touch_sclk;
    wire touch_cs_n;
    wire touch_mosi;
    tri1 cam_sda;
    wire cam_xclk;
    wire cam_reset_n;
    wire cam_pwdn;
    realtime previous_edge;
    realtime period_ns;
    integer edge_index;
    top_pg2l100h_vision dut (.sys_clk(sys_clk), .reset_n(reset_n), .keys_n(keys_n), .uart_rxd(1'b1), .uart_txd(),
        .led(led), .lcd_r(red), .lcd_g(green), .lcd_b(blue), .lcd_dclk(dclk), .lcd_hsync(), .lcd_vsync(), .lcd_de(de),
        .touch_sclk(touch_sclk), .touch_cs_n(touch_cs_n), .touch_mosi(touch_mosi), .touch_busy(1'b0),
        .cam_scl(), .cam_sda(cam_sda), .cam_vsync(1'b0), .cam_href(1'b0), .cam_pclk(1'b0), .cam_data(8'd0),
        .cam_xclk(cam_xclk), .cam_reset_n(cam_reset_n), .cam_pwdn(cam_pwdn));
    defparam dut.system.keys.DEBOUNCE_CYCLES = 6;
    defparam dut.system.LONG_PRESS_CYCLES = 100;
    task cycles;
        input integer count;
        integer cycle_index;
        begin for (cycle_index = 0; cycle_index < count; cycle_index = cycle_index + 1) @(negedge dut.clk_50m); end
    endtask
    task press_key;
        input integer index;
        begin keys_n[index] = 0; cycles(20); keys_n[index] = 1; cycles(20); end
    endtask
    initial begin
        repeat (12) @(negedge sys_clk);
        reset_n = 1;
        wait(dut.pll_locked === 1'b1);
        cycles(10);
        previous_edge = $realtime;
        for (edge_index = 0; edge_index < 30; edge_index = edge_index + 1) begin
            cycles(1);
            period_ns = $realtime - previous_edge;
            if (period_ns < 19.999 || period_ns > 20.001) $fatal(1, "System frequency mismatch: %f ns", period_ns);
            previous_edge = $realtime;
        end
        force dut.powerup = 16'hffff;
        cycles(4);
        release dut.powerup;
        cycles(4);
        if (dut.reset || dut.show_bars || dut.frozen || !dut.system.control[0]) $fatal(1, "Wrong board reset/default controls");
        if (touch_sclk !== 0 || touch_cs_n !== 1 || touch_mosi !== 0) $fatal(1, "Touch outputs not inactive");
        if (cam_pwdn !== 0 || cam_reset_n !== 0) $fatal(1, "Wrong DVP sensor power/reset sequence");
        @(posedge cam_xclk); previous_edge = $realtime;
        for (edge_index = 0; edge_index < 30; edge_index = edge_index + 1) begin
            @(posedge cam_xclk); period_ns = $realtime - previous_edge;
            if (period_ns < 79.999 || period_ns > 80.001) $fatal(1, "Camera MCLK mismatch: %f ns", period_ns);
            previous_edge = $realtime;
        end
        wait(de === 1'b1);
        if ({red, green, blue} !== 24'hffff00) $fatal(1, "RGB565 to RGB888 expansion failed");
        @(posedge dclk); previous_edge = $realtime;
        for (edge_index = 0; edge_index < 30; edge_index = edge_index + 1) begin
            @(posedge dclk); period_ns = $realtime - previous_edge;
            if (period_ns < 111.08 || period_ns > 111.14) $fatal(1, "LCD clock mismatch: %f ns", period_ns);
            previous_edge = $realtime;
        end
        keys_n[0] = 0; cycles(150); keys_n[0] = 1; cycles(20);
        if (!dut.system.mode_toggle_pending || dut.system.next_target_pending) $fatal(1, "SW4 long press mixed model and target events");
        press_key(0);
        if (!dut.system.next_target_pending || !dut.system.control[0]) $fatal(1, "SW4 next-target event failed");
        press_key(1);
        if (!dut.show_bars) $fatal(1, "SW5 colorbar toggle failed");
        press_key(2);
        if (!dut.frozen) $fatal(1, "SW6 freeze toggle failed");
        press_key(3);
        if (dut.frozen) $fatal(1, "SW7 restart failed to unfreeze");
        if (dut.cpu_illegal) $fatal(1, "CPU illegal instruction on board wrapper");
        reset_n = 0;
        repeat (12) @(negedge sys_clk);
        reset_n = 1;
        wait(dut.pll_locked === 1'b1);
        cycles(10);
        if (!dut.reset) $fatal(1, "PLL relock failed to restart reset sequence");
        $display("PASS board actual Pango GPLL model, system 50MHz, video PLL 27MHz, LCD 9MHz, camera MCLK 12.5MHz, DVP reset/power, RGB888, four keys, reset/relock");
        $finish;
    end
    initial begin #4000000; $fatal(1, "Board test timeout"); end
endmodule
