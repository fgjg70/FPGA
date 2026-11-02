`timescale 1ns/1ps

module tb_camera_dvp;
    reg clk = 0;
    always #10 clk = !clk;
    reg reset = 1;
    reg configured = 1;
    reg freeze = 0;
    reg frame_ack = 0;
    reg pclk = 0;
    reg href = 0;
    reg vsync = 0;
    reg [7:0] data = 0;
    wire pixel_write;
    wire [14:0] pixel_address;
    wire [15:0] pixel_data;
    wire frame_done;
    wire [15:0] frame_count;
    wire [15:0] timeout_count;
    wire [15:0] vsync_count;
    wire [15:0] pclk_count;
    wire [15:0] line_count;
    wire [15:0] bad_frame_count;
    wire [3:0] state;
    integer writes = 0;
    integer completions = 0;
    integer saved_writes;
    reg check_pixels = 0;
    reg [15:0] expected_pixel;

    camera_dvp_capture #(.WIDTH(8), .HEIGHT(6), .TIMEOUT_CYCLES(4096), .WARMUP_FRAMES(0)) dut (
        .clk(clk), .reset(reset), .configured(configured), .freeze(freeze), .frame_ack(frame_ack),
        .pclk(pclk), .href(href), .vsync(vsync), .data(data), .pixel_write(pixel_write),
        .pixel_address(pixel_address), .pixel_data(pixel_data), .frame_done(frame_done),
        .frame_count(frame_count), .timeout_count(timeout_count), .vsync_count(vsync_count),
        .pclk_count(pclk_count), .line_count(line_count), .bad_frame_count(bad_frame_count),
        .state(state), .sync_levels()
    );

    function [15:0] source_pixel;
        input integer row_number;
        input integer column_number;
        begin source_pixel = 16'h8000 | (row_number << 8) | column_number; end
    endfunction

    always @(posedge clk) begin
        #1;
        if (!reset && pixel_write) begin
            if (!configured || freeze) $fatal(1, "DVP writes while disabled or frozen");
            if (check_pixels) begin
                expected_pixel = source_pixel(2 * (writes / 4), 2 * (writes % 4));
                if (pixel_address !== writes || pixel_data !== expected_pixel)
                    $fatal(1, "DVP pixel mismatch index=%0d addr=%0d data=%04x expected=%04x", writes, pixel_address, pixel_data, expected_pixel);
            end
            writes = writes + 1;
        end
        if (!reset && frame_done) completions = completions + 1;
    end

    task send_byte;
        input [7:0] value;
        begin
            data = value;
            pclk = 0;
            #83;
            pclk = 1;
            #77;
            pclk = 0;
        end
    endtask

    task frame_boundary;
        begin
            href = 0;
            vsync = 1;
            #513;
            vsync = 0;
            #497;
        end
    endtask

    task send_lines;
        input integer columns;
        integer row_number;
        integer column_number;
        reg [15:0] value;
        begin
            for (row_number = 0; row_number < 6; row_number = row_number + 1) begin
                href = 1;
                #43;
                for (column_number = 0; column_number < columns; column_number = column_number + 1) begin
                    value = source_pixel(row_number, column_number);
                    send_byte(value[15:8]);
                    send_byte(value[7:0]);
                end
                href = 0;
                #149;
            end
        end
    endtask

    task acknowledge;
        begin
            @(negedge clk); frame_ack = 1;
            @(negedge clk); frame_ack = 0;
            repeat (5) @(negedge clk);
        end
    endtask

    initial begin
        repeat (6) @(negedge clk);
        #7; reset = 0;
        frame_boundary;
        frame_boundary;
        if (frame_count != 0 || completions != 0 || vsync_count != 2)
            $fatal(1, "Raw VSYNC edges accepted as image frames");
        send_lines(7);
        frame_boundary;
        if (frame_count != 0 || completions != 0 || bad_frame_count == 0)
            $fatal(1, "Short DVP lines accepted as complete image");
        href = 1;
        send_byte(8'h12);
        href = 0;
        #149;
        frame_boundary;
        if (frame_count != 0) $fatal(1, "Odd-byte frame accepted");
        writes = 0;
        check_pixels = 1;
        send_lines(8);
        frame_boundary;
        check_pixels = 0;
        if (frame_count != 1 || completions != 1 || writes != 12 || state != 2)
            $fatal(1, "Missing valid DVP frame count=%0d writes=%0d state=%0d", frame_count, writes, state);
        saved_writes = writes;
        send_lines(8);
        frame_boundary;
        if (writes != saved_writes || frame_count != 1) $fatal(1, "DVP overwrote pending display buffer");
        acknowledge;
        freeze = 1;
        frame_boundary;
        send_lines(8);
        frame_boundary;
        if (writes != saved_writes || frame_count != 1) $fatal(1, "Freeze failed");
        freeze = 0;
        frame_boundary;
        writes = 0;
        check_pixels = 1;
        send_lines(8);
        frame_boundary;
        check_pixels = 0;
        if (frame_count != 2 || completions != 2 || writes != 12) $fatal(1, "DVP did not resume after freeze");
        acknowledge;
        repeat (4200) @(negedge clk);
        if (timeout_count == 0) $fatal(1, "Missing DVP frame watchdog");
        configured = 0;
        saved_writes = writes;
        frame_boundary;
        send_lines(8);
        frame_boundary;
        if (writes != saved_writes || frame_count != 2) $fatal(1, "Unconfigured camera accepted a frame");
        if (pclk_count == 0 || line_count == 0) $fatal(1, "Missing DVP activity diagnostics");
        reset = 1;
        repeat (5) @(negedge clk);
        if (frame_count != 0 || bad_frame_count != 0 || frame_done) $fatal(1, "DVP reset failed");
        $display("PASS camera DVP asynchronous PCLK, RGB565 endian/subsample, frame geometry, noise/short/odd rejection, display backpressure, freeze, timeout, configuration loss and reset");
        $finish;
    end
    initial begin #1000000; $fatal(1, "DVP capture test timeout"); end
endmodule
