`timescale 1ns/1ps
// Run with the vendor GTP_GPLL simulation model and the generated clk_gen.v.
module tb_pixel_clock;
    reg sys_clk=0, rst=1;
    wire clk, locked;
    always #10 sys_clk=~sys_clk;
    clk_gen dut(.clkin1(sys_clk),.rst(rst),.clkout0(clk),.lock(locked));
    realtime start_time, period_ns;
    initial begin
        #200; rst=0;
        wait(locked); repeat(20) @(posedge clk);
        start_time=$realtime;
        repeat(1000) @(posedge clk);
        period_ns=($realtime-start_time)/1000.0;
        if (period_ns<6.72 || period_ns>6.75)
            $fatal(1,"Unexpected pixel clock period %f ns",period_ns);
        $display("PASS: vendor PLL model period=%f ns, frequency=%f MHz",period_ns,1000.0/period_ns);
        $finish;
    end
    initial begin #100000; $fatal(1,"PLL did not lock"); end
endmodule
