`timescale 1ns/1ps

module vision_graph_npu (
    input wire clk,
    input wire reset,
    input wire register_write,
    input wire [7:0] register_address,
    input wire [31:0] register_wdata,
    output reg [31:0] register_rdata,
    input wire [31:0] memory_status,
    output reg memory_read,
    output reg memory_write,
    output reg [31:0] memory_address,
    output reg [31:0] memory_wdata,
    input wire memory_ready,
    input wire [31:0] memory_rdata
);
    localparam IDLE=0, SETUP=1, WEIGHT_REQUEST=2, WEIGHT_WAIT=3, PARAM_REQUEST=4, PARAM_WAIT=5,
               ROW_BEGIN=6, ROW_REQUEST=7, ROW_WAIT=8, ROW_PAD=9, INITIALIZE=10, FETCH=11,
               MAC=12, EMIT=13, STORE_WAIT=14, ADVANCE=15, COPY_FETCH=16, COPY_VALUE=17, FINISH=18;
    reg [4:0] state;
    reg [31:0] configuration [0:9];
    reg busy;
    reg done;
    reg fault;
    reg abort_requested;
    reg [31:0] cycles;
    reg [31:0] input_cache [0:8191];
    reg [31:0] weight_cache [0:8191];
    reg signed [31:0] bias_zero [0:63];
    reg signed [31:0] bias_one [0:63];
    reg signed [31:0] bias_two [0:63];
    reg signed [31:0] bias_three [0:63];
    reg [7:0] shift_zero [0:63];
    reg [7:0] shift_one [0:63];
    reg [7:0] shift_two [0:63];
    reg [7:0] shift_three [0:63];
    reg [31:0] input_read;
    reg [31:0] weight_read;
    reg [1:0] byte_offset;
    reg invalid_pixel;
    reg signed [31:0] accumulator_zero;
    reg signed [31:0] accumulator_one;
    reg signed [31:0] accumulator_two;
    reg signed [31:0] accumulator_three;
    reg [15:0] output_x;
    reg [15:0] output_y;
    reg [7:0] output_group;
    reg [15:0] input_channel;
    reg [3:0] kernel_x;
    reg [3:0] kernel_y;
    reg [3:0] cache_row;
    reg [15:0] row_word;
    reg [15:0] load_index;
    reg [15:0] weight_count;
    reg [15:0] weight_span;
    reg [15:0] weight_base;
    reg [15:0] mac_index;
    reg [1:0] copy_lane;
    integer configuration_index;
    wire [31:0] source_base = configuration[0];
    wire [31:0] weights_base = configuration[1];
    wire [31:0] parameters_base = configuration[2];
    wire [31:0] destination_base = configuration[3];
    wire [15:0] input_width = configuration[4][15:0];
    wire [15:0] input_height = configuration[4][31:16];
    wire [15:0] input_channels = configuration[5][15:0];
    wire [15:0] output_channels = configuration[5][31:16];
    wire [15:0] output_width = configuration[6][15:0];
    wire [15:0] output_height = configuration[6][31:16];
    wire [3:0] opcode = configuration[7][3:0];
    wire [3:0] kernel = configuration[7][7:4];
    wire [3:0] stride = configuration[7][11:8];
    wire [3:0] padding = configuration[7][15:12];
    wire relu = configuration[7][16];
    wire signed [7:0] copy_shift = configuration[7][31:24];
    wire [15:0] destination_channels = configuration[8][15:0];
    wire [15:0] destination_offset = configuration[8][31:16];
    wire [7:0] source_step = configuration[9][7:0];
    wire upsample = configuration[9][8];
    wire [15:0] source_offset = configuration[9][31:16];
    wire [31:0] row_bytes = input_width * input_channels;
    wire [31:0] row_words = row_bytes >> 2;
    wire [7:0] output_groups = output_channels >> 2;
    wire signed [31:0] source_y = opcode == 4 ? $signed({16'd0, output_y} >> upsample) : $signed(output_y * stride) - $signed({28'd0, padding}) + $signed({28'd0, cache_row});
    wire signed [31:0] source_x = $signed(output_x * stride) + $signed({28'd0, kernel_x}) - $signed({28'd0, padding});
    wire [31:0] activation_index = kernel_y * row_bytes + source_x * input_channels + (opcode == 1 ? {16'd0, input_channel} : {22'd0, output_group, 2'b00});
    wire [31:0] copy_index = (output_x >> upsample) * input_channels + source_offset + (output_group * 4 + copy_lane) * source_step;
    wire [31:0] cached_index = cache_row * row_words + row_word;
    wire signed [7:0] selected_byte = input_read >> {byte_offset, 3'b000};
    wire signed [7:0] input_zero = invalid_pixel ? (opcode == 3 ? -8'sd128 : 8'sd0) : (opcode == 1 ? selected_byte : $signed(input_read[7:0]));
    wire signed [7:0] input_one = invalid_pixel ? (opcode == 3 ? -8'sd128 : 8'sd0) : (opcode == 1 ? selected_byte : $signed(input_read[15:8]));
    wire signed [7:0] input_two = invalid_pixel ? (opcode == 3 ? -8'sd128 : 8'sd0) : (opcode == 1 ? selected_byte : $signed(input_read[23:16]));
    wire signed [7:0] input_three = invalid_pixel ? (opcode == 3 ? -8'sd128 : 8'sd0) : (opcode == 1 ? selected_byte : $signed(input_read[31:24]));
    wire signed [15:0] product_zero = input_zero * $signed(weight_read[7:0]);
    wire signed [15:0] product_one = input_one * $signed(weight_read[15:8]);
    wire signed [15:0] product_two = input_two * $signed(weight_read[23:16]);
    wire signed [15:0] product_three = input_three * $signed(weight_read[31:24]);
    wire waiting_memory = state == WEIGHT_WAIT || state == PARAM_WAIT || state == ROW_WAIT || state == STORE_WAIT;
    wire memory_usable = memory_status[3:0] == 4'hf && (memory_status & 32'h50) == 0;

    function [7:0] quantize;
        input signed [31:0] value;
        input signed [7:0] shift;
        input positive;
        reg signed [63:0] rounded;
        begin
            rounded = value;
            if (shift > 0) rounded = (rounded + (64'sd1 << (shift - 1))) >>> shift;
            if (shift < 0) rounded = rounded <<< -shift;
            if (positive && rounded < 0) rounded = 0;
            quantize = rounded > 127 ? 8'h7f : rounded < -128 ? 8'h80 : rounded[7:0];
        end
    endfunction

    always @* begin
        register_rdata = 0;
        if (register_address >= 8'h08 && register_address <= 8'h2c && register_address[1:0] == 0)
            register_rdata = configuration[(register_address - 8'h08) >> 2];
        if (register_address == 8'h04) register_rdata = {29'd0, fault, done, busy};
        if (register_address == 8'h30) register_rdata = cycles;
    end

    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            busy <= 0;
            done <= 0;
            fault <= 0;
            abort_requested <= 0;
            cycles <= 0;
            memory_read <= 0;
            memory_write <= 0;
            memory_address <= 0;
            memory_wdata <= 0;
            output_x <= 0;
            output_y <= 0;
            output_group <= 0;
            input_channel <= 0;
            kernel_x <= 0;
            kernel_y <= 0;
            cache_row <= 0;
            row_word <= 0;
            load_index <= 0;
            weight_count <= 0;
            weight_span <= 0;
            weight_base <= 0;
            mac_index <= 0;
            copy_lane <= 0;
            invalid_pixel <= 0;
            byte_offset <= 0;
            accumulator_zero <= 0;
            accumulator_one <= 0;
            accumulator_two <= 0;
            accumulator_three <= 0;
            for (configuration_index = 0; configuration_index < 10; configuration_index = configuration_index + 1) configuration[configuration_index] <= 0;
        end else begin
            if (busy) cycles <= cycles + 1'b1;
            if (register_write && register_address == 0 && register_wdata[1] && busy) abort_requested <= 1;
            if (register_write && !busy && register_address >= 8'h08 && register_address <= 8'h2c && register_address[1:0] == 0)
                configuration[(register_address - 8'h08) >> 2] <= register_wdata;
            if (busy && (!memory_usable || abort_requested) && !waiting_memory && state != FINISH) begin
                memory_read <= 0;
                memory_write <= 0;
                fault <= 1;
                state <= FINISH;
            end else case (state)
                IDLE: if (register_write && register_address == 0 && register_wdata[0]) begin
                    busy <= 1;
                    done <= 0;
                    fault <= 0;
                    abort_requested <= 0;
                    cycles <= 0;
                    state <= SETUP;
                end
                SETUP: begin
                    output_x <= 0; output_y <= 0; output_group <= 0; load_index <= 0;
                    weight_span <= kernel * kernel * (opcode == 1 ? input_channels : 16'd1);
                    weight_count <= output_groups * kernel * kernel * (opcode == 1 ? input_channels : 16'd1);
                    if (!memory_usable || opcode < 1 || opcode > 4 || !input_width || !input_height || !output_width || !output_height ||
                        !input_channels || !output_channels || output_channels > 256 || input_channels[1:0] || output_channels[1:0] ||
                        !destination_channels || destination_channels[1:0] || destination_offset[1:0] || destination_offset + output_channels > destination_channels ||
                        source_base[1:0] || destination_base[1:0] || weights_base[1:0] || parameters_base[1:0] ||
                        kernel < 1 || kernel > 5 || stride < 1 || stride > 2 ||
                        row_words * (opcode == 4 ? 1 : kernel) > 8192 ||
                        (opcode <= 2 && output_groups * kernel * kernel * (opcode == 1 ? input_channels : 16'd1) > 8192) ||
                        (opcode == 2 && input_channels != output_channels) ||
                        (opcode == 4 && (!source_step || source_offset + (output_channels - 1) * source_step >= input_channels))) begin
                        fault <= 1; state <= FINISH;
                    end else state <= opcode <= 2 ? WEIGHT_REQUEST : ROW_BEGIN;
                end
                WEIGHT_REQUEST: begin
                    memory_address <= weights_base + {14'd0, load_index, 2'b00};
                    memory_read <= 1; state <= WEIGHT_WAIT;
                end
                WEIGHT_WAIT: if (memory_ready) begin
                    weight_cache[load_index[12:0]] <= memory_rdata;
                    memory_read <= 0;
                    load_index <= load_index + 1'b1;
                    if (load_index + 1 == weight_count) begin load_index <= 0; state <= PARAM_REQUEST; end
                    else state <= WEIGHT_REQUEST;
                end
                PARAM_REQUEST: begin
                    memory_address <= parameters_base + {14'd0, load_index, 2'b00};
                    memory_read <= 1; state <= PARAM_WAIT;
                end
                PARAM_WAIT: if (memory_ready) begin
                    case (load_index[2:0])
                        0: bias_zero[load_index[8:3]] <= memory_rdata;
                        1: bias_one[load_index[8:3]] <= memory_rdata;
                        2: bias_two[load_index[8:3]] <= memory_rdata;
                        3: bias_three[load_index[8:3]] <= memory_rdata;
                        4: shift_zero[load_index[8:3]] <= memory_rdata[7:0];
                        5: shift_one[load_index[8:3]] <= memory_rdata[7:0];
                        6: shift_two[load_index[8:3]] <= memory_rdata[7:0];
                        7: shift_three[load_index[8:3]] <= memory_rdata[7:0];
                    endcase
                    memory_read <= 0;
                    load_index <= load_index + 1'b1;
                    state <= load_index + 1 == output_channels * 2 ? ROW_BEGIN : PARAM_REQUEST;
                end
                ROW_BEGIN: begin cache_row <= 0; row_word <= 0; state <= ROW_REQUEST; end
                ROW_REQUEST: begin
                    if (source_y < 0 || source_y >= $signed({16'd0, input_height})) state <= ROW_PAD;
                    else begin
                        memory_address <= source_base + source_y * row_bytes + {14'd0, row_word, 2'b00};
                        memory_read <= 1; state <= ROW_WAIT;
                    end
                end
                ROW_WAIT: if (memory_ready) begin
                    input_cache[cached_index[12:0]] <= memory_rdata;
                    memory_read <= 0;
                    if (row_word + 1 == row_words) begin
                        row_word <= 0;
                        if (opcode == 4 || cache_row + 1 == kernel) state <= INITIALIZE;
                        else begin cache_row <= cache_row + 1'b1; state <= ROW_REQUEST; end
                    end else begin row_word <= row_word + 1'b1; state <= ROW_REQUEST; end
                end
                ROW_PAD: begin
                    input_cache[cached_index[12:0]] <= opcode == 3 ? 32'h80808080 : 32'd0;
                    if (row_word + 1 == row_words) begin
                        row_word <= 0;
                        if (cache_row + 1 == kernel) state <= INITIALIZE;
                        else begin cache_row <= cache_row + 1'b1; state <= ROW_REQUEST; end
                    end else begin row_word <= row_word + 1'b1; state <= ROW_REQUEST; end
                end
                INITIALIZE: begin
                    accumulator_zero <= opcode == 3 ? -128 : opcode == 4 ? 0 : bias_zero[output_group[5:0]];
                    accumulator_one <= opcode == 3 ? -128 : opcode == 4 ? 0 : bias_one[output_group[5:0]];
                    accumulator_two <= opcode == 3 ? -128 : opcode == 4 ? 0 : bias_two[output_group[5:0]];
                    accumulator_three <= opcode == 3 ? -128 : opcode == 4 ? 0 : bias_three[output_group[5:0]];
                    input_channel <= 0; kernel_x <= 0; kernel_y <= 0; mac_index <= 0; copy_lane <= 0;
                    state <= opcode == 4 ? COPY_FETCH : FETCH;
                end
                FETCH: begin
                    input_read <= input_cache[activation_index[14:2]];
                    byte_offset <= activation_index[1:0];
                    invalid_pixel <= source_x < 0 || source_x >= $signed({16'd0, input_width});
                    weight_read <= weight_cache[(weight_base + mac_index) & 16'h1fff];
                    state <= MAC;
                end
                MAC: begin
                    if (opcode == 3) begin
                        if (input_zero > accumulator_zero) accumulator_zero <= input_zero;
                        if (input_one > accumulator_one) accumulator_one <= input_one;
                        if (input_two > accumulator_two) accumulator_two <= input_two;
                        if (input_three > accumulator_three) accumulator_three <= input_three;
                    end else begin
                        accumulator_zero <= accumulator_zero + product_zero;
                        accumulator_one <= accumulator_one + product_one;
                        accumulator_two <= accumulator_two + product_two;
                        accumulator_three <= accumulator_three + product_three;
                    end
                    mac_index <= mac_index + 1'b1;
                    state <= FETCH;
                    if (opcode == 1 && input_channel + 1 < input_channels) input_channel <= input_channel + 1'b1;
                    else begin
                        input_channel <= 0;
                        if (kernel_x + 1 < kernel) kernel_x <= kernel_x + 1'b1;
                        else begin
                            kernel_x <= 0;
                            if (kernel_y + 1 < kernel) kernel_y <= kernel_y + 1'b1;
                            else state <= EMIT;
                        end
                    end
                end
                COPY_FETCH: begin
                    input_read <= input_cache[copy_index[14:2]];
                    byte_offset <= copy_index[1:0];
                    state <= COPY_VALUE;
                end
                COPY_VALUE: begin
                    case (copy_lane)
                        0: accumulator_zero <= $signed(quantize(selected_byte, copy_shift, 1'b0));
                        1: accumulator_one <= $signed(quantize(selected_byte, copy_shift, 1'b0));
                        2: accumulator_two <= $signed(quantize(selected_byte, copy_shift, 1'b0));
                        3: accumulator_three <= $signed(quantize(selected_byte, copy_shift, 1'b0));
                    endcase
                    copy_lane <= copy_lane + 1'b1;
                    state <= copy_lane == 3 ? EMIT : COPY_FETCH;
                end
                EMIT: begin
                    memory_address <= destination_base + (output_y * output_width + output_x) * destination_channels + destination_offset + output_group * 4;
                    memory_wdata <= {quantize(accumulator_three, opcode <= 2 ? shift_three[output_group[5:0]] : 8'd0, relu),
                                     quantize(accumulator_two, opcode <= 2 ? shift_two[output_group[5:0]] : 8'd0, relu),
                                     quantize(accumulator_one, opcode <= 2 ? shift_one[output_group[5:0]] : 8'd0, relu),
                                     quantize(accumulator_zero, opcode <= 2 ? shift_zero[output_group[5:0]] : 8'd0, relu)};
                    memory_write <= 1; state <= STORE_WAIT;
                end
                STORE_WAIT: if (memory_ready) begin memory_write <= 0; state <= ADVANCE; end
                ADVANCE: begin
                    if (output_group + 1 < output_groups) begin
                        output_group <= output_group + 1'b1; weight_base <= weight_base + weight_span; state <= INITIALIZE;
                    end else begin
                        output_group <= 0; weight_base <= 0;
                        if (output_x + 1 < output_width) begin output_x <= output_x + 1'b1; state <= INITIALIZE; end
                        else begin
                            output_x <= 0;
                            if (output_y + 1 < output_height) begin output_y <= output_y + 1'b1; state <= ROW_BEGIN; end
                            else state <= FINISH;
                        end
                    end
                end
                FINISH: begin busy <= 0; done <= 1; state <= IDLE; end
                default: begin fault <= 1; state <= FINISH; end
            endcase
            if (state == SETUP) weight_base <= 0;
        end
    end
endmodule
