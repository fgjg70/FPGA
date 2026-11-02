`timescale 1ns/1ps

module top_io_debug #(
    parameter integer CLOCK_HZ = 50000000,
    parameter integer BAUD = 115200,
    parameter integer DEBOUNCE_CYCLES = 1000000,
    parameter integer HDMI_RESET_CYCLES = 1000000,
    parameter integer HDMI_SETTLE_CYCLES = 1000000,
    parameter integer HDMI_PLL_WAIT_CYCLES = 500000,
    parameter integer HDMI_RETRY_CYCLES = 50000000,
    parameter integer I2C_QUARTER_CYCLES = 125
) (
    input wire sys_clk,
    input wire video_clk,
    input wire sys_rst_n,
    input wire [5:0] keys_n,
    input wire uart_rxd,
    output wire uart_txd,
    output wire [7:0] led,
    inout wire hdmi_scl,
    inout wire hdmi_sda,
    output wire hdmi_reset_n,
    output wire hdmi_pclk,
    output wire hdmi_hsync,
    output wire hdmi_vsync,
    output wire hdmi_de,
    output wire [23:0] hdmi_data
);
    reg [2:0] reset_sync = 0;
    reg [2:0] pixel_reset_sync = 0;
    wire reset = !reset_sync[2];
    wire [5:0] keys;
    wire [5:0] press_pulse;
    reg [5:0] previous_keys;
    reg [31:0] press_count;
    reg [47:0] key_counts;
    reg [31:0] rx_count;
    reg [7:0] last_rx;
    reg [2:0] pattern;
    reg [31:0] heartbeat_count;
    reg heartbeat;
    wire [7:0] rx_data;
    wire rx_valid;
    wire rx_frame_error;
    wire [7:0] tx_data;
    wire tx_start;
    wire tx_busy;
    wire hdmi_ok;
    wire hdmi_failed;
    wire [7:0] hdmi_step;
    wire fifo_overflow;
    wire frame_error;
    wire clear_counts = rx_valid && rx_data == "c";
    wire restart_hdmi = rx_valid && rx_data == "r";
    wire frame_toggle;
    reg [2:0] frame_sync;
    reg [31:0] video_timeout;
    reg video_alive;
    reg [2:0] previous_health;
    reg [133:0] status_bundle;
    reg status_request;
    wire status_ack;
    reg [1:0] ack_sync;
    wire report_event = keys != previous_keys || clear_counts || restart_hdmi ||
        previous_health != {hdmi_ok, hdmi_failed, video_alive};
    integer key_index;

    function [3:0] pressed_total;
        input [5:0] events;
        integer event_index;
        begin
            pressed_total = 0;
            for (event_index = 0; event_index < 6; event_index = event_index + 1)
                pressed_total = pressed_total + {3'b000, events[event_index]};
        end
    endfunction

    assign led = {hdmi_ok, heartbeat, keys};
    assign hdmi_pclk = ~video_clk;

    always @(posedge sys_clk or negedge sys_rst_n) begin
        if (!sys_rst_n) reset_sync <= 0;
        else reset_sync <= {reset_sync[1:0], 1'b1};
    end

    always @(posedge video_clk or posedge reset) begin
        if (reset) pixel_reset_sync <= 0;
        else pixel_reset_sync <= {pixel_reset_sync[1:0], 1'b1};
    end

    debug_keys #(.DEBOUNCE_CYCLES(DEBOUNCE_CYCLES)) key_inputs (
        .clk(sys_clk), .reset(reset), .keys_n(keys_n), .pressed(keys), .press_pulse(press_pulse)
    );

    debug_uart #(.CLOCK_HZ(CLOCK_HZ), .BAUD(BAUD)) serial_port (
        .clk(sys_clk), .reset(reset), .rxd(uart_rxd), .txd(uart_txd),
        .rx_data(rx_data), .rx_valid(rx_valid), .rx_frame_error(rx_frame_error),
        .tx_data(tx_data), .tx_start(tx_start), .tx_busy(tx_busy)
    );

    debug_console console (
        .clk(sys_clk), .reset(reset), .clear_errors(clear_counts), .report_event(report_event),
        .keys(keys), .press_count(press_count), .rx_count(rx_count), .last_rx(last_rx),
        .pattern(pattern), .hdmi_ok(hdmi_ok), .hdmi_failed(hdmi_failed),
        .hdmi_step(hdmi_step), .video_alive(video_alive), .rx_data(rx_data),
        .rx_valid(rx_valid), .rx_frame_error(rx_frame_error), .tx_busy(tx_busy),
        .tx_data(tx_data), .tx_start(tx_start), .fifo_overflow(fifo_overflow), .frame_error(frame_error)
    );

    debug_ms7210 #(
        .RESET_CYCLES(HDMI_RESET_CYCLES), .SETTLE_CYCLES(HDMI_SETTLE_CYCLES),
        .PLL_WAIT_CYCLES(HDMI_PLL_WAIT_CYCLES), .RETRY_CYCLES(HDMI_RETRY_CYCLES),
        .I2C_QUARTER_CYCLES(I2C_QUARTER_CYCLES)
    ) hdmi_controller (
        .clk(sys_clk), .reset(reset), .restart(restart_hdmi), .hdmi_reset_n(hdmi_reset_n),
        .initialized(hdmi_ok), .failed(hdmi_failed), .step_index(hdmi_step),
        .scl(hdmi_scl), .sda(hdmi_sda)
    );

    debug_video display (
        .pixel_clk(video_clk), .reset(!pixel_reset_sync[2]), .status_bundle(status_bundle),
        .status_request(status_request), .status_ack(status_ack), .frame_toggle(frame_toggle),
        .hsync(hdmi_hsync), .vsync(hdmi_vsync), .data_enable(hdmi_de), .rgb(hdmi_data)
    );

    always @(posedge sys_clk) begin
        if (reset) begin
            previous_keys <= 0;
            previous_health <= 0;
            press_count <= 0;
            key_counts <= 0;
            rx_count <= 0;
            last_rx <= 0;
            pattern <= 0;
            heartbeat_count <= 0;
            heartbeat <= 0;
        end else begin
            previous_keys <= keys;
            previous_health <= {hdmi_ok, hdmi_failed, video_alive};
            if (heartbeat_count == CLOCK_HZ / 2 - 1) begin
                heartbeat_count <= 0;
                heartbeat <= !heartbeat;
            end else heartbeat_count <= heartbeat_count + 1'b1;
            if (clear_counts) begin
                press_count <= 0;
                key_counts <= 0;
                rx_count <= 0;
                last_rx <= 0;
            end else begin
                press_count <= press_count + {28'd0, pressed_total(press_pulse)};
                for (key_index = 0; key_index < 6; key_index = key_index + 1)
                    if (press_pulse[key_index])
                        key_counts[key_index*8 +: 8] <= key_counts[key_index*8 +: 8] + 1'b1;
                if (rx_valid) begin rx_count <= rx_count + 1'b1; last_rx <= rx_data; end
            end
            for (key_index = 0; key_index < 6; key_index = key_index + 1)
                if (press_pulse[key_index]) pattern <= key_index;
            if (rx_valid && rx_data >= "0" && rx_data <= "5") pattern <= rx_data - "0";
        end
    end

    always @(posedge sys_clk) begin
        if (reset) begin
            frame_sync <= 0;
            video_timeout <= CLOCK_HZ / 10;
            video_alive <= 0;
            status_bundle <= 0;
            status_request <= 0;
            ack_sync <= 0;
        end else begin
            frame_sync <= {frame_sync[1:0], frame_toggle};
            if (frame_sync[2] != frame_sync[1]) begin
                video_timeout <= 0;
                video_alive <= 1;
            end else if (video_timeout < CLOCK_HZ / 10) begin
                video_timeout <= video_timeout + 1'b1;
            end else video_alive <= 0;
            ack_sync <= {ack_sync[0], status_ack};
            if (ack_sync[1] == status_request) begin
                status_bundle <= {keys, key_counts, press_count, rx_count, last_rx, pattern,
                    hdmi_ok, hdmi_failed, video_alive, fifo_overflow, frame_error};
                status_request <= !status_request;
            end
        end
    end
endmodule
