`timescale 1ns/1ps

module tb_camera;
    reg clk = 0;
    always #10 clk = !clk;
    reg reset = 1;
    reg vsync = 0;
    reg freeze = 0;
    reg frame_ack = 0;
    reg [7:0] data = 0;
    wire rclk;
    wire oe_n;
    wire rrst_n;
    wire we;
    wire pixel_write;
    wire [14:0] pixel_address;
    wire [15:0] pixel_data;
    wire frame_done;
    wire [15:0] frame_count;
    wire [3:0] state;
    integer byte_index = 0;
    integer captured = 0;
    integer source_pixel;
    reg [15:0] expected;
    realtime previous_read = 0;
    camera_fifo_capture #(.WIDTH(8), .HEIGHT(4), .WARMUP_FRAMES(0), .READ_HALF_CYCLES(6), .TIMEOUT_CYCLES(50000000)) dut (
        .clk(clk), .reset(reset), .configured(1'b1), .freeze(freeze), .frame_ack(frame_ack), .vsync(vsync), .data(data),
        .rclk(rclk), .we(we), .oe_n(oe_n), .wrst_n(), .rrst_n(rrst_n), .pixel_write(pixel_write),
        .pixel_address(pixel_address), .pixel_data(pixel_data), .frame_done(frame_done), .frame_count(frame_count),
        .timeout_count(), .vsync_count(), .state(state));
    always @(posedge rclk) begin
        if (!rrst_n) begin byte_index = 0; previous_read = 0; end
        else if (!oe_n) begin
            if (previous_read && $realtime - previous_read != 240) $fatal(1, "Unsafe FIFO read period");
            previous_read = $realtime;
            data <= #80 byte_index[7:0];
            byte_index = byte_index + 1;
        end
    end
    always @(negedge clk) begin
        if (!reset && pixel_write) begin
            source_pixel = (captured / 4) * 16 + (captured % 4) * 2;
            expected = ((2 * source_pixel) << 8) | (2 * source_pixel + 1);
            if (pixel_address !== captured || pixel_data !== expected)
                $fatal(1, "Camera byte timing/subsampling mismatch %0d: %h expected %h", captured, pixel_data, expected);
            captured = captured + 1;
        end
    end
    task pulse_vsync;
        begin
            @(negedge clk); vsync = 1;
            repeat (12) @(negedge clk);
            vsync = 0;
            repeat (12) @(negedge clk);
        end
    endtask
    initial begin
        repeat (8) @(negedge clk); reset = 0;
        pulse_vsync;
        pulse_vsync;
        pulse_vsync;
        wait(frame_done);
        @(negedge clk);
        if (captured != 8 || frame_count != 1 || byte_index != 64) $fatal(1, "Incomplete camera frame");
        freeze = 1;
        frame_ack = 1;
        repeat (3) @(negedge clk); frame_ack = 0;
        pulse_vsync;
        if (we || frame_count != 1 || state != 1) $fatal(1, "Freeze/acknowledgement failed");
        $display("PASS camera 50MHz system, 4.167MHz FIFO reads, 120ns sample spacing, 80ns external delay, RGB565 and freeze");
        $finish;
    end
    initial begin #100000; $fatal(1, "Camera test timeout"); end
endmodule
