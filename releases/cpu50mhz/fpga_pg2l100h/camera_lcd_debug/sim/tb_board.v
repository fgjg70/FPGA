`timescale 1ns/1ps

module tb_board;
    reg sys_clk = 0;
    always #10 sys_clk = ~sys_clk;
    reg reset_n = 0;
    reg [3:0] keys_n = 4'hf;
    reg uart_rxd = 1;
    tri1 cam_sda;
    wire [3:0] led;
    wire [7:0] red, green, blue;
    wire dclk, hsync, vsync, de;
    wire touch_sclk, touch_cs_n, touch_mosi;
    integer pixel_index;
    integer clock_index;
    reg [23:0] expected;
    realtime previous_edge;
    realtime clock_period;
    realtime data_edge = 0;

    top_pg2l100h_camera_lcd dut (
        .sys_clk(sys_clk), .reset_n(reset_n), .keys_n(keys_n), .uart_rxd(uart_rxd),
        .led(led), .lcd_r(red), .lcd_g(green), .lcd_b(blue),
        .lcd_dclk(dclk), .lcd_hsync(hsync), .lcd_vsync(vsync), .lcd_de(de),
        .touch_sclk(touch_sclk), .touch_cs_n(touch_cs_n), .touch_mosi(touch_mosi),
        .touch_busy(1'b0), .cam_sda(cam_sda), .cam_vsync(1'b0), .cam_data(8'b0)
    );
    defparam dut.debug.keys.DEBOUNCE_CYCLES = 6;

    always @(red or green or blue or de or hsync or vsync) data_edge = $realtime;

    task cycles;
        input integer count;
        integer cycle_index;
        begin
            for (cycle_index = 0; cycle_index < count; cycle_index = cycle_index + 1)
                @(negedge dut.clk_27m);
        end
    endtask

    task press_key;
        input integer key_index;
        begin
            keys_n[key_index] = 0;
            cycles(20);
            keys_n[key_index] = 1;
            cycles(20);
        end
    endtask

    task send_command;
        input [7:0] command;
        integer command_bit;
        begin
            uart_rxd = 0;
            cycles(234);
            for (command_bit = 0; command_bit < 8; command_bit = command_bit + 1) begin
                uart_rxd = command[command_bit];
                cycles(234);
            end
            uart_rxd = 1;
            cycles(500);
        end
    endtask

    initial begin
        repeat (12) @(negedge sys_clk);
        reset_n = 1;
        wait (dut.pll_locked === 1'b1);
        @(posedge dut.clk_27m);
        previous_edge = $realtime;
        for (clock_index = 0; clock_index < 100; clock_index = clock_index + 1) begin
            @(posedge dut.clk_27m);
            clock_period = $realtime - previous_edge;
            if (clock_period < 37.027 || clock_period > 37.047)
                $fatal(1, "Vendor PLL model did not generate 27MHz: %f", clock_period);
            previous_edge = $realtime;
        end
        $display("PLL model verified: 50MHz input, 27MHz output");
        force dut.debug.powerup = 16'hffff;
        cycles(4);
        release dut.debug.powerup;
        cycles(4);
        if (dut.debug.reset || dut.debug.camera_mode || dut.debug.frozen)
            $fatal(1, "Board reset or default mode incorrect");
        if (led !== dut.debug_led[3:0] || touch_sclk !== 0 || touch_cs_n !== 1 || touch_mosi !== 0)
            $fatal(1, "Board LED mapping or inactive touch controls incorrect");
        if (dut.debug.keys_n !== 6'h3f)
            $fatal(1, "Unused MES50HP keys must remain released");
        wait (de === 1'b1);
        previous_edge = 0;
        for (pixel_index = 0; pixel_index < 480; pixel_index = pixel_index + 1) begin
            @(posedge dclk);
            clock_period = $realtime - previous_edge;
            if (pixel_index != 0 && (clock_period < 55.54 || clock_period > 55.57))
                $fatal(1, "Board LCD clock half-period incorrect: %f", clock_period);
            if ($realtime - data_edge < 35)
                $fatal(1, "Board LCD data setup too short");
            #1;
            case (pixel_index / 60)
                0: expected = 24'hffffff;
                1: expected = 24'hffff00;
                2: expected = 24'h00ffff;
                3: expected = 24'h00ff00;
                4: expected = 24'hff00ff;
                5: expected = 24'hff0000;
                6: expected = 24'h0000ff;
                default: expected = 24'h000000;
            endcase
            if (!de || {red, green, blue} !== expected)
                $fatal(1, "RGB888 connector mapping incorrect at pixel %d: %h", pixel_index, {red, green, blue});
            previous_edge = $realtime - 1;
            @(negedge dclk);
            clock_period = $realtime - previous_edge;
            if (clock_period < 55.54 || clock_period > 55.57)
                $fatal(1, "Board LCD clock duty cycle incorrect");
            previous_edge = $realtime;
        end
        press_key(0);
        if (!dut.debug.camera_mode) $fatal(1, "KEY1 did not select camera");
        press_key(1);
        if (dut.debug.camera_mode) $fatal(1, "KEY2 did not select bars");
        press_key(2);
        if (!dut.debug.frozen) $fatal(1, "KEY3 did not freeze");
        press_key(3);
        if (!dut.debug.sensor_bars || !dut.debug.camera_mode || dut.debug.frozen)
            $fatal(1, "KEY4 did not restart with sensor bars");
        send_command("b");
        if (dut.debug.camera_mode) $fatal(1, "Board UART command b failed");
        send_command("c");
        if (!dut.debug.camera_mode) $fatal(1, "Board UART command c failed");
        send_command("f");
        if (!dut.debug.frozen) $fatal(1, "Board UART command f failed");
        send_command("r");
        if (dut.debug.frozen) $fatal(1, "Board UART command r failed");
        reset_n = 0;
        #1000;
        if (dut.pll_locked !== 0) $fatal(1, "PLL lock not cleared by SW2");
        reset_n = 1;
        wait (dut.pll_locked === 1'b1);
        cycles(8);
        if (!dut.debug.reset) $fatal(1, "Debug logic reset hold missing after PLL relock");
        force dut.debug.powerup = 16'hffff;
        cycles(4);
        release dut.debug.powerup;
        cycles(4);
        if (dut.debug.camera_mode || dut.debug.frozen || dut.debug.sensor_bars)
            $fatal(1, "SW2 did not restore default debug controls");
        $display("PASS tb_board: vendor PLL 50-to-27MHz, LCD 9MHz RGB888, four keys, UART, PLL relock reset");
        $finish;
    end

    initial begin
        #5000000;
        $fatal(1, "tb_board watchdog");
    end
endmodule
