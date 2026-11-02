`timescale 1ns/1ps

module tb_controls;
    reg clk=0;
    always #18.5185 clk=~clk;
    reg reset_n=0;
    reg [5:0] keys_n=6'h3f;
    reg uart_rxd=1;
    tri1 camera_sda;
    wire uart_txd;
    wire [7:0] led;
    integer line_count=0;
    integer report_count=0;
    integer restart_count=0;
    integer key_index;
    integer bit_index;
    integer character_index=0;
    reg [7:0] character;
    reg mode_seen=0;
    reg frozen_seen=0;
    reg [8*74-1:0] line_data=0;
    integer previous_reports;
    integer previous_restarts;

    top_camera_lcd_debug dut (
        .clk_27m(clk),.reset_n(reset_n),.keys_n(keys_n),.uart_rxd(uart_rxd),
        .uart_txd(uart_txd),.led(led),.touch_busy(1'b0),.touch_miso(1'b0),
        .touch_irq_n(1'b1),.cam_sda(camera_sda),.cam_vsync(1'b0),.cam_data(8'h00)
    );
    defparam dut.keys.DEBOUNCE_CYCLES=6;

    always @(posedge clk) if(!dut.reset) begin
        if(dut.report) report_count=report_count+1;
        if(dut.restart) restart_count=restart_count+1;
    end

    task automatic cycles;
        input integer count;
        integer cycle_index;
        begin for(cycle_index=0;cycle_index<count;cycle_index=cycle_index+1) @(negedge clk); end
    endtask

    task press_key;
        input integer index;
        begin keys_n[index]=0; cycles(14); keys_n[index]=1; cycles(14); end
    endtask

    task send_command;
        input [7:0] command;
        input integer bad_stop;
        integer command_bit;
        begin
            uart_rxd=0; cycles(234);
            for(command_bit=0;command_bit<8;command_bit=command_bit+1) begin
                uart_rxd=command[command_bit]; cycles(234);
            end
            uart_rxd=!bad_stop; cycles(234);
            uart_rxd=1; cycles(300);
        end
    endtask

    initial forever begin
        @(negedge uart_txd);
        cycles(351);
        for(bit_index=0;bit_index<8;bit_index=bit_index+1) begin
            character[bit_index]=uart_txd; cycles(234);
        end
        if(!uart_txd) $fatal(1,"UART output stop bit invalid");
        line_data[(74-1-character_index)*8 +: 8]=character;
        if(character_index==9 && character=="1") mode_seen=1;
        if(character_index==34 && character=="1") frozen_seen=1;
        if(character_index==73) begin
            if(line_data[8*74-1 -: 8*7]!=="CAMLCD " || line_data[15:0]!==16'h0d0a)
                $fatal(1,"UART status record was corrupted");
            line_count=line_count+1;
            $display("UART %0s",line_data);
            character_index=0;
        end else character_index=character_index+1;
    end

    initial begin
        cycles(10); reset_n=1;
        wait(!dut.reset); cycles(10);
        if(dut.camera_mode || dut.frozen) $fatal(1,"Default LCD mode incorrect");
        keys_n[0]=0; cycles(3); keys_n[0]=1; cycles(12);
        if(dut.camera_mode || dut.pressed!=0) $fatal(1,"Key glitch was not rejected");
        press_key(0); if(!dut.camera_mode) $fatal(1,"KEY2 camera mode failed");
        press_key(1); if(dut.camera_mode) $fatal(1,"KEY3 LCD bars failed");
        press_key(2); if(!dut.frozen) $fatal(1,"KEY4 freeze failed");
        previous_restarts=restart_count;
        press_key(3);
        if(!dut.sensor_bars || !dut.camera_mode || dut.frozen || restart_count!=previous_restarts+1)
            $fatal(1,"KEY5 sensor bars/reinitialization failed");
        previous_restarts=restart_count;
        press_key(4);
        if(restart_count!=previous_restarts+1) $fatal(1,"KEY6 initialization failed");
        previous_reports=report_count;
        press_key(5);
        if(report_count!=previous_reports+1) $fatal(1,"KEY7 status request failed");
        for(key_index=0;key_index<6;key_index=key_index+1)
            if(dut.pressed[key_index]) $fatal(1,"Key release did not debounce");
        send_command("b",0); if(dut.camera_mode) $fatal(1,"UART b failed");
        send_command("c",0); if(!dut.camera_mode) $fatal(1,"UART c failed");
        send_command("f",0); if(!dut.frozen) $fatal(1,"UART f failed");
        send_command("f",1);
        if(!dut.frozen || dut.uart_errors!=1) $fatal(1,"Invalid UART stop bit changed mode");
        send_command("?",0);
        wait(line_count>=2 && mode_seen && frozen_seen);
        send_command("t",0);
        if(dut.sensor_bars || dut.frozen || !dut.camera_mode) $fatal(1,"UART t failed");
        previous_restarts=restart_count;
        send_command("r",0);
        if(restart_count!=previous_restarts+1) $fatal(1,"UART r failed");
        if(dut.touch_cs_n!==1 || dut.touch_sclk!==0 || dut.touch_mosi!==0)
            $fatal(1,"Reserved touch SPI pins are not idle");
        $display("PASS tb_controls: six debounced keys, UART commands/status/framing, defaults, touch idle");
        $finish;
    end
    initial begin #30000000; $fatal(1,"tb_controls watchdog"); end
endmodule
