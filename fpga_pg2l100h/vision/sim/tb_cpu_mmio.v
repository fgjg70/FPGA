`timescale 1ns/1ps

module tb_cpu_mmio;
    reg cpu_clk = 0;
    always #4 cpu_clk = !cpu_clk;
    reg peripheral_clk = 0;
    always #10.37 peripheral_clk = !peripheral_clk;
    reg reset = 1;
    wire cpu_write, cpu_read, cpu_ready;
    wire [31:0] cpu_address, cpu_wdata, cpu_rdata;
    wire [3:0] cpu_wstrb;
    wire bus_write, bus_read;
    wire [31:0] bus_address, bus_wdata;
    wire [3:0] bus_wstrb;
    wire cpu_illegal;
    reg [31:0] register_value = 0;
    reg [31:0] writes = 0;
    reg [31:0] reads = 0;
    reg [31:0] checksum = 0;
    reg [31:0] bus_rdata;
    integer lane;
    integer cpu_cycles = 0;

    core #(.EXTERNAL_WAIT(1)) processor (
        .clk(cpu_clk), .rst(reset), .dbg_raddr(5'd0), .dbg_illegal(cpu_illegal),
        .ext_we(cpu_write), .ext_re(cpu_read), .ext_addr(cpu_address),
        .ext_wdata(cpu_wdata), .ext_wstrb(cpu_wstrb), .ext_rdata(cpu_rdata),
        .ext_ready(cpu_ready), .irq_timer(1'b0)
    );
    vision_mmio_bridge bridge (
        .cpu_clk(cpu_clk), .cpu_reset(reset), .cpu_write(cpu_write), .cpu_read(cpu_read),
        .cpu_address(cpu_address), .cpu_wdata(cpu_wdata), .cpu_wstrb(cpu_wstrb),
        .cpu_ready(cpu_ready), .response_data(cpu_rdata), .peripheral_clk(peripheral_clk),
        .peripheral_reset(reset), .peripheral_write(bus_write), .peripheral_read(bus_read),
        .peripheral_address(bus_address), .peripheral_wdata(bus_wdata),
        .peripheral_wstrb(bus_wstrb), .peripheral_rdata(bus_rdata)
    );
    always @* begin
        case (bus_address)
            32'ha1000000: bus_rdata = register_value;
            32'ha1000004: bus_rdata = writes;
            default: bus_rdata = 0;
        endcase
    end
    always @(posedge cpu_clk) begin
        cpu_cycles = cpu_cycles + 1;
        if (!reset && cpu_illegal) $fatal(1, "Illegal CPU instruction during MMIO wait");
        if (cpu_cycles > 200000) $fatal(1, "CPU/MMIO test timed out at PC %h", processor.dbg_pc);
    end
    always @(posedge peripheral_clk) begin
        if (reset) begin register_value <= 0; writes <= 0; reads <= 0; checksum <= 0; end
        else begin
            if (bus_read) reads <= reads + 1;
            if (bus_write && bus_address == 32'ha1000000) begin
                for (lane = 0; lane < 4; lane = lane + 1)
                    if (bus_wstrb[lane]) register_value[8*lane +: 8] <= bus_wdata[8*lane +: 8];
                if (bus_wstrb == 4'hf) writes <= writes + 1;
            end
            if (bus_write && bus_address == 32'ha100000c) checksum <= bus_wdata;
            if (bus_write && bus_address == 32'ha1000010) begin
                if (bus_wdata !== 32'h600dc0de) $fatal(1, "Actual CPU/MMIO program failed: %h", bus_wdata);
                if (writes !== 512 || reads !== 1536) $fatal(1, "Duplicated or lost MMIO side effects: writes=%0d reads=%0d", writes, reads);
                $display("PASS cpu_mmio actual RV32 at 125MHz, unrelated peripheral phase, 512 dependent loads/stores, byte strobes, local memory and exact side effects; checksum=%h", checksum);
                $finish;
            end
        end
    end
    initial begin
        repeat (12) @(negedge peripheral_clk);
        reset = 0;
    end
endmodule
