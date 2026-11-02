`timescale 1ns/1ps

module debug_ms7210 #(
    parameter integer RESET_CYCLES = 1000000,
    parameter integer SETTLE_CYCLES = 1000000,
    parameter integer PLL_WAIT_CYCLES = 500000,
    parameter integer RETRY_CYCLES = 50000000,
    parameter integer I2C_QUARTER_CYCLES = 125
) (
    input wire clk,
    input wire reset,
    input wire restart,
    output reg hdmi_reset_n,
    output reg initialized,
    output reg failed,
    output reg [7:0] step_index,
    inout wire scl,
    inout wire sda
);
    localparam [2:0] HOLD_RESET = 0, SETTLE = 1, SEND = 2, WAIT_WRITE = 3,
        PLL_WAIT = 4, COMPLETE = 5, RETRY = 6;
    reg [2:0] state;
    reg [31:0] delay_count;
    reg write_start;
    wire write_done;
    wire write_failed;
    wire [23:0] configuration_word = configuration(step_index);

    function [23:0] configuration;
        input [7:0] index;
        begin
            case (index)
                0: configuration = 24'h128104;
                1: configuration = 24'h006081;
                2: configuration = 24'h006054;
                3: configuration = 24'h001604;
                4: configuration = 24'h000901;
                5: configuration = 24'h007920;
                6: configuration = 24'h120004;
                7: configuration = 24'h120100;
                8: configuration = 24'h120200;
                9: configuration = 24'h126200;
                10: configuration = 24'h126300;
                11: configuration = 24'h126500;
                12: configuration = 24'h000709;
                13: configuration = 24'h0008f0;
                14: configuration = 24'h000af0;
                15: configuration = 24'h000611;
                16: configuration = 24'h090020;
                17: configuration = 24'h090147;
                18: configuration = 24'h090409;
                19: configuration = 24'h092307;
                20: configuration = 24'h092444;
                21: configuration = 24'h092544;
                22: configuration = 24'h090f80;
                23: configuration = 24'h091f00;
                24: configuration = 24'h09201a;
                25: configuration = 24'h001820;
                26: configuration = 24'h05c0fe;
                27: configuration = 24'h000b00;
                28: configuration = 24'h050706;
                29: configuration = 24'h058104;
                30: configuration = 24'h058100;
                31: configuration = 24'h090600;
                32: configuration = 24'h092611;
                33: configuration = 24'h092701;
                34: configuration = 24'h092811;
                35: configuration = 24'h092901;
                36: configuration = 24'h092a00;
                37: configuration = 24'h090502;
                38: configuration = 24'h050300;
                39: configuration = 24'h050800;
                40: configuration = 24'h120603;
                41: configuration = 24'h120b34;
                42: configuration = 24'h120c60;
                43: configuration = 24'h120d03;
                44: configuration = 24'h120e71;
                45: configuration = 24'h120f02;
                46: configuration = 24'h121087;
                47: configuration = 24'h121100;
                48: configuration = 24'h121202;
                49: configuration = 24'h121300;
                50: configuration = 24'h121440;
                51: configuration = 24'h121500;
                52: configuration = 24'h121605;
                53: configuration = 24'h121700;
                54: configuration = 24'h121884;
                55: configuration = 24'h121900;
                56: configuration = 24'h121a54;
                57: configuration = 24'h121b03;
                58: configuration = 24'h121c2c;
                59: configuration = 24'h121d00;
                60: configuration = 24'h121e6c;
                61: configuration = 24'h121f02;
                62: configuration = 24'h122065;
                63: configuration = 24'h122101;
                64: configuration = 24'h122285;
                65: configuration = 24'h122302;
                66: configuration = 24'h091001;
                67: configuration = 24'h000b11;
                68: configuration = 24'h050e00;
                69: configuration = 24'h050a82;
                70: configuration = 24'h050902;
                71: configuration = 24'h050b0d;
                72: configuration = 24'h050df4;
                73: configuration = 24'h050d12;
                74: configuration = 24'h050d58;
                75: configuration = 24'h050d00;
                76: configuration = 24'h050d11;
                77: configuration = 24'h050d00;
                78: configuration = 24'h050d00;
                79: configuration = 24'h050d00;
                80: configuration = 24'h050d00;
                81: configuration = 24'h050d00;
                82: configuration = 24'h050d00;
                83: configuration = 24'h050d00;
                84: configuration = 24'h050d00;
                85: configuration = 24'h050d00;
                86: configuration = 24'h050e40;
                87: configuration = 24'h050704;
                88: configuration = 24'h091f07;
                89: configuration = 24'h09201e;
                default: configuration = 0;
            endcase
        end
    endfunction

    debug_i2c_write #(.QUARTER_CYCLES(I2C_QUARTER_CYCLES)) bus_writer (
        .clk(clk), .reset(reset || restart), .start(write_start),
        .register_address(configuration_word[23:8]), .register_value(configuration_word[7:0]),
        .busy(), .done(write_done), .failed(write_failed), .scl(scl), .sda(sda)
    );

    always @(posedge clk) begin
        if (reset || restart) begin
            state <= HOLD_RESET;
            delay_count <= 0;
            write_start <= 0;
            hdmi_reset_n <= 0;
            initialized <= 0;
            failed <= 0;
            step_index <= 0;
        end else begin
            write_start <= 0;
            case (state)
                HOLD_RESET: begin
                    hdmi_reset_n <= 0;
                    if (delay_count == RESET_CYCLES - 1) begin
                        hdmi_reset_n <= 1;
                        delay_count <= 0;
                        state <= SETTLE;
                    end else delay_count <= delay_count + 1'b1;
                end
                SETTLE: begin
                    if (delay_count == SETTLE_CYCLES - 1) begin
                        delay_count <= 0;
                        state <= SEND;
                    end else delay_count <= delay_count + 1'b1;
                end
                SEND: begin write_start <= 1; state <= WAIT_WRITE; end
                WAIT_WRITE: if (write_done) begin
                    if (write_failed) begin
                        initialized <= 0;
                        failed <= 1;
                        delay_count <= 0;
                        state <= RETRY;
                    end else if (step_index == 89) begin
                        initialized <= 1;
                        failed <= 0;
                        state <= COMPLETE;
                    end else begin
                        step_index <= step_index + 1'b1;
                        if (step_index == 65 || step_index == 66) state <= PLL_WAIT;
                        else state <= SEND;
                    end
                end
                PLL_WAIT: begin
                    if (delay_count == PLL_WAIT_CYCLES - 1) begin
                        delay_count <= 0;
                        state <= SEND;
                    end else delay_count <= delay_count + 1'b1;
                end
                RETRY: begin
                    if (delay_count == RETRY_CYCLES - 1) begin
                        delay_count <= 0;
                        step_index <= 0;
                        state <= HOLD_RESET;
                    end else delay_count <= delay_count + 1'b1;
                end
                COMPLETE: begin end
                default: state <= HOLD_RESET;
            endcase
        end
    end
endmodule
