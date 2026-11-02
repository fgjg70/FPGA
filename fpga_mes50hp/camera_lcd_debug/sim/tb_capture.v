`timescale 1ns/1ps

module tb_capture;
    reg clk=0;
    always #18.5185 clk=~clk;
    reg reset=1;
    reg configured=0;
    reg freeze=0;
    reg vsync=0;
    reg [7:0] fifo_data=0;
    wire rclk, we, oe_n, wrst_n, rrst_n;
    wire pixel_write, frame_done, frame_ack, frame_valid;
    wire [14:0] write_address;
    wire [15:0] write_data;
    wire [15:0] frames, timeouts, vsyncs;
    wire [3:0] state;
    reg frame_tick=0;
    reg [14:0] read_address=0;
    wire [15:0] read_data;
    integer fifo_pointer=0;
    integer reset_edges=0;
    integer read_edges=0;
    integer writes=0;
    integer generation=0;
    integer address_index;
    reg [15:0] output_word;

    camera_fifo_capture #(.WIDTH(8),.HEIGHT(4),.TIMEOUT_CYCLES(5000),.WARMUP_FRAMES(1)) dut (
        .clk(clk),.reset(reset),.configured(configured),.freeze(freeze),.frame_ack(frame_ack),
        .vsync(vsync),.data(fifo_data),.rclk(rclk),.we(we),.oe_n(oe_n),.wrst_n(wrst_n),
        .rrst_n(rrst_n),.pixel_write(pixel_write),.pixel_address(write_address),
        .pixel_data(write_data),.frame_done(frame_done),.frame_count(frames),
        .timeout_count(timeouts),.vsync_count(vsyncs),.state(state)
    );
    camera_framebuffer #(.PIXELS(8)) buffer (
        .clk(clk),.reset(reset),.pixel_write(pixel_write),.write_address(write_address),
        .write_data(write_data),.frame_done(frame_done),.frame_tick(frame_tick),
        .read_address(read_address),.read_data(read_data),.frame_valid(frame_valid),.frame_ack(frame_ack)
    );

    function [15:0] source_pixel;
        input integer pixel_index;
        input integer frame_index;
        begin source_pixel=16'h8000+pixel_index+frame_index*16'h2000; end
    endfunction

    function [15:0] expected_pixel;
        input integer pixel_index;
        input integer frame_index;
        begin expected_pixel=source_pixel((pixel_index/4)*16+(pixel_index%4)*2,frame_index); end
    endfunction

    always @(posedge rclk) begin
        if (!rrst_n) begin
            fifo_pointer=0;
            reset_edges=reset_edges+1;
        end else if (!oe_n) begin
            if (we) $fatal(1,"FIFO read overlaps sensor write");
            output_word=source_pixel(fifo_pointer/2,generation);
            if (fifo_pointer%2 == 0) fifo_data <= #20 output_word[15:8];
            else fifo_data <= #20 output_word[7:0];
            fifo_pointer=fifo_pointer+1;
            read_edges=read_edges+1;
        end
    end

    always @(posedge clk) if (pixel_write && !reset) begin
        if (write_address !== (writes%8)) $fatal(1,"Noncontiguous destination address");
        if (write_data !== expected_pixel(writes%8,generation))
            $fatal(1,"RGB565 byte order or downsampling incorrect at %d: %h",writes,write_data);
        writes=writes+1;
    end

    task cycles;
        input integer count;
        integer cycle_index;
        begin for(cycle_index=0;cycle_index<count;cycle_index=cycle_index+1) @(negedge clk); end
    endtask

    task sync_pulse;
        begin vsync=1; cycles(20); vsync=0; cycles(20); end
    endtask

    task check_front;
        input integer frame_index;
        begin
            for(address_index=0;address_index<8;address_index=address_index+1) begin
                read_address=address_index;
                cycles(3);
                if(read_data !== expected_pixel(address_index,frame_index))
                    $fatal(1,"Front buffer changed before swap, or pixel invalid: %d %h",address_index,read_data);
            end
        end
    endtask

    task swap;
        begin frame_tick=1; cycles(1); frame_tick=0; cycles(4); end
    endtask

    initial begin
        cycles(6); reset=0; configured=1;
        sync_pulse();
        wait(state==1); cycles(3);
        sync_pulse();
        if(!we || !wrst_n) $fatal(1,"Sensor capture did not start after VSYNC falling edge");
        cycles(100); vsync=1; cycles(20); vsync=0;
        wait(frame_done); cycles(2);
        if(frame_valid || state!=7) $fatal(1,"Frame published outside LCD blanking");
        if(writes!=8 || read_edges!=64 || reset_edges!=3 || frames!=1)
            $fatal(1,"First FIFO frame length/reset mismatch");
        freeze=1; swap();
        if(!frame_valid) $fatal(1,"Frame swap missing");
        check_front(0);
        sync_pulse();
        if(we) $fatal(1,"Freeze started a new capture");
        generation=1; freeze=0; cycles(4); sync_pulse();
        if(!we) $fatal(1,"Unfreeze did not restart capture");
        freeze=1;
        cycles(100); vsync=1; cycles(20); vsync=0;
        wait(frame_done); cycles(2);
        check_front(0);
        if(writes!=16 || read_edges!=128 || reset_edges!=6 || frames!=2)
            $fatal(1,"Second FIFO frame length/reset mismatch");
        swap(); check_front(1);
        cycles(5100);
        if(timeouts!=0) $fatal(1,"Freeze incorrectly counted as camera timeout");
        freeze=0; cycles(5100);
        if(timeouts!=1 || we || !wrst_n) $fatal(1,"Missing VSYNC timeout recovery failed");
        sync_pulse();
        if(!we) $fatal(1,"Camera did not recover after timeout");
        reset=1; cycles(3);
        if(we || rclk || !oe_n || !wrst_n || !rrst_n || frame_valid)
            $fatal(1,"Reset did not return FIFO controls to idle");
        $display("PASS tb_capture: FIFO first byte, RGB565, decimation, double buffer, freeze, timeout, reset");
        $finish;
    end

    initial begin #2000000; $fatal(1,"tb_capture watchdog"); end
endmodule
