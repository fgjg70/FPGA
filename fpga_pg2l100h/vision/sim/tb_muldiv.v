`timescale 1ns/1ps

module tb_muldiv;
    reg clk = 0;
    always #4 clk = !clk;
    reg reset = 1;
    reg [4:0] operation = 0;
    reg [31:0] left_operand = 0;
    reg [31:0] right_operand = 0;
    wire [31:0] result;
    wire busy;
    reg [31:0] random_state = 32'h12550001;
    reg [31:0] edge_values [0:7];
    integer operation_index, left_index, right_index, random_index;
    integer checked = 0;
    muldiv dut (.clk(clk), .rst(reset), .op(operation), .a(left_operand), .b(right_operand), .result(result), .busy(busy));

    task check_operation;
        input [4:0] selected_operation;
        input [31:0] selected_left;
        input [31:0] selected_right;
        reg signed [63:0] extended_left;
        reg signed [63:0] extended_right;
        reg signed [127:0] full_product;
        reg [31:0] expected;
        integer elapsed;
        begin
            extended_left = (selected_operation == 13 || selected_operation == 15 || selected_operation == 17) ? $signed({32'd0, selected_left}) : $signed({{32{selected_left[31]}}, selected_left});
            extended_right = (selected_operation == 12 || selected_operation == 13 || selected_operation == 15 || selected_operation == 17) ? $signed({32'd0, selected_right}) : $signed({{32{selected_right[31]}}, selected_right});
            full_product = extended_left * extended_right;
            if (selected_operation == 10) expected = full_product[31:0];
            else if (selected_operation <= 13) expected = full_product[63:32];
            else if (selected_right == 0) expected = selected_operation >= 16 ? selected_left : 32'hffffffff;
            else if (selected_operation == 14 || selected_operation == 15) expected = extended_left / extended_right;
            else expected = extended_left % extended_right;
            @(negedge clk);
            operation = selected_operation; left_operand = selected_left; right_operand = selected_right;
            elapsed = 0;
            @(negedge clk);
            while (busy && elapsed < 40) begin elapsed = elapsed + 1; @(negedge clk); end
            if (busy || result !== expected) $fatal(1, "Mul/div op=%0d left=%h right=%h expected=%h actual=%h elapsed=%0d", selected_operation, selected_left, selected_right, expected, result, elapsed);
            checked = checked + 1;
            operation = 0;
            repeat (2) @(negedge clk);
        end
    endtask

    initial begin
        edge_values[0] = 0; edge_values[1] = 1; edge_values[2] = 32'hffffffff; edge_values[3] = 32'h80000000;
        edge_values[4] = 32'h7fffffff; edge_values[5] = 32'h0000ffff; edge_values[6] = 32'hffff0000; edge_values[7] = 32'h1234abcd;
        repeat (4) @(negedge clk); reset = 0;
        for (operation_index = 10; operation_index <= 17; operation_index = operation_index + 1)
            for (left_index = 0; left_index < 8; left_index = left_index + 1)
                for (right_index = 0; right_index < 8; right_index = right_index + 1)
                    check_operation(operation_index, edge_values[left_index], edge_values[right_index]);
        for (random_index = 0; random_index < 512; random_index = random_index + 1) begin
            random_state = random_state * 32'd1664525 + 32'd1013904223;
            left_operand = random_state;
            random_state = random_state * 32'd1664525 + 32'd1013904223;
            right_operand = random_state;
            for (operation_index = 10; operation_index <= 13; operation_index = operation_index + 1)
                check_operation(operation_index, left_operand, right_operand);
        end
        $display("PASS muldiv %0d exact RV32M edge/random cases at 125MHz, signed/unsigned high products, mixed signs, divide-by-zero and signed overflow", checked);
        $finish;
    end
endmodule
