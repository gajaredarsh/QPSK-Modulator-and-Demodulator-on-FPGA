`timescale 1ns / 1ps
`include "qpsk_rx_params.vh"

module tb_decision_ber;
    localparam integer W = `RXC_ACC_BITS;
    localparam signed [W-1:0] MIN_IQ = {1'b1, {(W-1){1'b0}}};
    localparam signed [W-1:0] MAX_IQ = {1'b0, {(W-1){1'b1}}};

    reg clk, rst, symbol_en, clear, compare_en;
    reg signed [W-1:0] i_symbol, q_symbol;
    wire [1:0] bits_out;
    wire bits_valid;
    wire [31:0] total_bits, error_bits;

    always #5 clk = ~clk;

    symbol_decision #(.W(W)) decision (
        .clk(clk), .rst(rst), .symbol_en(symbol_en),
        .i_symbol(i_symbol), .q_symbol(q_symbol),
        .bits_out(bits_out), .bits_valid(bits_valid)
    );

    ber_counter #(.START_SYMBOL(0)) counter (
        .clk(clk), .rst(rst), .clear(clear),
        .rx_valid(bits_valid), .compare_en(compare_en),
        .rx_bits(bits_out), .pat_en(1'b0), .pat(8'h00), .total_bits(total_bits),
        .error_bits(error_bits)
    );

    task check_counts;
        input [31:0] expected_total;
        input [31:0] expected_errors;
        begin
            if (total_bits !== expected_total ||
                error_bits !== expected_errors) begin
                $display("FAIL: BER expected total/errors %0d/%0d, got %0d/%0d",
                         expected_total, expected_errors, total_bits, error_bits);
                $finish;
            end
        end
    endtask

    task send_symbol;
        input signed [W-1:0] i_value;
        input signed [W-1:0] q_value;
        input [1:0] expected_bits;
        input [31:0] expected_total;
        input [31:0] expected_errors;
        begin
            @(negedge clk);
            i_symbol = i_value;
            q_symbol = q_value;
            symbol_en = 1'b1;

            @(posedge clk);
            #1;
            if (bits_valid !== 1'b1 || bits_out !== expected_bits) begin
                $display("FAIL: I=%0d Q=%0d expected=%b got=%b valid=%b",
                         i_value, q_value, expected_bits, bits_out, bits_valid);
                $finish;
            end

            @(negedge clk);
            symbol_en = 1'b0;
            @(posedge clk);
            #1;
            if (bits_valid !== 1'b0) begin
                $display("FAIL: bits_valid stayed high during a gap");
                $finish;
            end
            check_counts(expected_total, expected_errors);
        end
    endtask

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        symbol_en = 1'b0;
        clear = 1'b0;
        compare_en = 1'b1;
        i_symbol = 0;
        q_symbol = 0;

        repeat (2) @(posedge clk);
        #1;
        check_counts(0, 0);
        @(negedge clk);
        rst = 1'b0;

        // Seed 7'h7F gives reference pairs 11, 11, 11, 10.
        send_symbol(MIN_IQ, -1, 2'b11, 2, 0);
        send_symbol(0,      -1, 2'b01, 4, 1);
        send_symbol(MAX_IQ,  0, 2'b00, 6, 3);

        repeat (3) @(posedge clk);
        #1;
        check_counts(6, 3);

        @(negedge clk);
        clear = 1'b1;
        @(posedge clk);
        #1;
        check_counts(0, 0);
        @(negedge clk);
        clear = 1'b0;

        send_symbol(-1, MAX_IQ, 2'b10, 2, 0);

        compare_en = 1'b0;
        send_symbol(0, 0, 2'b00, 2, 0);

        $display("PASS: Part D decision and BER");
        $finish;
    end

    initial begin
        #5000;
        $display("FAIL: Decision/BER timeout");
        $finish;
    end
endmodule