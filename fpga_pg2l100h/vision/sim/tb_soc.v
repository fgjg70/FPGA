`timescale 1ns/1ps

module tb_soc #(
    parameter HAND_MODE = 0
);
    reg clk = 0;
    always #10 clk = !clk;
    reg cpu_clk = 0;
    always #4 cpu_clk = !cpu_clk;
    reg reset = 1;
    reg uart_rxd = 1;
    reg [3:0] keys_n = 4'hf;
    wire uart_txd;
    reg configured = 0;
    reg failed = 0;
    reg frame_valid = 0;
    reg [15:0] frame_count = 0;
    reg [9:0] frame_phase = 0;
    wire frame_tick = frame_phase == 0;
    reg pixel_write = 0;
    reg [14:0] pixel_address = 0;
    reg [15:0] pixel_data = 0;
    reg frame_done = 0;
    wire frozen;
    wire show_bars;
    wire restart;
    wire overlay_valid;
    wire [9:0] box_left;
    wire [8:0] box_top;
    wire [9:0] box_right;
    wire [8:0] box_bottom;
    wire [5:0] label;
    wire inference_busy;
    wire cpu_illegal;
    reg [15:0] camera_pixels [0:19199];
    reg [7:0] model_pixels [0:4095];
    reg [31:0] expected [0:7];
    reg [2047:0] vector_dir;
    reg [2047:0] filename;
    reg [7:0] received;
    reg [111:0] prefix = "VISION50 READY";
    reg [56:0] previous_box = 0;
    reg tick_before;
    reg model_change;
    integer byte_count = 0;
    integer bit_index;
    integer pixel_index;
    integer elapsed_cycles = 0;
    vision_soc #(.LONG_PRESS_CYCLES(100)) dut (.clk(clk), .reset(reset), .keys_n(keys_n), .uart_rxd(uart_rxd), .uart_txd(uart_txd),
        .cpu_clk(cpu_clk), .cpu_reset(reset),
        .configured(configured), .failed(failed), .frame_valid(frame_valid), .frame_count(frame_count), .frame_tick(frame_tick),
        .pixel_write(pixel_write), .pixel_address(pixel_address), .pixel_data(pixel_data), .frame_done(frame_done),
        .frozen(frozen), .show_bars(show_bars), .restart(restart), .overlay_valid(overlay_valid),
        .box_left(box_left), .box_top(box_top), .box_right(box_right), .box_bottom(box_bottom), .label(label),
        .inference_busy(inference_busy), .cpu_illegal(cpu_illegal));
    defparam dut.keys.DEBOUNCE_CYCLES = 6;
    always @(posedge clk) begin
        elapsed_cycles = elapsed_cycles + 1;
        if (elapsed_cycles % 250000 == 0)
            $display("TRACE soc cycles=%0d pc=%h busy=%b done=%b overlay=%b count=%0d panel=%h", elapsed_cycles,
                dut.processor.dbg_pc, inference_busy, dut.inference_done, overlay_valid, dut.completed_count, dut.panel_status);
        frame_phase <= frame_phase + 1'b1;
        tick_before = frame_tick;
        model_change = dut.model_write;
        #1;
        if (!reset && cpu_illegal) $fatal(1, "RISC-V executed illegal instruction");
        if (!reset && configured && dut.control[0] && !show_bars && !model_change && {overlay_valid, label, box_left, box_top, box_right, box_bottom} !== previous_box && !tick_before)
            $fatal(1, "Detection changed away from frame boundary");
        previous_box = {overlay_valid, label, box_left, box_top, box_right, box_bottom};
    end
    initial forever begin
        @(negedge uart_txd);
        repeat (651) @(negedge clk);
        for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
            received[bit_index] = uart_txd;
            repeat (434) @(negedge clk);
        end
        if (!uart_txd) $fatal(1, "UART stop bit missing");
        if (byte_count < 14 && received !== prefix[111 - byte_count * 8 -: 8]) $fatal(1, "Wrong RISC-V boot message at byte %0d: %h", byte_count, received);
        byte_count = byte_count + 1;
    end
    task send_command;
        input [7:0] command;
        integer command_bit;
        begin
            @(negedge clk); uart_rxd = 0;
            repeat (434) @(negedge clk);
            for (command_bit = 0; command_bit < 8; command_bit = command_bit + 1) begin
                uart_rxd = command[command_bit];
                repeat (434) @(negedge clk);
            end
            uart_rxd = 1;
            repeat (434) @(negedge clk);
        end
    endtask
    task press_mode;
        input [1:0] expected_mode;
        begin
            @(negedge clk); keys_n[0] = 0;
            repeat (180) @(negedge clk);
            keys_n[0] = 1;
            wait(dut.application_mode === expected_mode && dut.panel_status[24:23] === expected_mode);
            repeat (1000) @(negedge clk);
            if (overlay_valid || dut.inference_done || dut.next_target_pending)
                $fatal(1, "Mode button kept old results or emitted a short-press event");
        end
    endtask
    initial begin
        if (!$value$plusargs("vectors=%s", vector_dir)) vector_dir = "../../validation";
        if (HAND_MODE) $sformat(filename, "%0s/hand_camera.hex", vector_dir);
        else $sformat(filename, "%0s/camera.hex", vector_dir);
        $readmemh(filename, camera_pixels);
        if (HAND_MODE) $sformat(filename, "%0s/hand_soc_expected.hex", vector_dir);
        else $sformat(filename, "%0s/soc_expected.hex", vector_dir);
        $readmemh(filename, expected);
        if (HAND_MODE) $sformat(filename, "%0s/hand_model_input.hex", vector_dir);
        else $sformat(filename, "%0s/model_input.hex", vector_dir);
        $readmemh(filename, model_pixels);
        repeat (5) @(negedge clk);
        reset = 0;
        wait(byte_count >= 14);
        $display("TRACE soc RISC-V UART boot prefix received");
        configured = 1;
        frame_valid = 1;
        repeat (300) @(negedge clk);
        for (pixel_index = 0; pixel_index < 19200; pixel_index = pixel_index + 1) begin
            pixel_write = 1; pixel_address = pixel_index; pixel_data = camera_pixels[pixel_index];
            @(negedge clk);
            pixel_write = 0;
            @(negedge clk);
        end
        frame_done = 1; frame_count = 1;
        @(negedge clk);
        frame_done = 0;
        wait(inference_busy);
        $display("TRACE soc NPU started");
        if (HAND_MODE) begin
            send_command("g");
            wait(dut.model_select === 1'b1);
            repeat (300) @(negedge clk);
            if (inference_busy || dut.inference_done || overlay_valid || dut.completed_count)
                $fatal(1, "Model switch did not cancel the previous inference");
            for (pixel_index = 0; pixel_index < 19200; pixel_index = pixel_index + 1) begin
                pixel_write = 1; pixel_address = pixel_index; pixel_data = camera_pixels[pixel_index];
                @(negedge clk); pixel_write = 0; @(negedge clk);
            end
            frame_done = 1; frame_count = 2;
            @(negedge clk); frame_done = 0;
            wait(inference_busy);
            if (!dut.accelerator.active_model) $fatal(1, "Gesture weights were not selected");
        end
        wait(overlay_valid);
        @(negedge clk);
        if (label !== expected[1][5:0] || box_left !== expected[2][9:0] || box_top !== expected[3][8:0] ||
            box_right !== expected[4][9:0] || box_bottom !== expected[5][8:0])
            $fatal(1, "RISC-V decode mismatch label=%0d box=%0d,%0d,%0d,%0d", label, box_left, box_top, box_right, box_bottom);
        repeat (100) @(negedge clk);
        if (dut.completed_count != 1) $fatal(1, "RISC-V did not acknowledge NPU result");
        for (pixel_index = 0; pixel_index < 4096; pixel_index = pixel_index + 1)
            if (dut.sample_memory[pixel_index] !== model_pixels[pixel_index]) $fatal(1, "UART snapshot memory mismatch at %0d", pixel_index);
        if (dut.panel_status[11:8] !== expected[1] - (HAND_MODE ? 32'd2 : 32'd12) ||
            dut.panel_status[23] !== (HAND_MODE != 0) || dut.pass_count || dut.reject_count)
            $fatal(1, "Numeric panel state mismatch or unsafe startup count");
        if (HAND_MODE) begin
            $display("PASS soc_hand real RISC-V firmware + skin snapshot + gesture INT8 bank label=%0d box=%0d,%0d,%0d,%0d cycles=%0d", label, box_left, box_top, box_right, box_bottom, dut.inference_cycles);
            repeat (300) @(negedge clk);
            for (pixel_index = 0; pixel_index < 19200; pixel_index = pixel_index + 1) begin
                pixel_write = 1; pixel_address = pixel_index; pixel_data = camera_pixels[pixel_index];
                @(negedge clk); pixel_write = 0; @(negedge clk);
            end
            frame_done = 1;
            @(negedge clk); frame_done = 0;
            wait(inference_busy);
            press_mode(2);
            if (dut.model_ready || !dut.panel_status[25] || inference_busy || dut.completed_count != 1)
                $fatal(1, "COCO mode did not cancel the busy hand inference");
            frame_done = 1;
            repeat (500) @(negedge clk);
            frame_done = 0;
            if (inference_busy || dut.inference_start || overlay_valid) $fatal(1, "Unavailable COCO mode executed the digit engine");
            keys_n[0] = 0; repeat (20) @(negedge clk); keys_n[0] = 1;
            repeat (10000) @(negedge clk);
            if (dut.application_mode !== 2 || dut.panel_status[24:23] !== 2) $fatal(1, "Short target press changed the application mode");
            press_mode(0);
            if (!dut.model_ready || dut.panel_status[25]) $fatal(1, "Return to handwriting did not restore readiness");
            press_mode(1);
            if (!dut.model_select || dut.panel_status[25]) $fatal(1, "Three-mode cycle did not return to gesture bank");
            send_command("l");
            wait(dut.application_mode === 2'd0);
            repeat (100000) @(negedge clk);
            if (overlay_valid || dut.inference_done || dut.panel_status[23]) $fatal(1, "Return to label mode kept stale hand state");
            $display("PASS soc_hand physical-key three-mode cycle, missing COCO interlock, busy cancellation, 4096 silhouette bytes, UART compatibility and safe return");
        end else $display("PASS soc real RISC-V firmware + RGB565 snapshot + INT8 NPU label=%0d box=%0d,%0d,%0d,%0d cycles=%0d", label, box_left, box_top, box_right, box_bottom, dut.inference_cycles);
        send_command("n");
        repeat (1000) @(negedge clk);
        if (dut.control[0] || overlay_valid) $fatal(1, "UART inference-disable command failed");
        configured = 0;
        repeat (10) @(negedge clk);
        if (inference_busy || overlay_valid) $fatal(1, "Camera disconnect did not clear inference and overlay");
        $display("PASS soc UART boot/command, frame-atomic commit, 4096 capture-memory bytes, startup interlock, disconnect clear, no illegal instructions");
        $finish;
    end
    initial begin #100000000; $fatal(1, "SoC test timeout"); end
endmodule
