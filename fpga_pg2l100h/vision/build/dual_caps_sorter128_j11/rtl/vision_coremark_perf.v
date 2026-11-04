`timescale 1ns/1ps

module vision_coremark_perf (
    input wire clk /* synthesis PAP_MARK_DEBUG="<0/c0/0>" */,
    input wire reset,
    input wire write,
    input wire [11:0] address,
    input wire [31:0] write_data,
    output reg [31:0] read_data,
    input wire [15:0] events,
    input wire [31:0] decode_pc,
    input wire [31:0] decode_instruction,
    output reg [114:0] probe /* synthesis PAP_MARK_DEBUG="<0/t0/0>" */
);
    reg running;
    reg frozen;
    reg [31:0] result;
    reg [4:0] summary_index;
    reg sample_valid;
    reg stop_pending;
    reg [15:0] sampled_increment;
    reg [1:0] sampled_retired;
    reg [1:0] sampled_issued;
    reg [63:0] counters [0:15];
    reg [2:0] carry_one [0:15];
    reg [2:0] carry_two [0:15];
    wire [63:0] next_counters [0:15];
    wire [63:0] summary_value = summary_index == 16 ? {32'h434d5031, result} : counters[summary_index[3:0]];
    wire start = write && address == 12'h004 && write_data == 1 && !running && !stop_pending;
    wire stop = write && address == 12'h004 && write_data == 2 && running;
    wire clear = write && address == 12'h004 && write_data == 4 && !running && !stop_pending;
    wire [1:0] retire_count = {1'b0, events[2]} + {1'b0, events[3]};
    wire [1:0] issue_count = {1'b0, events[0]} + {1'b0, events[1]};
    wire [15:0] increment_mask = {
        events[8] && events[14],
        events[8] && events[13],
        events[11],
        1'b0,
        events[10],
        events[9],
        events[4] && events[8],
        events[4] && !events[8] && events[7],
        events[4] && !events[8] && !events[7] && events[6],
        events[4] && !events[8] && !events[7] && !events[6] && events[5],
        events[4],
        events[2] && events[3],
        events[1],
        events[0],
        1'b0,
        1'b1
    };
    integer counter_index;
    genvar counter_number;
    generate
        for (counter_number = 0; counter_number < 16; counter_number = counter_number + 1) begin : counter_lookahead
            wire [1:0] increment = counter_number == 1 ? sampled_retired :
                                   counter_number == 12 ? sampled_issued :
                                   {1'b0, sampled_increment[counter_number]};
            wire [2:0] carry = increment == 2 ? carry_one[counter_number] | carry_two[counter_number] :
                               increment == 1 ? carry_one[counter_number] : 3'b000;
            assign next_counters[counter_number][15:0] = counters[counter_number][15:0] + increment;
            assign next_counters[counter_number][31:16] = counters[counter_number][31:16] + carry[0];
            assign next_counters[counter_number][47:32] = counters[counter_number][47:32] + carry[1];
            assign next_counters[counter_number][63:48] = counters[counter_number][63:48] + carry[2];
        end
    endgenerate

    always @* begin
        case (address)
            12'h000: read_data = 32'h50455246;
            12'h004: read_data = {30'd0, frozen, running};
            12'h008: read_data = 32'd1;
            12'h00c: read_data = 32'd16;
            12'h010: read_data = result;
            default: begin
                read_data = 0;
                if (address[11:7] == 5'b00010 && address[1:0] == 0)
                    read_data = address[2] ? counters[address[6:3]][63:32] : counters[address[6:3]][31:0];
            end
        endcase
    end

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            running <= 0;
            frozen <= 0;
            result <= 0;
            summary_index <= 0;
            sample_valid <= 0;
            stop_pending <= 0;
            sampled_increment <= 0;
            sampled_retired <= 0;
            sampled_issued <= 0;
            probe <= 0;
            for (counter_index = 0; counter_index < 16; counter_index = counter_index + 1) begin
                counters[counter_index] <= 0;
                carry_one[counter_index] <= 0;
                carry_two[counter_index] <= 0;
            end
        end else begin
            sample_valid <= running;
            sampled_increment <= increment_mask;
            sampled_retired <= retire_count;
            sampled_issued <= issue_count;
            probe <= {stop, start, running, counters[0][31:0], decode_instruction, decode_pc, events};
            if (frozen && !start) begin
                probe <= {3'b000, 27'd0, summary_index, summary_value, 16'hcafe};
                summary_index <= summary_index == 16 ? 0 : summary_index + 1'b1;
            end
            if (write && address == 12'h010 && !running) result <= write_data;
            if (start || clear) begin
                running <= start;
                frozen <= 0;
                result <= 0;
                summary_index <= 0;
                sample_valid <= 0;
                stop_pending <= 0;
                for (counter_index = 0; counter_index < 16; counter_index = counter_index + 1) begin
                    counters[counter_index] <= 0;
                    carry_one[counter_index] <= 0;
                    carry_two[counter_index] <= 0;
                end
            end else begin
                if (sample_valid) begin
                    for (counter_index = 0; counter_index < 16; counter_index = counter_index + 1) begin
                        counters[counter_index] <= next_counters[counter_index];
                        carry_one[counter_index] <= {next_counters[counter_index][47:0] == 48'hffffffffffff,
                            next_counters[counter_index][31:0] == 32'hffffffff,
                            next_counters[counter_index][15:0] == 16'hffff};
                        carry_two[counter_index] <= {next_counters[counter_index][47:0] == 48'hfffffffffffe,
                            next_counters[counter_index][31:0] == 32'hfffffffe,
                            next_counters[counter_index][15:0] == 16'hfffe};
                    end
                end
                if (stop) begin
                    running <= 0;
                    stop_pending <= 1;
                end
                if (stop_pending) begin
                    stop_pending <= 0;
                    frozen <= 1;
                end
            end
        end
    end
endmodule
