`timescale 1ns/1ps

module tb_npu;
    reg clk = 0;
    always #5 clk = !clk;
    reg reset = 1;
    reg model_select = 0;
    reg input_write = 0;
    reg [11:0] input_address = 0;
    reg [7:0] input_data = 0;
    reg start = 0;
    reg acknowledge = 0;
    reg [8:0] result_address = 0;
    wire signed [31:0] result_data;
    wire busy;
    wire done;
    wire [31:0] cycles;
    reg [7:0] pixels [0:4095];
    reg [31:0] expected [0:431];
    reg [2047:0] vector_dir;
    reg [2047:0] filename;
    integer sample_index;
    integer word_index;
    vision_npu dut (.clk(clk), .reset(reset), .model_select(model_select), .input_write(input_write), .input_address(input_address), .input_data(input_data),
                    .start(start), .acknowledge(acknowledge), .result_address(result_address), .result_data(result_data),
                    .busy(busy), .done(done), .cycles(cycles));
    initial begin
        if (!$value$plusargs("vectors=%s", vector_dir)) $fatal(1, "Missing vector directory");
        repeat (4) @(negedge clk);
        reset = 0;
        for (sample_index = 0; sample_index < 4; sample_index = sample_index + 1) begin
            model_select = sample_index >= 2;
            if (model_select) $sformat(filename, "%0s/hand_input_%0d.hex", vector_dir, sample_index - 2);
            else $sformat(filename, "%0s/input_%0d.hex", vector_dir, sample_index);
            $readmemh(filename, pixels);
            if (model_select) $sformat(filename, "%0s/hand_output_%0d.hex", vector_dir, sample_index - 2);
            else $sformat(filename, "%0s/output_%0d.hex", vector_dir, sample_index);
            $readmemh(filename, expected);
            for (word_index = 0; word_index < 4096; word_index = word_index + 1) begin
                input_write = 1;
                input_address = word_index;
                input_data = pixels[word_index];
                @(negedge clk);
            end
            input_write = 0;
            start = 1;
            @(negedge clk);
            start = 0;
            repeat (10) @(negedge clk);
            model_select = !model_select;
            input_write = 1;
            input_address = 0;
            input_data = 8'h7f;
            @(negedge clk);
            input_write = 0;
            wait(done);
            @(negedge clk);
            if (busy) $fatal(1, "Busy remained set after completion");
            if (cycles != 1769238) $fatal(1, "Unexpected NPU cycle count %0d", cycles);
            for (word_index = 0; word_index < 432; word_index = word_index + 1) begin
                result_address = word_index;
                repeat (2) @(negedge clk);
                if (result_data !== expected[word_index])
                    $fatal(1, "NPU mismatch sample=%0d word=%0d actual=%0d expected=%0d", sample_index, word_index, result_data, $signed(expected[word_index]));
            end
            repeat (8) @(negedge clk);
            if (!done || busy) $fatal(1, "Results not held until acknowledge");
            acknowledge = 1;
            @(negedge clk);
            acknowledge = 0;
            @(negedge clk);
            if (done) $fatal(1, "Acknowledge did not clear done");
            $display("PASS npu sample=%0d exact_words=432 cycles=%0d", sample_index, cycles);
        end
        start = 1;
        @(negedge clk);
        start = 0;
        repeat (20) @(negedge clk);
        reset = 1;
        @(negedge clk);
        reset = 0;
        @(negedge clk);
        if (busy || done) $fatal(1, "Reset failed to cancel inference");
        $display("PASS npu hold/ack/reset/input-write-guard");
        $finish;
    end
    initial begin #100000000; $fatal(1, "NPU test timeout"); end
endmodule
