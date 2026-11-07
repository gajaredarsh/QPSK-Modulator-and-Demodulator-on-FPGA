`include "qpsk_rx_params.vh"

// Mirrors rx_backend_eval.decide().
// Inputs: signed W-bit accumulated I/Q; symbol_en marks a valid pair.
// Outputs: {I_bit, Q_bit}, valid for one clock.
// Latency: one register stage; synchronous active-high reset.
module symbol_decision #(
    parameter integer W = `RXC_ACC_BITS
)(
    input  wire                clk,
    input  wire                rst,
    input  wire                symbol_en,
    input  wire signed [W-1:0] i_symbol,
    input  wire signed [W-1:0] q_symbol,
    output reg  [1:0]          bits_out,
    output reg                 bits_valid
);

    always @(posedge clk) begin
        if (rst) begin
            bits_out   <= 2'b00;
            bits_valid <= 1'b0;
        end else begin
            bits_valid <= symbol_en;

            if (symbol_en)
                bits_out <= {i_symbol[W-1], q_symbol[W-1]};
        end
    end

endmodule
