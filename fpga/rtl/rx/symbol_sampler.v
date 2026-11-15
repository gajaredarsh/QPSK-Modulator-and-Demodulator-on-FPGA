// symbol_sampler.v
// Aditya 

// Symbol timing + integrate-and-dump.
// After reset it first skips the filter delay (OFFSET = 12 samples), once. After that it adds up every SPS = 16
// filtered samples into one I value and one Q value (this is the rectangular pulse matched filter) and sends them out.
// Timing is fixed, it only counts samples (y_valid pulses), so no timing recovery loop is needed.

// Matches rx_backend_eval.integrate_dump(yi, yq, timing_offset=OFFSET) in python:
//     i_hat[k] = sum of yi[OFFSET + SPS*k .. OFFSET + SPS*k + SPS-1]     (signed 16 bit, cannot overflow)
// Ports:
//   y_i, y_q, y_valid   filtered samples from fir_lpf (12 bit)
//   i_hat, q_hat        symbol values, 16 bit signed, 2048 = ideal amplitude with no noise
//   sym_valid           one pulse per symbol, i_hat / q_hat stay the same until the next symbol
// Latency: 1 clock after the last sample of the symbol window.
// Decision rule for Part D (same as rx_backend_eval.decide): bit = (value < 0), bits in the order {I, Q}.
// i_hat[k] is for TX symbol k (k-th symbol after reset), so match the reference bits by counting symbols, not clocks.
`timescale 1ns/1ps
`include "qpsk_rx_params.vh"

module symbol_sampler #(
    parameter XW     = `RXC_X_BITS,      // bits of the filter output
    parameter AW     = `RXC_ACC_BITS,    // bits of the symbol sum (16)
    parameter SPS    = `RXC_SPS,         // samples in one symbol (16)
    parameter OFFSET = `RXC_OFFSET       // filter delay to skip (12)
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
    // bits needed for the two counters (the "? :" just avoids a 0 bit counter if the number is 0 or 1)
    localparam PHW = (SPS > 1) ? $clog2(SPS) : 1;
    localparam SKW = (OFFSET > 0) ? $clog2(OFFSET + 1) : 1;

    reg [PHW-1:0]       ph;                      // which sample of the symbol we are at (0 to 15)
    reg [SKW-1:0]       skip_cnt;                // how many delay samples we have skipped so far
    reg                 skipping;                // 1 while we are still skipping the filter delay
    reg signed [AW-1:0] acc_i, acc_q;            // running sums

    // at the first sample of a symbol (ph == 0) the sum starts again from 0, else keep adding to the old sum
    wire signed [AW-1:0] base_i = (ph == 0) ? {AW{1'b0}} : acc_i;
    wire signed [AW-1:0] base_q = (ph == 0) ? {AW{1'b0}} : acc_q;
    // new sum = old sum + this sample
    wire signed [AW-1:0] nxt_i  = base_i + y_i;
    wire signed [AW-1:0] nxt_q  = base_q + y_q;

    always @(posedge clk) begin
        if (rst) begin
            // start by skipping the delay (if OFFSET is 0 there is nothing to skip)
            ph <= 0; skip_cnt <= 0; skipping <= (OFFSET > 0);
            acc_i <= 0; acc_q <= 0; i_hat <= 0; q_hat <= 0; sym_valid <= 1'b0;
        end else begin
            // sym_valid is a one clock pulse, so it goes low by default
            sym_valid <= 1'b0;
            // only do something when a new filtered sample comes
            if (y_valid) begin
                if (skipping) begin
                    // still in the filter delay, just count the sample and throw it away
                    skip_cnt <= skip_cnt + 1'b1;
                    if (skip_cnt == OFFSET - 1) skipping <= 1'b0;
                end else begin
                    // normal work, add the sample to the sum
                    acc_i <= nxt_i;
                    acc_q <= nxt_q;
                    if (ph == SPS - 1) begin
                        // this was the 16th sample, so the symbol is done: send the sum out and go back to 0
                        ph <= 0;
                        i_hat <= nxt_i; q_hat <= nxt_q; sym_valid <= 1'b1;
                    end else
                        ph <= ph + 1'b1;
                end
            end
        end
    end
endmodule
