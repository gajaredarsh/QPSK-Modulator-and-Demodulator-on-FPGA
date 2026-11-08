`include "qpsk_params.vh"

// Mirrors tx_nco.gen_bits() and rx_backend_eval.count_errors().
// rx_bits: {I_bit, Q_bit}; consume only when rx_valid is high.
// Counters: unsigned 32-bit, modulo 2^32.
// Latency: counters update on the edge accepting rx_valid.
// START_SYMBOL is a symbol index offset, NOT a clock-cycle delay.
module ber_counter #(
    parameter integer L = `PRBS_LEN,
    parameter [L-1:0] SEED = `PRBS_SEED,
    parameter integer TAP_A = `TAP_A,
    parameter integer TAP_B = `TAP_B,
    parameter integer START_SYMBOL = 0
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        clear,
    input  wire        rx_valid,
    input  wire        compare_en,
    input  wire [1:0]  rx_bits,
    input  wire        pat_en,      // 1: expected bits come from pat[] (same pattern as tx_top)
    input  wire [7:0]  pat,

    output reg  [31:0] total_bits,
    output reg  [31:0] error_bits
);

    function [L-1:0] step;
        input [L-1:0] s;
        begin
            step = {s[TAP_A] ^ s[TAP_B], s[L-1:1]};
        end
    endfunction

    function [L-1:0] initial_state;
        input [L-1:0] seed;
        integer k;
        reg [L-1:0] s;
        begin
            s = seed;
            for (k = 0; k < 2 * START_SYMBOL; k = k + 1)
                s = step(s);
            initial_state = s;
        end
    endfunction

    localparam [L-1:0] RESET_STATE = initial_state(SEED);

    reg  [L-1:0] state;
    wire [L-1:0] after_one = step(state);
    wire [L-1:0] after_two = step(after_one);

    reg [1:0] pidx;
    always @(posedge clk)
        if (rst)           pidx <= 2'd0;
        else if (rx_valid) pidx <= pidx + 1'b1;
    wire [1:0] pat_bits = {pat[{pidx, 1'b0}], pat[{pidx, 1'b1}]};
    wire [1:0] expected_bits = pat_en ? pat_bits : {state[0], after_one[0]};
    wire [1:0] mismatch = rx_bits ^ expected_bits;

    // Explicitly widen before adding: two errors must produce 2.
    wire [1:0] errors_this_symbol =
        {1'b0, mismatch[1]} + {1'b0, mismatch[0]};

    always @(posedge clk) begin
        if (rst) begin
            state      <= RESET_STATE;
            total_bits <= 32'd0;
            error_bits <= 32'd0;
        end else begin
            if (rx_valid)
                state <= after_two;

            if (clear) begin
                total_bits <= 32'd0;
                error_bits <= 32'd0;
            end else if (rx_valid && compare_en) begin
                total_bits <= total_bits + 32'd2;
                error_bits <= error_bits + errors_this_symbol;
            end
        end
    end

endmodule