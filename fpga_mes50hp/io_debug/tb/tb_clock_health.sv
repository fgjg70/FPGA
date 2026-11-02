`timescale 1ns/1ps

module tb_clock_health;
    reg sys_clk = 0;
    reg video_clk = 0;
    reg video_running = 1;
    reg sys_rst_n = 0;
    tri1 hdmi_scl, hdmi_sda;
    time stopped_at;
    time resumed_at;

    always #500 sys_clk = ~sys_clk;
    always #18.5185185 if (video_running) video_clk = ~video_clk;

    top_io_debug #(.CLOCK_HZ(1000000), .BAUD(9600), .DEBOUNCE_CYCLES(20000)) dut (
        .sys_clk(sys_clk), .video_clk(video_clk), .sys_rst_n(sys_rst_n),
        .keys_n(6'h3f), .uart_rxd(1'b1), .uart_txd(), .led(),
        .hdmi_scl(hdmi_scl), .hdmi_sda(hdmi_sda), .hdmi_reset_n(),
        .hdmi_pclk(), .hdmi_hsync(), .hdmi_vsync(), .hdmi_de(), .hdmi_data()
    );

    initial begin
        #150000000;
        $fatal(1, "Pixel clock health test timed out");
    end

    initial begin
        repeat (10) @(negedge sys_clk);
        sys_rst_n = 1;
        wait (dut.video_alive);
        video_running = 0;
        stopped_at = $time;
        wait (!dut.video_alive);
        if ($time - stopped_at < 99999000 || $time - stopped_at > 100003000)
            $fatal(1, "Pixel clock loss timeout was not 100 ms: %0t", $time - stopped_at);
        video_running = 1;
        resumed_at = $time;
        wait (dut.video_alive);
        if ($time - resumed_at > 21000000) $fatal(1, "Pixel clock resumption was not detected within a frame");
        $display("PASS VIDEO: 100 ms missing pixel clock timeout and automatic recovery");
        $display("CLOCK_HEALTH_PASS");
        $finish;
    end
endmodule
