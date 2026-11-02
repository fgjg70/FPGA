`timescale 1ns/1ps

module camera_fifo_capture #(
    parameter integer WIDTH = 320,
    parameter integer HEIGHT = 240,
    parameter integer TIMEOUT_CYCLES = 27000000,
    parameter integer WARMUP_FRAMES = 2,
    parameter integer READ_HALF_CYCLES = 3
) (
    input wire clk,
    input wire reset,
    input wire configured,
    input wire freeze,
    input wire frame_ack,
    input wire vsync,
    input wire [7:0] data,
    output reg rclk,
    output reg we,
    output reg oe_n,
    output reg wrst_n,
    output reg rrst_n,
    output reg pixel_write,
    output reg [14:0] pixel_address,
    output reg [15:0] pixel_data,
    output reg frame_done,
    output reg [15:0] frame_count,
    output reg [15:0] timeout_count,
    output reg [15:0] vsync_count,
    output reg [3:0] state
);
    localparam [3:0] WARMUP=0, WAIT_START=1, WRITE_RESET=2, RECORD=3,
        READ_RESET=4, READ_SETUP=5, READ_BYTES=6, WAIT_ACK=7;
    reg [2:0] vsync_sync;
    wire vsync_rise = vsync_sync[1] && !vsync_sync[2];
    wire vsync_fall = !vsync_sync[1] && vsync_sync[2];
    reg [31:0] watchdog;
    reg [7:0] warmup_count;
    localparam integer PHASE_BITS = $clog2(2 * READ_HALF_CYCLES);
    reg [PHASE_BITS-1:0] phase;
    reg [1:0] reset_pulses;
    reg low_byte;
    reg [7:0] high_byte;
    reg [9:0] column;
    reg [8:0] row;
    reg [14:0] store_address;

    always @(posedge clk) begin
        if (reset) begin
            vsync_sync <= 0;
            rclk <= 0;
            we <= 0;
            oe_n <= 1;
            wrst_n <= 1;
            rrst_n <= 1;
            pixel_write <= 0;
            pixel_address <= 0;
            pixel_data <= 0;
            frame_done <= 0;
            frame_count <= 0;
            timeout_count <= 0;
            vsync_count <= 0;
            state <= WARMUP;
            watchdog <= 0;
            warmup_count <= 0;
            phase <= 0;
            reset_pulses <= 0;
            low_byte <= 0;
            high_byte <= 0;
            column <= 0;
            row <= 0;
            store_address <= 0;
        end else begin
            vsync_sync <= {vsync_sync[1:0], vsync};
            pixel_write <= 0;
            frame_done <= 0;
            if (vsync_rise) vsync_count <= vsync_count + 1'b1;
            if (!configured) begin
                state <= WARMUP;
                warmup_count <= 0;
                watchdog <= 0;
                rclk <= 0;
                we <= 0;
                oe_n <= 1;
                wrst_n <= 1;
                rrst_n <= 1;
            end else if (state <= RECORD && !(state == WAIT_START && freeze)
                         && watchdog == TIMEOUT_CYCLES - 1) begin
                timeout_count <= timeout_count + 1'b1;
                watchdog <= 0;
                state <= WAIT_START;
                we <= 0;
                wrst_n <= 1;
            end else begin
                if (state <= RECORD && !(state == WAIT_START && freeze))
                    watchdog <= watchdog + 1'b1;
                else watchdog <= 0;
                case (state)
                    WARMUP: if (vsync_rise) begin
                        watchdog <= 0;
                        if (warmup_count == WARMUP_FRAMES - 1 || WARMUP_FRAMES == 0)
                            state <= WAIT_START;
                        else warmup_count <= warmup_count + 1'b1;
                    end
                    WAIT_START: if (!freeze && vsync_rise) begin
                        wrst_n <= 0;
                        we <= 0;
                        watchdog <= 0;
                        state <= WRITE_RESET;
                    end
                    WRITE_RESET: if (vsync_fall) begin
                        wrst_n <= 1;
                        we <= 1;
                        watchdog <= 0;
                        state <= RECORD;
                    end
                    RECORD: if (vsync_rise) begin
                        we <= 0;
                        rrst_n <= 0;
                        oe_n <= 1;
                        rclk <= 0;
                        phase <= 0;
                        reset_pulses <= 0;
                        state <= READ_RESET;
                    end
                    READ_RESET: begin
                        if (phase == 0) rclk <= 1;
                        if (phase == READ_HALF_CYCLES) rclk <= 0;
                        if (phase == 2 * READ_HALF_CYCLES - 1) begin
                            phase <= 0;
                            if (reset_pulses == 2) begin
                                rrst_n <= 1;
                                oe_n <= 0;
                                state <= READ_SETUP;
                            end else reset_pulses <= reset_pulses + 1'b1;
                        end else phase <= phase + 1'b1;
                    end
                    READ_SETUP: begin
                        column <= 0;
                        row <= 0;
                        low_byte <= 0;
                        store_address <= 0;
                        phase <= 0;
                        state <= READ_BYTES;
                    end
                    READ_BYTES: begin
                        if (phase == 0) rclk <= 1;
                        if (phase == READ_HALF_CYCLES) begin
                            rclk <= 0;
                            if (!low_byte) high_byte <= data;
                            else begin
                                if (!column[0] && !row[0]) begin
                                    pixel_address <= store_address;
                                    pixel_data <= {high_byte, data};
                                    pixel_write <= 1;
                                    store_address <= store_address + 1'b1;
                                end
                                if (column == WIDTH - 1) begin
                                    column <= 0;
                                    row <= row + 1'b1;
                                end else column <= column + 1'b1;
                            end
                            low_byte <= !low_byte;
                        end
                        if (phase == 2 * READ_HALF_CYCLES - 1) begin
                            phase <= 0;
                            if (row == HEIGHT) begin
                                oe_n <= 1;
                                frame_done <= 1;
                                frame_count <= frame_count + 1'b1;
                                state <= WAIT_ACK;
                            end
                        end else phase <= phase + 1'b1;
                    end
                    WAIT_ACK: if (frame_ack) state <= WAIT_START;
                    default: state <= WARMUP;
                endcase
            end
        end
    end
endmodule
