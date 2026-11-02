`timescale 1ns/1ps

module tb_coremark;
    reg clk = 0;
    always #5 clk = !clk;
    reg reset = 1;
    wire uart_txd;
    wire cpu_illegal;
    reg [7:0] received;
    integer bit_index;
    vision_soc dut (.clk(clk), .reset(reset), .keys_n(4'hf), .uart_rxd(1'b1), .uart_txd(uart_txd),
        .configured(1'b0), .failed(1'b0), .frame_valid(1'b0), .frame_count(16'd0), .frame_tick(1'b0),
        .pixel_write(1'b0), .pixel_address(15'd0), .pixel_data(16'd0), .frame_done(1'b0),
        .frozen(), .show_bars(), .restart(), .overlay_valid(), .box_left(), .box_top(), .box_right(),
        .box_bottom(), .label(), .panel_status(), .pass_count(), .reject_count(), .inference_busy(), .cpu_illegal(cpu_illegal));
    defparam dut.uart.BAUD = 6250000;
    always @(posedge clk) if (!reset && cpu_illegal) $fatal(1, "Illegal instruction in official CoreMark");
    initial forever begin
        @(negedge uart_txd);
        repeat (12) @(negedge clk);
        for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
            received[bit_index] = uart_txd;
            repeat (8) @(negedge clk);
        end
        if (!uart_txd) $fatal(1, "CoreMark UART stop bit missing");
        $write("%c", received);
    end
    initial begin
        repeat (5) @(negedge clk);
        reset = 0;
        wait(dut.benchmark_done == 32'hc0decafe);
        wait(!dut.tx_busy);
        repeat (50) @(negedge clk);
        $display("PASS coremark official algorithm completed on the real RISC-V core; short functional run is not an eligible score");
        $finish;
    end
    initial begin #50000000; $fatal(1, "CoreMark functional simulation timeout"); end
endmodule
