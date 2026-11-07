// symbol_sampler.v  (Part C)
// Author: [FILL IN YOUR NAME] (Part C)  |  AI-assistance: drafted with Claude (Anthropic) for EE2000; cite per course AI-usage policy.
// Symbol timing + integrate-and-dump. Skips the FIR group delay (OFFSET samples) once after reset, then adds
// every SPS filtered samples into one I value and one Q value (the rectangular-pulse matched filter) and emits
// them.  Timing is fixed: it only counts samples (y_valid pulses), so it needs no recovery loop.
//
// Mirrors:  rx_backend_eval.integrate_dump(yi, yq, timing_offset=OFFSET)       (OFFSET = 12, SPS = 16)
//           i_hat[k] = sum of yi[OFFSET + SPS*k .. OFFSET + SPS*k + SPS-1]     (signed 16 bit, cannot overflow)
// Ports  :  y_i, y_q, y_valid     filtered samples from fir_lpf (12 bit)
//           i_hat, q_hat          symbol values, 16 bit signed, 2048 = "ideal" noiseless amplitude
//           sym_valid             one pulse per symbol; i_hat / q_hat stay stable until the next symbol
// Latency:  1 clock after the last sample of the symbol window.
// Decision rule for Part D (same as rx_backend_eval.decide): bit = (value < 0), bits ordered {I, Q}.
// i_hat[k] belongs to TX symbol k (the k-th symbol after reset), so the BER reference can be matched by symbol
// count, not by clock delay.
`timescale 1ns/1ps
`include "qpsk_rx_params.vh"

module symbol_sampler #(
    parameter XW     = `RXC_X_BITS,
    parameter AW     = `RXC_ACC_BITS,
    parameter SPS    = `RXC_SPS,
    parameter OFFSET = `RXC_OFFSET
)(
    input  wire                 clk,
    input  wire                 rst,
    input  wire                 y_valid,
    input  wire signed [XW-1:0] y_i,
    input  wire signed [XW-1:0] y_q,
    output reg  signed [AW-1:0] i_hat,
    output reg  signed [AW-1:0] q_hat,
    output reg                  sym_valid
);
    localparam PHW = (SPS > 1) ? $clog2(SPS) : 1;
    localparam SKW = (OFFSET > 0) ? $clog2(OFFSET + 1) : 1;

    reg [PHW-1:0]       ph;                      // position inside the current symbol window
    reg [SKW-1:0]       skip_cnt;                // samples of filter delay already skipped
    reg                 skipping;
    reg signed [AW-1:0] acc_i, acc_q;

    wire signed [AW-1:0] base_i = (ph == 0) ? {AW{1'b0}} : acc_i;     // restart the sum at the first sample
    wire signed [AW-1:0] base_q = (ph == 0) ? {AW{1'b0}} : acc_q;
    wire signed [AW-1:0] nxt_i  = base_i + y_i;
    wire signed [AW-1:0] nxt_q  = base_q + y_q;

    always @(posedge clk) begin
        if (rst) begin
            ph <= 0; skip_cnt <= 0; skipping <= (OFFSET > 0);
            acc_i <= 0; acc_q <= 0; i_hat <= 0; q_hat <= 0; sym_valid <= 1'b0;
        end else begin
            sym_valid <= 1'b0;
            if (y_valid) begin
                if (skipping) begin
                    skip_cnt <= skip_cnt + 1'b1;
                    if (skip_cnt == OFFSET - 1) skipping <= 1'b0;
                end else begin
                    acc_i <= nxt_i;
                    acc_q <= nxt_q;
                    if (ph == SPS - 1) begin
                        ph <= 0;
                        i_hat <= nxt_i; q_hat <= nxt_q; sym_valid <= 1'b1;
                    end else
                        ph <= ph + 1'b1;
                end
            end
        end
    end
endmodule
