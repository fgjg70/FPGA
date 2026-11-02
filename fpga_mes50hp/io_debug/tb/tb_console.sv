`timescale 1ns/1ps

module tb_console;
    reg clk = 0;
    reg reset = 1;
    reg clear_errors = 0;
    reg rx_valid = 0;
    reg rx_frame_error = 0;
    reg [7:0] rx_data = 0;
    reg tx_busy = 1;
    wire [7:0] tx_data;
    wire tx_start, fifo_overflow, frame_error;
    integer input_index, delivered;

    always #10 clk = ~clk;

    debug_console dut (
        .clk(clk), .reset(reset), .clear_errors(clear_errors), .report_event(1'b0),
        .keys(6'd0), .press_count(32'd0), .rx_count(32'd0), .last_rx(8'd0),
        .pattern(3'd0), .hdmi_ok(1'b1), .hdmi_failed(1'b0), .hdmi_step(8'd89),
        .video_alive(1'b1), .rx_data(rx_data), .rx_valid(rx_valid), .rx_frame_error(rx_frame_error),
        .tx_busy(tx_busy), .tx_data(tx_data), .tx_start(tx_start),
        .fifo_overflow(fifo_overflow), .frame_error(frame_error)
    );

    task enqueue(input [7:0] value);
        begin
            @(negedge clk); rx_data = value; rx_valid = 1;
            @(negedge clk); rx_valid = 0;
        end
    endtask

    initial begin
        #1000000;
        $fatal(1, "Console test timed out");
    end

    initial begin
        repeat (4) @(negedge clk);
        reset = 0;
        for (input_index = 0; input_index < 1024; input_index = input_index + 1)
            enqueue(input_index[7:0]);
        if (fifo_overflow) $fatal(1, "FIFO overflowed before 1024 bytes");
        enqueue(8'hc3);
        if (!fifo_overflow) $fatal(1, "FIFO overflow was not reported");
        rx_frame_error = 1;
        @(negedge clk); rx_frame_error = 0;
        tx_busy = 0;
        delivered = 0;
        while (delivered < 1024) begin
            @(posedge clk);
            if (tx_start) begin
                if (tx_data !== delivered[7:0]) $fatal(1, "FIFO byte %0d was corrupted", delivered);
                delivered = delivered + 1;
            end
        end
        if (!frame_error) $fatal(1, "Framing error was not sticky");
        @(negedge clk); clear_errors = 1;
        @(negedge clk); clear_errors = 0;
        if (fifo_overflow || frame_error) $fatal(1, "Error clear failed");
        $display("PASS CONSOLE: 1024-byte FIFO, overflow protection, byte ordering and sticky error clear");
        $display("CONSOLE_PASS");
        $finish;
    end
endmodule
