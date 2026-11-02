`timescale 1ns/1ps

module tb_cdc;
    reg system_clk = 0;
    reg video_clk = 0;
    always #10 system_clk = !system_clk;
    initial begin #7; forever #18.5185 video_clk = !video_clk; end
    reg reset = 1;
    reg [271:0] source_payload = 0;
    wire [271:0] display_payload;
    reg video_tick = 0;
    wire system_tick;
    integer video_phase = 0;
    integer video_ticks = 0;
    integer system_ticks = 0;
    integer commits = 0;
    integer sequence_index;
    reg [271:0] previous_payload = 0;
    reg tick_before;
    reg previous_system_tick = 0;
    reg pixel_write = 0;
    reg [14:0] write_address = 0;
    reg [15:0] write_data = 0;
    reg frame_done = 0;
    reg frame_tick = 0;
    reg [14:0] read_address = 0;
    wire [15:0] read_data;
    wire frame_ack;
    wire frame_valid;
    wire display_valid;
    reg permit_ack = 0;
    integer acknowledgements = 0;
    integer pixel_index;

    vision_video_bridge #(.PAYLOAD_BITS(272)) bridge (.system_clk(system_clk), .system_reset(reset), .source_payload(source_payload),
        .video_clk(video_clk), .video_reset(reset), .video_frame_tick(video_tick),
        .display_payload(display_payload), .system_frame_tick(system_tick));
    vision_framebuffer #(.PIXELS(16)) framebuffer (.write_clk(system_clk), .reset(reset),
        .pixel_write(pixel_write), .write_address(write_address), .write_data(write_data), .frame_done(frame_done),
        .frame_ack(frame_ack), .frame_valid(frame_valid), .read_clk(video_clk), .frame_tick(frame_tick),
        .read_address(read_address), .read_data(read_data), .display_valid(display_valid));

    always @(negedge video_clk) begin
        if (reset) begin video_phase = 0; video_tick = 0; end
        else begin
            video_tick = video_phase == 36;
            video_phase = video_phase == 36 ? 0 : video_phase + 1;
        end
    end
    always @(posedge video_clk) begin
        tick_before = video_tick;
        if (!reset && video_tick) video_ticks = video_ticks + 1;
        #1;
        if (!reset && display_payload !== previous_payload) begin
            if (!tick_before) $fatal(1, "Overlay changed inside a video frame");
            if (display_payload !== {display_payload[127:96], ~display_payload[127:96],
                    display_payload[127:96] ^ 32'h1234abcd, display_payload[127:96] + 32'd4,
                    16'h5a5a, display_payload[127:96], ~display_payload[127:96],
                    display_payload[127:96] ^ 32'hcafe1234, display_payload[127:96] + 32'd1})
                $fatal(1, "Torn overlay packet");
            commits = commits + 1;
        end
        previous_payload = display_payload;
    end
    always @(posedge system_clk) begin
        if (!reset) begin
            if (system_tick) begin
                if (previous_system_tick) $fatal(1, "Stretched frame tick");
                system_ticks = system_ticks + 1;
            end
            if (frame_ack) begin
                if (!permit_ack) $fatal(1, "Framebuffer acknowledged before video boundary");
                acknowledgements = acknowledgements + 1;
            end
        end
        previous_system_tick = system_tick;
    end

    task publish;
        input [31:0] sequence_value;
        begin
            @(negedge system_clk);
            source_payload = {sequence_value, ~sequence_value, sequence_value ^ 32'h1234abcd, sequence_value + 32'd4,
                16'h5a5a, sequence_value, ~sequence_value, sequence_value ^ 32'hcafe1234, sequence_value + 32'd1};
        end
    endtask
    task write_frame;
        input [15:0] base;
        begin
            for (pixel_index = 0; pixel_index < 16; pixel_index = pixel_index + 1) begin
                @(negedge system_clk);
                pixel_write = 1;
                write_address = pixel_index;
                write_data = base + pixel_index;
            end
            @(negedge system_clk); pixel_write = 0; frame_done = 1;
            @(negedge system_clk); frame_done = 0;
        end
    endtask
    task swap_frame;
        begin
            repeat (6) @(negedge video_clk);
            permit_ack = 1;
            frame_tick = 1;
            @(negedge video_clk); frame_tick = 0;
            wait(frame_ack === 1'b1);
            repeat (3) @(negedge system_clk);
            permit_ack = 0;
            if (!frame_valid || !display_valid) $fatal(1, "Valid frame did not cross clock domains");
        end
    endtask
    task check_frame;
        input [15:0] base;
        integer read_index;
        begin
            for (read_index = 0; read_index < 16; read_index = read_index + 1) begin
                @(negedge video_clk); read_address = read_index;
                @(negedge video_clk);
                if (read_data !== base + read_index) $fatal(1, "Torn framebuffer pixel %0d: %h", read_index, read_data);
            end
        end
    endtask

    initial begin
        repeat (8) @(negedge system_clk); reset = 0;
        publish(32'd1);
        write_frame(16'h1200);
        if (display_valid || frame_ack) $fatal(1, "Premature first frame");
        swap_frame;
        check_frame(16'h1200);
        write_frame(16'h3400);
        check_frame(16'h1200);
        @(negedge system_clk); pixel_write = 1; write_data = 16'hdead;
        repeat (4) @(negedge system_clk);
        pixel_write = 0;
        swap_frame;
        check_frame(16'h3400);
        for (sequence_index = 2; sequence_index < 200; sequence_index = sequence_index + 1) begin
            publish(sequence_index);
            repeat (sequence_index % 7 + 1) @(negedge system_clk);
        end
        publish(32'h12345678);
        repeat (180) @(negedge video_clk);
        if (display_payload !== source_payload || commits < 5) $fatal(1, "Overlay handshake lost final update");
        @(negedge video_clk); video_phase = 0;
        repeat (8) @(negedge system_clk);
        if (video_ticks != system_ticks) $fatal(1, "Lost video frame tick: %0d/%0d", video_ticks, system_ticks);
        #3; reset = 1;
        repeat (8) @(negedge system_clk);
        if (frame_valid || display_valid) $fatal(1, "Framebuffer reset did not invalidate old image");
        reset = 0;
        publish(32'd77);
        write_frame(16'h5600);
        swap_frame;
        check_frame(16'h5600);
        if (acknowledgements != 3) $fatal(1, "Duplicate framebuffer acknowledgement");
        $display("PASS cdc 50/27MHz coherent 272-bit DVP/overlay packet, frame-only commits, exact event pulses, double-buffer ownership and reset");
        $finish;
    end
    initial begin #1000000; $fatal(1, "CDC test timeout"); end
endmodule
