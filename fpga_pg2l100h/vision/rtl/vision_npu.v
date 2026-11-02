`timescale 1ns/1ps

module vision_npu (
    input wire clk,
    input wire reset,
    input wire model_select,
    input wire input_write,
    input wire [11:0] input_address,
    input wire [7:0] input_data,
    input wire start,
    input wire acknowledge,
    input wire [8:0] result_address,
    output reg signed [31:0] result_data,
    output wire busy,
    output reg done,
    output reg [31:0] cycles
);
    localparam IDLE=0, SETUP=1, BIAS_REQUEST=2, BIAS_LOAD=3, REQUEST=4, MAC=5, STORE=6;
    reg [2:0] state;
    reg [2:0] layer_index;
    reg active_model;
    reg [6:0] input_width;
    reg [5:0] input_channels;
    reg [5:0] output_channels;
    reg [5:0] output_width;
    reg [1:0] kernel_size;
    reg [1:0] stride;
    reg [14:0] weight_base;
    reg [7:0] bias_base;
    reg [5:0] output_row;
    reg [5:0] output_column;
    reg [5:0] output_channel;
    reg [5:0] input_channel;
    reg [1:0] kernel_row;
    reg [1:0] kernel_column;
    reg signed [31:0] accumulator;
    reg signed [7:0] activation_read;
    reg signed [7:0] weight_read;
    reg signed [31:0] bias_read;
    reg signed [7:0] weights [0:65535];
    reg signed [31:0] biases [0:511];
    reg [7:0] shifts [0:11];
    reg [7:0] activation_first [0:8191];
    reg [7:0] activation_second [0:8191];
    reg signed [31:0] results [0:511];
    integer source_row;
    integer source_column;
    reg [12:0] activation_index;
    reg [14:0] weight_index;
    reg [12:0] output_index;
    reg padding;
    wire signed [15:0] product = activation_read * weight_read;
    wire [7:0] bias_index = bias_base + output_channel;
    wire [3:0] shift_index = active_model ? 4'd6 + layer_index : {1'b0, layer_index};
    wire signed [31:0] scaled = accumulator >>> shifts[shift_index];
    wire [7:0] activated = scaled < 0 ? 8'd0 : scaled > 127 ? 8'd127 : scaled[7:0];

    initial begin
        $readmemh("model/weights.hex", weights);
        $readmemh("model/biases.hex", biases);
        $readmemh("model/shifts.hex", shifts);
    end

    assign busy = state != IDLE;

    always @* begin
        source_row = output_row * stride + kernel_row - (kernel_size == 3 ? 1 : 0);
        source_column = output_column * stride + kernel_column - (kernel_size == 3 ? 1 : 0);
        padding = source_row < 0 || source_column < 0 || source_row >= input_width || source_column >= input_width;
        activation_index = padding ? 13'd0 : (source_row * input_width + source_column) * input_channels + input_channel;
        weight_index = weight_base + ((output_channel * kernel_size + kernel_row) * kernel_size + kernel_column) * input_channels + input_channel;
        output_index = (output_row * output_width + output_column) * output_channels + output_channel;
    end

    always @(posedge clk) begin
        result_data <= results[result_address];
        if (state == BIAS_REQUEST) bias_read <= biases[{active_model, bias_index}];
        if (state == REQUEST) begin
            weight_read <= weights[{active_model, weight_index}];
            activation_read <= padding ? 8'sd0 : layer_index[0] ? activation_second[activation_index] : activation_first[activation_index];
        end
        if (!reset && state == STORE) begin
            if (layer_index == 5) results[output_index[8:0]] <= scaled;
            else if (!layer_index[0]) activation_second[output_index] <= activated;
        end
        if (!reset && state == STORE && layer_index != 5 && layer_index[0])
            activation_first[output_index] <= activated;
        else if (!reset && input_write && !busy && !done)
            activation_first[{1'b0, input_address}] <= input_data;
    end

    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            layer_index <= 0;
            active_model <= 0;
            input_width <= 64;
            input_channels <= 1;
            output_channels <= 8;
            output_width <= 32;
            kernel_size <= 3;
            stride <= 2;
            weight_base <= 0;
            bias_base <= 0;
            output_row <= 0;
            output_column <= 0;
            output_channel <= 0;
            input_channel <= 0;
            kernel_row <= 0;
            kernel_column <= 0;
            accumulator <= 0;
            done <= 0;
            cycles <= 0;
        end else begin
            if (busy) cycles <= cycles + 1'b1;
            if (acknowledge && !busy) done <= 0;
            case (state)
                IDLE: if (start && !done) begin
                    active_model <= model_select;
                    layer_index <= 0;
                    cycles <= 0;
                    state <= SETUP;
                end
                SETUP: begin
                    case (layer_index)
                        0: begin input_width <= 64; input_channels <= 1; output_channels <= 8; output_width <= 32; kernel_size <= 3; stride <= 2; weight_base <= 0; bias_base <= 0; end
                        1: begin input_width <= 32; input_channels <= 8; output_channels <= 16; output_width <= 16; kernel_size <= 3; stride <= 2; weight_base <= 72; bias_base <= 8; end
                        2: begin input_width <= 16; input_channels <= 16; output_channels <= 24; output_width <= 8; kernel_size <= 3; stride <= 2; weight_base <= 1224; bias_base <= 24; end
                        3: begin input_width <= 8; input_channels <= 24; output_channels <= 32; output_width <= 4; kernel_size <= 3; stride <= 2; weight_base <= 4680; bias_base <= 48; end
                        4: begin input_width <= 4; input_channels <= 32; output_channels <= 32; output_width <= 4; kernel_size <= 3; stride <= 1; weight_base <= 11592; bias_base <= 80; end
                        5: begin input_width <= 4; input_channels <= 32; output_channels <= 27; output_width <= 4; kernel_size <= 1; stride <= 1; weight_base <= 20808; bias_base <= 112; end
                        default: state <= IDLE;
                    endcase
                    output_row <= 0;
                    output_column <= 0;
                    output_channel <= 0;
                    state <= BIAS_REQUEST;
                end
                BIAS_REQUEST: state <= BIAS_LOAD;
                BIAS_LOAD: begin
                    accumulator <= bias_read;
                    input_channel <= 0;
                    kernel_row <= 0;
                    kernel_column <= 0;
                    state <= REQUEST;
                end
                REQUEST: state <= MAC;
                MAC: begin
                    accumulator <= accumulator + product;
                    state <= REQUEST;
                    if (input_channel + 1 < input_channels) input_channel <= input_channel + 1'b1;
                    else begin
                        input_channel <= 0;
                        if (kernel_column + 1 < kernel_size) kernel_column <= kernel_column + 1'b1;
                        else begin
                            kernel_column <= 0;
                            if (kernel_row + 1 < kernel_size) kernel_row <= kernel_row + 1'b1;
                            else state <= STORE;
                        end
                    end
                end
                STORE: begin
                    state <= BIAS_REQUEST;
                    if (output_channel + 1 < output_channels) output_channel <= output_channel + 1'b1;
                    else begin
                        output_channel <= 0;
                        if (output_column + 1 < output_width) output_column <= output_column + 1'b1;
                        else begin
                            output_column <= 0;
                            if (output_row + 1 < output_width) output_row <= output_row + 1'b1;
                            else if (layer_index == 5) begin
                                done <= 1;
                                state <= IDLE;
                            end else begin
                                layer_index <= layer_index + 1'b1;
                                state <= SETUP;
                            end
                        end
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
