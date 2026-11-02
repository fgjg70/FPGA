`timescale 1ns/1ps

module tb_io_debug;
    localparam integer BIT_NS = 8680;
    reg sys_clk = 0;
    reg video_clk = 0;
    reg video_running = 1;
    reg sys_rst_n = 0;
    reg [5:0] keys_n = 6'h3f;
    reg uart_rxd = 1;
    reg chip_present = 1;
    reg block_scl = 0;
    reg initial_hdmi_complete = 0;
    wire uart_txd;
    wire [7:0] led;
    tri1 hdmi_scl, hdmi_sda;
    wire hdmi_reset_n, hdmi_pclk, hdmi_hsync, hdmi_vsync, hdmi_de;
    wire [23:0] hdmi_data;
    integer serial_file, image_file;
    integer key_index, byte_index, bit_index, pixel_index, line_index;
    integer sample_count, line_pixels;
    integer hsync_low_pixels, vsync_low_pixels;
    reg [7:0] decoded_byte;
    reg [8*18-1:0] echo_text = {"UART_LOOPBACK_OK", 8'h0d, 8'h0a};

    always #10 sys_clk = ~sys_clk;
    always #18.5185185 if (video_running) video_clk = ~video_clk;
    assign hdmi_scl = block_scl ? 1'b0 : 1'bz;

    top_io_debug #(
        .DEBOUNCE_CYCLES(16), .HDMI_RESET_CYCLES(32), .HDMI_SETTLE_CYCLES(32),
        .HDMI_PLL_WAIT_CYCLES(32), .HDMI_RETRY_CYCLES(1000), .I2C_QUARTER_CYCLES(8)
    ) dut (
        .sys_clk(sys_clk), .video_clk(video_clk), .sys_rst_n(sys_rst_n), .keys_n(keys_n),
        .uart_rxd(uart_rxd), .uart_txd(uart_txd), .led(led), .hdmi_scl(hdmi_scl), .hdmi_sda(hdmi_sda),
        .hdmi_reset_n(hdmi_reset_n), .hdmi_pclk(hdmi_pclk), .hdmi_hsync(hdmi_hsync),
        .hdmi_vsync(hdmi_vsync), .hdmi_de(hdmi_de), .hdmi_data(hdmi_data)
    );

    io_debug_i2c_slave chip (
        .present(chip_present), .reset_n(hdmi_reset_n), .scl(hdmi_scl), .sda(hdmi_sda)
    );

    task send_byte(input [7:0] value, input bit good_stop = 1);
        integer serial_bit;
        begin
            @(negedge sys_clk);
            uart_rxd = 0;
            #(BIT_NS);
            for (serial_bit = 0; serial_bit < 8; serial_bit = serial_bit + 1) begin
                uart_rxd = value[serial_bit];
                #(BIT_NS);
            end
            uart_rxd = good_stop;
            #(BIT_NS);
            uart_rxd = 1;
            #(BIT_NS);
        end
    endtask

    initial begin
        serial_file = $fopen("uart_capture.bin", "wb");
        forever begin
            @(negedge uart_txd);
            #(BIT_NS + BIT_NS / 2);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                decoded_byte[bit_index] = uart_txd;
                #(BIT_NS);
            end
            if (uart_txd !== 1'b1) $fatal(1, "TX stop bit is not high");
            $fwrite(serial_file, "%c", decoded_byte);
        end
    end

    initial begin
        #1000000000;
        $fatal(1, "Simulation timed out");
    end

    initial begin
        #5000000;
        if (!initial_hdmi_complete) $fatal(1, "HDMI init timed out: step=%0d state=%0d writes=%0d failed=%b",
            dut.hdmi_step, dut.hdmi_controller.bus_writer.state, chip.writes, dut.hdmi_failed);
    end

    initial begin
        repeat (10) @(negedge sys_clk);
        sys_rst_n = 1;
        wait (dut.hdmi_ok);
        initial_hdmi_complete = 1;
        if (chip.writes != 90) $fatal(1, "Expected 90 MS7210 writes, got %0d", chip.writes);
        if ({chip.memory[16'h120d], chip.memory[16'h120c]} != 864 ||
            {chip.memory[16'h120f], chip.memory[16'h120e]} != 625 ||
            chip.memory[16'h1202] != 0 || chip.memory[16'h050e] != 8'h40 ||
            chip.memory[16'h0920] != 8'h1e)
            $fatal(1, "MS7210 timing or output configuration mismatch");
        if (chip.avi_count != 14 || chip.avi_sum != 0)
            $fatal(1, "AVI InfoFrame length or checksum mismatch");
        $display("PASS MS7210: 90 acknowledged register writes and AVI checksum");

        for (key_index = 0; key_index < 6; key_index = key_index + 1) begin
            keys_n[key_index] = 0;
            repeat (5) @(negedge sys_clk);
            keys_n[key_index] = 1;
            repeat (25) @(negedge sys_clk);
            if (dut.press_count != key_index) $fatal(1, "Key bounce counted as a press");
            keys_n[key_index] = 0;
            repeat (100) @(negedge sys_clk);
            if (!led[key_index] || dut.press_count != key_index + 1 || dut.pattern != key_index)
                $fatal(1, "Key press, LED or pattern mismatch for KEY%0d", key_index + 2);
            repeat (100) @(negedge sys_clk);
            if (dut.press_count != key_index + 1) $fatal(1, "Holding a key repeated its event");
            keys_n[key_index] = 1;
            repeat (25) @(negedge sys_clk);
            if (led[key_index]) $fatal(1, "Key release failed");
        end
        if (dut.key_counts != 48'h010101010101) $fatal(1, "Per-key counters mismatch");
        keys_n = 0;
        repeat (30) @(negedge sys_clk);
        if (dut.press_count != 12 || led[5:0] != 6'h3f) $fatal(1, "Simultaneous keys failed");
        keys_n = 6'h3f;
        repeat (30) @(negedge sys_clk);
        $display("PASS KEYS: bounce, all six keys, hold, release and simultaneous presses");

        for (byte_index = 0; byte_index < 18; byte_index = byte_index + 1)
            send_byte(echo_text >> ((17 - byte_index) * 8));
        if (dut.rx_count != 18) $fatal(1, "UART receive count mismatch");
        send_byte(8'h55, 0);
        if (!dut.frame_error || dut.rx_count != 18) $fatal(1, "Bad UART stop bit was not rejected");
        send_byte("?");
        #30000000;
        $display("PASS UART: 115200 baud receive, echo scheduling and framing error detection");

        send_byte("c");
        if (dut.press_count != 0 || dut.rx_count != 0 || dut.key_counts != 0 || dut.frame_error)
            $fatal(1, "Clear command failed");
        keys_n[0] = 0;
        repeat (30) @(negedge sys_clk);
        keys_n[0] = 1;
        repeat (30) @(negedge sys_clk);

        chip_present = 0;
        send_byte("r");
        wait (dut.hdmi_failed);
        chip_present = 1;
        wait (dut.hdmi_ok);
        $display("PASS I2C: NACK detection and automatic recovery");
        block_scl = 1;
        send_byte("r");
        wait (dut.hdmi_failed);
        block_scl = 0;
        wait (dut.hdmi_ok);
        $display("PASS I2C: stuck SCL timeout and automatic recovery");

        keys_n[0] = 0;
        @(negedge hdmi_vsync);
        @(negedge hdmi_vsync);
        image_file = $fopen("display.ppm", "wb");
        $fwrite(image_file, "P6\n720 576\n255\n");
        sample_count = 0;
        line_pixels = 0;
        line_index = 0;
        hsync_low_pixels = 0;
        vsync_low_pixels = 0;
        for (pixel_index = 0; pixel_index < 864 * 625; pixel_index = pixel_index + 1) begin
            @(posedge hdmi_pclk);
            if (!hdmi_hsync) hsync_low_pixels = hsync_low_pixels + 1;
            if (!hdmi_vsync) vsync_low_pixels = vsync_low_pixels + 1;
            if (hdmi_de) begin
                $fwrite(image_file, "%c%c%c", hdmi_data[23:16], hdmi_data[15:8], hdmi_data[7:0]);
                sample_count = sample_count + 1;
                line_pixels = line_pixels + 1;
            end else if (line_pixels != 0) begin
                if (line_pixels != 720) $fatal(1, "Active line width mismatch: %0d", line_pixels);
                line_index = line_index + 1;
                line_pixels = 0;
            end
            if (!hdmi_de && hdmi_data !== 24'd0) $fatal(1, "Blanking must output black");
        end
        $fclose(image_file);
        if (sample_count != 720 * 576 || line_index != 576) $fatal(1, "Active frame dimensions mismatch");
        if (hsync_low_pixels != 64 * 625 || vsync_low_pixels != 5 * 864)
            $fatal(1, "HSYNC or VSYNC pulse width mismatch");
        if (dut.display.keys != 1 || dut.display.pattern != 0) $fatal(1, "Video status snapshot failed");
        $display("PASS VIDEO: 864x625 total, 720x576 active, snapshot and blanking");

        #1000000;
        $fclose(serial_file);
        $display("IO_DEBUG_PASS");
        $finish;
    end
endmodule

module io_debug_i2c_slave (
    input wire present,
    input wire reset_n,
    input wire scl,
    inout wire sda
);
    reg [7:0] memory [0:65535];
    reg active = 0;
    reg drive_low = 0;
    reg ack_phase = 0;
    reg ack_sampled = 0;
    reg acknowledge = 0;
    reg [7:0] shift = 0;
    reg [15:0] address = 0;
    integer bit_count = 0;
    integer byte_count = 0;
    integer writes = 0;
    integer avi_count = 0;
    reg [7:0] avi_sum = 8'h82 + 2 + 13;

    assign sda = present && reset_n && drive_low ? 1'b0 : 1'bz;

    always @(negedge sda) if (scl === 1'b1 && reset_n) begin
        active = 1;
        ack_phase = 0;
        ack_sampled = 0;
        bit_count = 0;
        byte_count = 0;
        shift = 0;
    end
    always @(posedge sda) if (scl === 1'b1) begin active = 0; drive_low = 0; end
    always @(negedge reset_n) begin active = 0; drive_low = 0; end

    always @(posedge scl) if (active && present && reset_n) begin
        if (ack_phase) ack_sampled = 1;
        else begin
            shift = {shift[6:0], sda};
            if (bit_count == 7) begin
                acknowledge = byte_count != 0 || shift == 8'hb2;
                case (byte_count)
                    1: address[7:0] = shift;
                    2: address[15:8] = shift;
                    3: begin
                        memory[address] = shift;
                        writes = writes + 1;
                        if (address == 16'h050b) begin avi_count = 0; avi_sum = 8'h82 + 2 + 13; end
                        if (address == 16'h050d) begin avi_count = avi_count + 1; avi_sum = avi_sum + shift; end
                    end
                    default: begin end
                endcase
                byte_count = byte_count + 1;
                bit_count = 0;
                ack_phase = 1;
                ack_sampled = 0;
            end else bit_count = bit_count + 1;
        end
    end

    always @(negedge scl) begin
        if (!active || !present || !reset_n) drive_low = 0;
        else if (ack_phase && !ack_sampled) drive_low = acknowledge;
        else if (ack_phase && ack_sampled) begin
            drive_low = 0;
            ack_phase = 0;
        end
    end
endmodule
