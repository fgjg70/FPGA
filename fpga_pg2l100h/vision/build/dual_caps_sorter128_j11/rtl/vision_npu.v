`timescale 1ns/1ps

module vision_npu #(
    parameter MAC_LANES = 128
) (
    input wire clk,
    input wire reset,
    input wire [1:0] model_select,
    input wire input_write,
    input wire [13:0] input_address,
    input wire [7:0] input_data,
    input wire start,
    input wire acknowledge,
    input wire [8:0] result_address,
    output wire signed [31:0] result_data,
    output wire busy,
    output reg done,
    output reg [31:0] cycles
);
    localparam IDLE = 0, PREPARE = 1, LAUNCH = 2, RUN = 3;
    reg [1:0] state;
    reg active_model;
    reg [2:0] layer_index;
    reg [210:0] descriptors [0:11];
    reg [210:0] descriptor;
    reg [63:0] quantization [0:511];
    reg [63:0] quant_read;
    wire engine_done;
    wire [7:0] engine_error;
    wire weight_enable;
    wire [23:0] weight_address;
    wire [127:0] weight_data;
    wire quant_enable;
    wire [12:0] quant_address;
    wire [1:0] source_bank;
    wire source_enable;
    wire [23:0] source_address;
    wire [127:0] source_data;
    wire [1:0] target_bank;
    wire target_enable;
    wire [23:0] target_address;
    wire [127:0] target_data;
    wire [15:0] target_strobes;
    wire raw_valid;
    wire [15:0] raw_x, raw_y, raw_channel;
    wire [511:0] raw_data;
    reg weight_enable_delayed;
    reg [11:0] weight_address_delayed;
    reg weight_half;
    wire [127:0] weight_lanes;
    wire [511:0] result_lanes;
    wire [4:0] result_channel = result_address % 9'd27;
    wire [3:0] result_pixel = result_address / 9'd27;
    reg [3:0] selected_result_lane;
    wire [14:0] input_offset = model_select == 1 ? {input_address[11:0], 3'b0} :
        (input_address / 14'd3) * 15'd8 + (input_address % 14'd3);
    wire load_input = input_write && !busy && !done && model_select < 2 &&
        input_address < (model_select == 1 ? 14'd4096 : 14'd12288);
    assign busy = state != IDLE;
    assign weight_data = weight_half ? {weight_lanes[63:0], weight_lanes[127:64]} : weight_lanes;
    assign result_data = result_lanes[selected_result_lane * 32 +: 32];

    initial begin
        $readmemh("model/npu128_descriptors.hex", descriptors);
        $readmemh("model/npu128_quant.hex", quantization);
    end

    nn_conv_engine #(.OC_LANES(16), .PX_LANES(8), .W_RD_LAT(2)) engine (
        .clk(clk), .rst(reset), .desc(descriptor), .start(state == LAUNCH),
        .busy(), .done(engine_done), .cycles(), .err_code(engine_error),
        .w_re(weight_enable), .w_addr(weight_address), .w_rdata(weight_data),
        .q_re(quant_enable), .q_addr(quant_address), .q_rdata(quant_read),
        .a_sel(source_bank), .a_re(source_enable), .a_addr(source_address), .a_rdata(source_data),
        .b_sel(target_bank), .b_we(target_enable), .b_addr(target_address),
        .b_wdata_128(target_data), .b_wstrb(target_strobes),
        .raw_valid(raw_valid), .raw_x(raw_x), .raw_y(raw_y), .raw_channel(raw_channel), .raw_data(raw_data)
    );

    genvar byte_lane;
    generate for (byte_lane = 0; byte_lane < 16; byte_lane = byte_lane + 1) begin: memory_lanes
        reg [7:0] weights [0:4095];
        reg [7:0] activation_first [0:2047];
        reg [7:0] activation_second [0:511];
        reg [7:0] weight_read;
        reg [7:0] activation_read;
        reg [31:0] results [0:31];
        reg [31:0] result_read;
        wire [11:0] weight_index = {active_model, weight_address_delayed[11:1]} +
            ((byte_lane < 8 && weight_address_delayed[0]) ? 12'd1 : 12'd0);
        wire masked_input = layer_index == 0 && (byte_lane % 8 >= (active_model ? 1 : 3));
        assign weight_lanes[byte_lane * 8 +: 8] = weight_read;
        assign source_data[byte_lane * 8 +: 8] = masked_input ? 8'd0 : activation_read;
        assign result_lanes[byte_lane * 32 +: 32] = result_read;
        if (byte_lane == 0) initial $readmemh("model/npu128_weights_0.hex", weights);
        if (byte_lane == 1) initial $readmemh("model/npu128_weights_1.hex", weights);
        if (byte_lane == 2) initial $readmemh("model/npu128_weights_2.hex", weights);
        if (byte_lane == 3) initial $readmemh("model/npu128_weights_3.hex", weights);
        if (byte_lane == 4) initial $readmemh("model/npu128_weights_4.hex", weights);
        if (byte_lane == 5) initial $readmemh("model/npu128_weights_5.hex", weights);
        if (byte_lane == 6) initial $readmemh("model/npu128_weights_6.hex", weights);
        if (byte_lane == 7) initial $readmemh("model/npu128_weights_7.hex", weights);
        if (byte_lane == 8) initial $readmemh("model/npu128_weights_8.hex", weights);
        if (byte_lane == 9) initial $readmemh("model/npu128_weights_9.hex", weights);
        if (byte_lane == 10) initial $readmemh("model/npu128_weights_10.hex", weights);
        if (byte_lane == 11) initial $readmemh("model/npu128_weights_11.hex", weights);
        if (byte_lane == 12) initial $readmemh("model/npu128_weights_12.hex", weights);
        if (byte_lane == 13) initial $readmemh("model/npu128_weights_13.hex", weights);
        if (byte_lane == 14) initial $readmemh("model/npu128_weights_14.hex", weights);
        if (byte_lane == 15) initial $readmemh("model/npu128_weights_15.hex", weights);
        always @(posedge clk) begin
            if (weight_enable_delayed) weight_read <= weights[weight_index];
            if (source_enable)
                activation_read <= source_bank == 0 ? activation_first[source_address[14:4]] : activation_second[source_address[12:4]];
            if (!reset && target_enable && target_strobes[byte_lane] && target_bank == 0)
                activation_first[target_address[14:4]] <= target_data[byte_lane * 8 +: 8];
            else if (!reset && load_input && input_offset[3:0] == byte_lane)
                activation_first[input_offset[14:4]] <= input_data;
            if (!reset && target_enable && target_strobes[byte_lane] && target_bank == 1)
                activation_second[target_address[12:4]] <= target_data[byte_lane * 8 +: 8];
            if (!reset && layer_index == 5 && raw_valid && raw_x < 4 && raw_y < 4 && raw_channel + byte_lane < 27)
                results[{raw_channel[4], raw_y[1:0], raw_x[1:0]}] <= raw_data[byte_lane * 32 +: 32];
            result_read <= results[{result_channel[4], result_pixel}];
        end
    end endgenerate

    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            active_model <= 0;
            layer_index <= 0;
            descriptor <= 0;
            weight_enable_delayed <= 0;
            weight_address_delayed <= 0;
            weight_half <= 0;
            selected_result_lane <= 0;
            done <= 0;
            cycles <= 0;
        end else begin
            weight_enable_delayed <= weight_enable;
            weight_address_delayed <= weight_address[14:3];
            if (weight_enable_delayed) weight_half <= weight_address_delayed[0];
            if (quant_enable) quant_read <= quantization[{active_model, quant_address[7:0]}];
            selected_result_lane <= result_channel[3:0];
            if (busy) cycles <= cycles + 1'b1;
            if (acknowledge && !busy) done <= 0;
            case (state)
                IDLE: if (start && !done && model_select < 2) begin
                    active_model <= model_select[0];
                    layer_index <= 0;
                    cycles <= 0;
                    state <= PREPARE;
                end
                PREPARE: begin
                    descriptor <= descriptors[(active_model ? 4'd6 : 4'd0) + layer_index];
                    state <= LAUNCH;
                end
                LAUNCH: state <= RUN;
                RUN: if (engine_done) begin
                    if (engine_error != 0 || layer_index == 5) begin
                        state <= IDLE;
                        done <= 1;
                    end else begin
                        layer_index <= layer_index + 1'b1;
                        state <= PREPARE;
                    end
                end
                default: state <= IDLE;
            endcase
        end
    end
endmodule
