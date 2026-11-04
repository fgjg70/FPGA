`timescale 1ns/1ps

module vision_memory_arbiter (
    input wire clk,
    input wire reset,
    input wire cpu_read,
    input wire cpu_write,
    input wire [31:0] cpu_address,
    input wire [31:0] cpu_wdata,
    input wire [3:0] cpu_wstrb,
    output wire cpu_ready,
    input wire npu_read,
    input wire npu_write,
    input wire [31:0] npu_address,
    input wire [31:0] npu_wdata,
    output wire npu_ready,
    output wire memory_read,
    output wire memory_write,
    output wire [31:0] memory_address,
    output wire [31:0] memory_wdata,
    output wire [3:0] memory_wstrb,
    input wire memory_ready
);
    reg [1:0] owner;
    reg turnaround;
    reg previous_npu;
    wire cpu_request = cpu_read || cpu_write;
    wire npu_request = npu_read || npu_write;
    assign cpu_ready = owner == 1 && memory_ready;
    assign npu_ready = owner == 2 && memory_ready;
    assign memory_read = owner == 1 ? cpu_read : owner == 2 ? npu_read : 1'b0;
    assign memory_write = owner == 1 ? cpu_write : owner == 2 ? npu_write : 1'b0;
    assign memory_address = owner == 2 ? npu_address : cpu_address;
    assign memory_wdata = owner == 2 ? npu_wdata : cpu_wdata;
    assign memory_wstrb = owner == 2 ? 4'hf : cpu_wstrb;
    always @(posedge clk) begin
        if (reset) begin owner <= 0; turnaround <= 0; previous_npu <= 0; end
        else if (owner != 0) begin
            if (memory_ready) begin previous_npu <= owner == 2; owner <= 0; turnaround <= 1; end
        end else if (turnaround) turnaround <= 0;
        else if (cpu_request && (!npu_request || previous_npu)) owner <= 1;
        else if (npu_request) owner <= 2;
    end
endmodule
