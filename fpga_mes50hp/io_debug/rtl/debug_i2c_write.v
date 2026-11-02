`timescale 1ns/1ps

module debug_i2c_write #(
    parameter integer QUARTER_CYCLES = 125,
    parameter integer TIMEOUT_TICKS = 4000
) (
    input wire clk,
    input wire reset,
    input wire start,
    input wire [15:0] register_address,
    input wire [7:0] register_value,
    output reg busy,
    output reg done,
    output reg failed,
    inout wire scl,
    inout wire sda
);
    localparam [4:0] IDLE = 0, START_IDLE = 1, START_HOLD = 2,
        BIT_LOW = 3, BIT_RISE = 4, BIT_HIGH = 5, BIT_FALL = 6,
        ACK_LOW = 7, ACK_RISE = 8, ACK_HIGH = 9, ACK_FALL = 10,
        STOP_LOW = 11, STOP_RISE = 12, STOP_HIGH = 13, STOP_RELEASE = 14,
        FINISH = 15;
    localparam integer DIVIDER_BITS = QUARTER_CYCLES < 2 ? 1 : $clog2(QUARTER_CYCLES);
    reg [4:0] state;
    reg [DIVIDER_BITS-1:0] divider;
    reg [31:0] shift_data;
    reg [2:0] bit_index;
    reg [1:0] byte_index;
    reg scl_low;
    reg sda_low;
    reg [1:0] scl_sync;
    reg [1:0] sda_sync;
    reg [$clog2(TIMEOUT_TICKS+1)-1:0] wait_ticks;
    wire waiting_high = state == START_IDLE || state == BIT_HIGH ||
        state == ACK_HIGH || state == STOP_HIGH;

    assign scl = scl_low ? 1'b0 : 1'bz;
    assign sda = sda_low ? 1'b0 : 1'bz;

    always @(posedge clk) begin
        if (reset) begin
            state <= IDLE;
            divider <= 0;
            shift_data <= 0;
            bit_index <= 7;
            byte_index <= 0;
            scl_low <= 0;
            sda_low <= 0;
            scl_sync <= 3;
            sda_sync <= 3;
            busy <= 0;
            done <= 0;
            failed <= 0;
            wait_ticks <= 0;
        end else begin
            scl_sync <= {scl_sync[0], scl};
            sda_sync <= {sda_sync[0], sda};
            done <= 0;
            if (state == IDLE) begin
                divider <= 0;
                wait_ticks <= 0;
                if (start) begin
                    shift_data <= {8'hb2, register_address[7:0], register_address[15:8], register_value};
                    bit_index <= 7;
                    byte_index <= 0;
                    busy <= 1;
                    failed <= 0;
                    state <= START_IDLE;
                end
            end else if (divider != QUARTER_CYCLES - 1) begin
                divider <= divider + 1'b1;
            end else begin
                divider <= 0;
                case (state)
                    START_IDLE: if (scl_sync[1] && sda_sync[1]) begin
                        sda_low <= 1;
                        state <= START_HOLD;
                    end
                    START_HOLD: begin scl_low <= 1; state <= BIT_LOW; end
                    BIT_LOW: begin sda_low <= !shift_data[31]; state <= BIT_RISE; end
                    BIT_RISE: begin scl_low <= 0; state <= BIT_HIGH; end
                    BIT_HIGH: if (scl_sync[1]) state <= BIT_FALL;
                    BIT_FALL: begin
                        scl_low <= 1;
                        shift_data <= {shift_data[30:0], 1'b0};
                        if (bit_index == 0) state <= ACK_LOW;
                        else begin bit_index <= bit_index - 1'b1; state <= BIT_LOW; end
                    end
                    ACK_LOW: begin sda_low <= 0; state <= ACK_RISE; end
                    ACK_RISE: begin scl_low <= 0; state <= ACK_HIGH; end
                    ACK_HIGH: if (scl_sync[1]) begin
                        if (sda_sync[1]) failed <= 1;
                        state <= ACK_FALL;
                    end
                    ACK_FALL: begin
                        scl_low <= 1;
                        if (failed || byte_index == 3) state <= STOP_LOW;
                        else begin
                            byte_index <= byte_index + 1'b1;
                            bit_index <= 7;
                            state <= BIT_LOW;
                        end
                    end
                    STOP_LOW: begin sda_low <= 1; state <= STOP_RISE; end
                    STOP_RISE: begin scl_low <= 0; state <= STOP_HIGH; end
                    STOP_HIGH: if (scl_sync[1]) state <= STOP_RELEASE;
                    STOP_RELEASE: begin sda_low <= 0; state <= FINISH; end
                    FINISH: begin busy <= 0; done <= 1; state <= IDLE; end
                    default: state <= FINISH;
                endcase
                if (waiting_high && (!scl_sync[1] || (state == START_IDLE && !sda_sync[1]))) begin
                    if (wait_ticks == TIMEOUT_TICKS - 1) begin
                        failed <= 1;
                        scl_low <= 0;
                        sda_low <= 0;
                        state <= FINISH;
                        wait_ticks <= 0;
                    end else wait_ticks <= wait_ticks + 1'b1;
                end else wait_ticks <= 0;
            end
        end
    end
endmodule
