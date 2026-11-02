`timescale 1ns/1ps

module tb_video;
    reg clk=0;
    always #18.5185 clk=~clk;
    reg reset=1;
    reg camera_mode=0;
    reg [15:0] image_pixel=0;
    wire [14:0] image_address;
    wire frame_tick,dclk,hsync,vsync,de;
    wire [4:0] red,blue;
    wire [5:0] green;
    integer pixel_index,active_count,hs_count,vs_count;
    integer pixel_x,pixel_y,source_x,source_y;
    integer output_file;
    reg [15:0] expected;
    realtime previous_edge=0;
    realtime data_edge=0;
    realtime delta;

    lcd_debug_video dut (
        .clk(clk),.reset(reset),.camera_mode(camera_mode),.frame_valid(1'b1),
        .configured(1'b1),.failed(1'b0),.frozen(1'b0),.pen_down(1'b0),
        .image_pixel(image_pixel),.image_address(image_address),.frame_tick(frame_tick),
        .dclk(dclk),.hsync(hsync),.vsync(vsync),.de(de),.red(red),.green(green),.blue(blue)
    );
    function [15:0] image_color;
        input integer address;
        reg [4:0] image_red,image_blue;
        reg [5:0] image_green;
        begin
            image_red=(address%160)/8;
            image_green=(address/160)/2;
            image_blue=address%32;
            image_color={image_red,image_green,image_blue};
        end
    endfunction
    always @(posedge clk) image_pixel<=image_color(image_address);
    always @(red or green or blue or de or hsync or vsync) data_edge=$realtime;
    always @(dclk) begin
        if(!reset && previous_edge!=0) begin
            delta=$realtime-previous_edge;
            if(delta<55.55 || delta>55.56) $fatal(1,"LCD clock duty cycle incorrect: %f",delta);
        end
        previous_edge=$realtime;
    end

    task capture_frame;
        input integer camera;
        begin
            active_count=0; hs_count=0; vs_count=0;
            wait(frame_tick); camera_mode=camera;
            if(camera) output_file=$fopen("camera_gradient.ppm","w");
            else output_file=$fopen("lcd_colorbars.ppm","w");
            $fwrite(output_file,"P3\n480 272\n255\n");
            for(pixel_index=0;pixel_index<525*286;pixel_index=pixel_index+1) begin
                @(posedge dclk); #1;
                if($realtime-data_edge<36) $fatal(1,"LCD data setup time too short");
                if(!hsync) hs_count=hs_count+1;
                if(!vsync) vs_count=vs_count+1;
                if(de) begin
                    pixel_x=active_count%480; pixel_y=active_count/480;
                    if(!camera) begin
                        case(pixel_x/60)
                            0: expected=16'hffff;
                            1: expected=16'hffe0;
                            2: expected=16'h07ff;
                            3: expected=16'h07e0;
                            4: expected=16'hf81f;
                            5: expected=16'hf800;
                            6: expected=16'h001f;
                            7: expected=16'h0000;
                        endcase
                    end else begin
                        expected=16'h18e3;
                        if(pixel_x>=80 && pixel_x<400 && pixel_y>=16 && pixel_y<256) begin
                            source_x=(pixel_x-80)/2; source_y=(pixel_y-16)/2;
                            expected=image_color(source_y*160+source_x);
                        end
                        if(pixel_y<8) expected=16'h07e0;
                        if(pixel_y>=264) expected=16'h001f;
                    end
                    if({red,green,blue} !== expected)
                        $fatal(1,"LCD pixel mismatch mode=%d x=%d y=%d got=%h expected=%h",camera,pixel_x,pixel_y,{red,green,blue},expected);
                    $fwrite(output_file,"%0d %0d %0d\n",{red,red[4:2]},{green,green[5:4]},{blue,blue[4:2]});
                    active_count=active_count+1;
                end else if({red,green,blue} !== 16'h0000) $fatal(1,"Nonzero LCD blanking data");
            end
            $fclose(output_file);
            if(active_count!=480*272 || hs_count!=41*286 || vs_count!=10*525)
                $fatal(1,"AN430 raster dimensions or sync pulse widths incorrect");
            @(negedge dclk);
        end
    endtask

    initial begin
        repeat(8) @(negedge clk);
        previous_edge=0; reset=0;
        capture_frame(0);
        capture_frame(1);
        $display("PASS tb_video: 480x272, 525x286, 9MHz 50%% duty, data setup, color bars, scaled camera raster");
        $finish;
    end
    initial begin #40000000; $fatal(1,"tb_video watchdog"); end
endmodule
