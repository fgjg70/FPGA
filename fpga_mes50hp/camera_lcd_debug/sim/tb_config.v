`timescale 1ns/1ps

module tb_config;
    reg clk=0;
    always #18.5185 clk=~clk;
    reg reset=1;
    reg restart=0;
    reg sensor_bars=0;
    reg device_present=1;
    reg [7:0] model_pid=8'h76;
    reg slave_low=0;
    tri1 sda;
    wire scl,configured,failed;
    wire [7:0] pid,version,step;
    reg [7:0] received;
    reg [7:0] current_address;
    reg [7:0] value;
    reg [7:0] registers [0:255];
    integer write_count=0;
    integer read_count=0;
    integer byte_index;

    assign sda=slave_low ? 1'b0 : 1'bz;
    camera_config #(.SETTLE_CYCLES(30)) dut (
        .clk(clk),.reset(reset),.restart(restart),.sensor_bars(sensor_bars),
        .configured(configured),.failed(failed),.pid(pid),.version(version),.step(step),
        .scl(scl),.sda(sda)
    );

    task receive_byte;
        output [7:0] result;
        integer bit_number;
        begin
            for(bit_number=7;bit_number>=0;bit_number=bit_number-1) begin
                @(posedge scl); #1; result[bit_number]=sda;
            end
        end
    endtask
    task ack;
        begin
            @(negedge scl); slave_low=1;
            @(posedge scl);
            @(negedge scl); slave_low=0;
        end
    endtask
    task transmit_byte;
        input [7:0] result;
        integer bit_number;
        begin
            for(bit_number=7;bit_number>=0;bit_number=bit_number-1) begin
                slave_low=!result[bit_number];
                @(posedge scl); @(negedge scl);
            end
            slave_low=0;
            @(posedge scl); #1;
            if(sda!==1'b1) $fatal(1,"Master did not NACK final SCCB read byte");
            @(negedge scl);
        end
    endtask

    initial forever begin
        @(negedge sda);
        if(scl && !reset && device_present) begin
            receive_byte(received);
            if(received==8'h42) begin
                ack(); receive_byte(current_address); ack();
                if(current_address!=8'h0a && current_address!=8'h0b) begin
                    receive_byte(value); ack();
                    registers[current_address]=value;
                    write_count=write_count+1;
                end
            end else if(received==8'h43) begin
                ack();
                if(current_address==8'h0a) transmit_byte(model_pid);
                else if(current_address==8'h0b) transmit_byte(8'h73);
                else $fatal(1,"Unexpected SCCB register read");
                read_count=read_count+1;
            end else $fatal(1,"Incorrect SCCB device address: %h",received);
        end
    end

    task reconfigure;
        begin
            @(negedge clk); restart=1;
            repeat(3) @(negedge clk);
            restart=0;
            wait(configured || failed);
            repeat(10) @(negedge clk);
        end
    endtask

    initial begin
        repeat(8) @(negedge clk); reset=0;
        wait(configured || failed);
        if(!configured || failed || pid!=8'h76 || version!=8'h73 || write_count!=50 || read_count!=2)
            $fatal(1,"OV7670 initialization or ID read failed pid=%h ver=%h writes=%d reads=%d",pid,version,write_count,read_count);
        if(registers[8'h12]!=8'h14 || registers[8'h40]!=8'hd0 || registers[8'h8c]!=0 ||
           registers[8'h0c]!=4 || registers[8'h72]!=8'h11 || registers[8'h42]!=0)
            $fatal(1,"Sensor output is not QVGA RGB565");
        device_present=0; reconfigure();
        if(!failed || configured || step!=0) $fatal(1,"Absent camera was accepted as configured");
        device_present=1; sensor_bars=1; reconfigure();
        if(!configured || failed || registers[8'h42]!=8'h08) $fatal(1,"SCCB NACK recovery or sensor bars failed");
        model_pid=8'h75; reconfigure();
        if(!failed || configured || pid!=8'h75) $fatal(1,"Incorrect sensor ID was accepted");
        $display("PASS tb_config: SCCB write/STOP/read/NACK, RGB565 configuration, absent device, restart, bad ID");
        $finish;
    end
    initial begin #60000000; $fatal(1,"tb_config watchdog"); end
endmodule
