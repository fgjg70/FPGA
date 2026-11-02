`timescale 1ns/1ps

module vision_soc #(
    parameter integer CLOCK_HZ = 50000000,
    parameter integer LONG_PRESS_CYCLES = CLOCK_HZ
) (
    input wire clk,
    input wire reset,
    input wire cpu_clk,
    input wire cpu_reset,
    input wire [3:0] keys_n,
    input wire uart_rxd,
    output wire uart_txd,
    input wire configured,
    input wire failed,
    input wire frame_valid,
    input wire [15:0] frame_count,
    input wire frame_tick,
    input wire pixel_write,
    input wire [14:0] pixel_address,
    input wire [15:0] pixel_data,
    input wire frame_done,
    output wire frozen,
    output wire show_bars,
    output reg restart,
    output reg overlay_valid,
    output reg [9:0] box_left,
    output reg [8:0] box_top,
    output reg [9:0] box_right,
    output reg [8:0] box_bottom,
    output reg [5:0] label,
    output reg [31:0] panel_status,
    output reg [31:0] pass_count,
    output reg [31:0] reject_count,
    output wire inference_busy,
    output wire cpu_illegal
);
    wire bus_write;
    wire bus_read;
    wire [31:0] bus_address;
    wire [31:0] bus_wdata;
    wire [3:0] bus_wstrb;
    reg [31:0] bus_rdata;
    reg [31:0] counter;
    reg [31:0] counter_high;
    reg [2:0] control;
    wire [5:0] pressed;
    wire [5:0] press_pulse;
    wire [7:0] rx_data;
    wire rx_valid;
    wire rx_error;
    wire tx_busy;
    reg [7:0] rx_latched;
    reg rx_pending;
    reg [15:0] rx_errors;
    reg [8:0] result_address;
    wire signed [31:0] result_data;
    wire inference_done;
    wire [31:0] inference_cycles;
    wire input_write;
    wire [11:0] input_address;
    wire [7:0] input_data;
    wire inference_start;
    reg inference_ack;
    reg [31:0] pending_first;
    reg [31:0] pending_second;
    reg [31:0] pending_label;
    reg commit_pending;
    reg [31:0] pending_status;
    reg [31:0] pending_pass;
    reg [31:0] pending_reject;
    reg next_target_pending;
    reg [31:0] inference_start_cycle;
    reg [31:0] commit_first;
    reg [31:0] commit_second;
    reg [31:0] commit_label;
    reg [31:0] commit_status;
    reg [31:0] commit_pass;
    reg [31:0] commit_reject;
    reg [7:0] sample_memory [0:4095];
    reg [11:0] sample_address;
    reg [7:0] sample_data;
    reg [31:0] benchmark_done;
    reg [31:0] completed_count;
    reg [1:0] application_mode;
    wire model_select = application_mode == 2'd1;
    wire model_ready = application_mode < 2'd2;
    reg mode_toggle_pending;
    reg [31:0] key_hold_cycles;
    reg key_was_pressed;
    reg key_long_handled;
    wire full_write = bus_write && bus_wstrb == 4'hf;
    wire model_write = full_write && bus_address == 32'ha100005c;
    wire accelerator_reset = reset || restart || !configured || model_write || !model_ready;

    assign frozen = control[1];
    assign show_bars = control[2];

    wire cpu_write;
    wire cpu_read;
    wire [31:0] cpu_address;
    wire [31:0] cpu_wdata;
    wire [3:0] cpu_wstrb;
    wire [31:0] cpu_rdata;
    wire cpu_ready;

    vision_mmio_bridge cpu_bus (
        .cpu_clk(cpu_clk), .cpu_reset(cpu_reset), .cpu_write(cpu_write), .cpu_read(cpu_read),
        .cpu_address(cpu_address), .cpu_wdata(cpu_wdata), .cpu_wstrb(cpu_wstrb),
        .cpu_ready(cpu_ready), .response_data(cpu_rdata),
        .peripheral_clk(clk), .peripheral_reset(reset),
        .peripheral_write(bus_write), .peripheral_read(bus_read), .peripheral_address(bus_address),
        .peripheral_wdata(bus_wdata), .peripheral_wstrb(bus_wstrb), .peripheral_rdata(bus_rdata)
    );
    core #(.EXTERNAL_WAIT(1)) processor (
        .clk(cpu_clk), .rst(cpu_reset), .dbg_raddr(5'd0), .dbg_illegal(cpu_illegal),
        .dbg_pc(), .dbg_id_pc(), .dbg_instr(), .dbg_rdata(),
        .dbg_mem_we(), .dbg_mem_addr(), .dbg_mem_wdata(), .dbg_stall(), .dbg_redirect(),
        .ext_we(cpu_write), .ext_re(cpu_read), .ext_addr(cpu_address),
        .ext_wdata(cpu_wdata), .ext_wstrb(cpu_wstrb), .ext_rdata(cpu_rdata), .ext_ready(cpu_ready), .irq_timer(1'b0)
    );

    debug_keys #(.DEBOUNCE_CYCLES(CLOCK_HZ / 50)) keys (.clk(clk), .reset(reset), .keys_n({2'b11, keys_n}), .pressed(pressed), .press_pulse(press_pulse));
    debug_uart #(.CLOCK_HZ(CLOCK_HZ), .BAUD(115200)) uart (
        .clk(clk), .reset(reset), .rxd(uart_rxd), .txd(uart_txd), .rx_data(rx_data),
        .rx_valid(rx_valid), .rx_frame_error(rx_error), .tx_data(bus_wdata[7:0]),
        .tx_start(full_write && bus_address == 32'ha1000080), .tx_busy(tx_busy)
    );

    vision_snapshot snapshot (
        .clk(clk), .reset(accelerator_reset), .model_select(model_select), .enabled(model_ready && control[0] && !show_bars && !frozen),
        .busy(inference_busy), .done(inference_done), .pixel_write(pixel_write),
        .pixel_address(pixel_address), .pixel_data(pixel_data), .frame_done(frame_done),
        .input_write(input_write), .input_address(input_address), .input_data(input_data), .start(inference_start)
    );
    vision_npu accelerator (
        .clk(clk), .reset(accelerator_reset), .model_select(model_select), .input_write(input_write), .input_address(input_address),
        .input_data(input_data), .start(inference_start), .acknowledge(inference_ack),
        .result_address(result_address), .result_data(result_data), .busy(inference_busy),
        .done(inference_done), .cycles(inference_cycles)
    );

    always @* begin
        case (bus_address)
            32'ha1000000: bus_rdata = 32'h56530101;
            32'ha1000004: bus_rdata = {23'd0, !model_ready, show_bars, frozen, control[0], inference_done, inference_busy, frame_valid, failed, configured};
            32'ha1000008: bus_rdata = {16'd0, frame_count};
            32'ha100000c: bus_rdata = inference_cycles;
            32'ha1000010: bus_rdata = {23'd0, result_address};
            32'ha1000014: bus_rdata = result_data;
            32'ha1000018: bus_rdata = {29'd0, control};
            32'ha100001c: bus_rdata = counter;
            32'ha1000030: bus_rdata = completed_count;
            32'ha1000034: bus_rdata = panel_status;
            32'ha1000038: bus_rdata = pass_count;
            32'ha100003c: bus_rdata = reject_count;
            32'ha1000040: bus_rdata = {31'd0, next_target_pending};
            32'ha1000044: bus_rdata = inference_start_cycle;
            32'ha1000048: bus_rdata = counter_high;
            32'ha1000050: bus_rdata = benchmark_done;
            32'ha1000054: bus_rdata = {20'd0, sample_address};
            32'ha1000058: bus_rdata = {24'd0, sample_data};
            32'ha100005c: bus_rdata = {30'd0, application_mode};
            32'ha1000060: bus_rdata = {31'd0, mode_toggle_pending};
            32'ha1000064: bus_rdata = 32'h00000003;
            32'ha1000084: bus_rdata = {31'd0, tx_busy};
            32'ha1000088: bus_rdata = {24'd0, rx_latched};
            32'ha100008c: bus_rdata = {15'd0, rx_errors, rx_pending};
            default: bus_rdata = 0;
        endcase
    end

    always @(posedge clk) begin
        if (input_write) sample_memory[input_address] <= input_data;
        sample_data <= sample_memory[sample_address];
    end

    always @(posedge clk) begin
        if (reset) begin
            counter <= 0;
            counter_high <= 0;
            control <= 3'b001;
            restart <= 0;
            inference_ack <= 0;
            result_address <= 0;
            rx_latched <= 0;
            rx_pending <= 0;
            rx_errors <= 0;
            pending_first <= 0;
            pending_second <= 0;
            pending_label <= 0;
            commit_pending <= 0;
            pending_status <= 32'h00000f01;
            pending_pass <= 0;
            pending_reject <= 0;
            panel_status <= 32'h00000f01;
            pass_count <= 0;
            reject_count <= 0;
            next_target_pending <= 0;
            inference_start_cycle <= 0;
            commit_first <= 0;
            commit_second <= 0;
            commit_label <= 0;
            commit_status <= 32'h00000f01;
            commit_pass <= 0;
            commit_reject <= 0;
            sample_address <= 0;
            benchmark_done <= 0;
            overlay_valid <= 0;
            box_left <= 0;
            box_top <= 0;
            box_right <= 0;
            box_bottom <= 0;
            label <= 0;
            completed_count <= 0;
            application_mode <= 0;
            mode_toggle_pending <= 0;
            key_hold_cycles <= 0;
            key_was_pressed <= 0;
            key_long_handled <= 0;
        end else begin
            counter <= counter + 1'b1;
            if (counter == 32'hffffffff) counter_high <= counter_high + 1'b1;
            restart <= 0;
            inference_ack <= 0;
            if (inference_start) inference_start_cycle <= counter;
            if (bus_read && bus_address == 32'ha1000040) next_target_pending <= 0;
            if (bus_read && bus_address == 32'ha1000060) mode_toggle_pending <= 0;
            if (rx_error || (rx_valid && rx_pending)) rx_errors <= rx_errors + 1'b1;
            if (bus_read && bus_address == 32'ha1000088) rx_pending <= 0;
            if (rx_valid) begin rx_latched <= rx_data; rx_pending <= 1; end
            if (full_write) begin
                case (bus_address)
                    32'ha1000010: result_address <= bus_wdata[8:0];
                    32'ha1000018: begin
                        control <= bus_wdata[2:0];
                        restart <= bus_wdata[3];
                        inference_ack <= bus_wdata[4];
                        if (bus_wdata[4] && inference_done) completed_count <= completed_count + 1'b1;
                    end
                    32'ha1000020: pending_first <= bus_wdata;
                    32'ha1000024: pending_second <= bus_wdata;
                    32'ha1000028: pending_label <= bus_wdata;
                    32'ha100002c: begin
                        commit_first <= pending_first;
                        commit_second <= pending_second;
                        commit_label <= pending_label;
                        commit_status <= pending_status;
                        commit_pass <= pending_pass;
                        commit_reject <= pending_reject;
                        commit_pending <= 1;
                    end
                    32'ha1000034: pending_status <= bus_wdata;
                    32'ha1000038: pending_pass <= bus_wdata;
                    32'ha100003c: pending_reject <= bus_wdata;
                    32'ha1000050: benchmark_done <= bus_wdata;
                    32'ha1000054: sample_address <= bus_wdata[11:0];
                    32'ha100005c: begin
                        application_mode <= bus_wdata[1:0];
                        pending_first <= 0;
                        pending_second <= 0;
                        pending_label <= 0;
                        commit_pending <= 0;
                        overlay_valid <= 0;
                    end
                    default: begin end
                endcase
            end
            if (commit_pending && frame_tick && !model_write) begin
                box_left <= commit_first[9:0];
                box_top <= commit_first[24:16];
                box_right <= commit_second[9:0];
                box_bottom <= commit_second[24:16];
                label <= commit_label[5:0];
                panel_status <= commit_status;
                pass_count <= commit_pass;
                reject_count <= commit_reject;
                overlay_valid <= commit_label[31];
                commit_pending <= full_write && bus_address == 32'ha100002c;
            end
            key_was_pressed <= pressed[0];
            if (pressed[0]) begin
                if (!key_long_handled) begin
                    if (key_hold_cycles == LONG_PRESS_CYCLES - 1) begin
                        mode_toggle_pending <= 1;
                        key_long_handled <= 1;
                    end else key_hold_cycles <= key_hold_cycles + 1'b1;
                end
            end else begin
                if (key_was_pressed && !key_long_handled) next_target_pending <= 1;
                key_hold_cycles <= 0;
                key_long_handled <= 0;
            end
            if (press_pulse[1]) control[2] <= !control[2];
            if (press_pulse[2]) control[1] <= !control[1];
            if (press_pulse[3]) begin restart <= 1; control[1] <= 0; end
            if (!configured || failed || restart || !control[0] || show_bars || model_write) overlay_valid <= 0;
        end
    end
endmodule
