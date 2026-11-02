`timescale 1ns/1ps
// Controller/driver integration check. The mock chip ACKs and returns 5A.
module tb_ms7210_config;
    reg clk=0, rstn=0;
    always #10 clk=~clk;
    wire done, scl;
    tri1 sda;
    wire [7:0] mock_data=8'h5a;
    hdmi_i2c dut(clk,rstn,done,scl,sda);
    wire mock_ack=(dut.driver.state==3'd3);
    wire mock_read=(dut.driver.state==3'd4) && !mock_data[7-dut.driver.trans_bit];
    assign sda=(mock_ack || mock_read) ? 1'b0 : 1'bz;
    integer writes=0, payload_count=0, checksum=8'h82+8'h02+8'h0d;
    reg [15:0] sent_addr;
    reg [7:0] sent_data;
    reg sent_write;
    always @(posedge dut.busy) begin
        sent_addr=dut.addr; sent_data=dut.data_in; sent_write=dut.write_read;
    end
    always @(negedge dut.busy) begin
        if (rstn && sent_write && sent_addr!=16'h0003) begin
            writes=writes+1;
            if (sent_addr==16'h050d) begin
                checksum=checksum+sent_data;
                payload_count=payload_count+1;
                if (payload_count==2 && sent_data!=8'h12) $fatal(1,"AVI scan/colorspace incorrect");
                if (payload_count==3 && sent_data!=8'h28) $fatal(1,"AVI aspect ratio incorrect");
                if (payload_count==5 && sent_data!=8'h10) $fatal(1,"AVI VIC must be 16 for 1080p60");
            end
        end
    end
    initial begin
        #200; rstn=1;
        wait(dut.controller.state==6'b001000);
        // Only shorten the 320ms analog settling wait in this digital mock test.
        @(negedge clk); force dut.controller.delay_cnt=24'd15999999;
        @(negedge clk); release dut.controller.delay_cnt;
        wait(done); #100;
        if (writes!=49 || payload_count!=14 || (checksum & 255)!=0)
            $fatal(1,"Config incomplete: writes=%0d AVI bytes=%0d checksum=%h",writes,payload_count,checksum&255);
        $display("PASS: MS7210 scratch readback, all 49 config writes, 16:9 RGB AVI and checksum.");
        $finish;
    end
    initial begin #10000000; $fatal(1,"MS7210 configuration timed out"); end
endmodule
