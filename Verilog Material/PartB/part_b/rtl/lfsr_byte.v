// lfsr_byte.v  (Part B)
// One 16 bit LFSR that gives one new random byte every time `step` is high.
//
// Mirrors:  channel.lfsr_byte_stream(n, seed)
// Ports  :  clk, rst (synchronous, active high), step (advance one sample)
//           byte_q [7:0]  the byte for the sample that was stepped, valid the cycle AFTER step
// Latency:  1 clock
//
// Per LFSR step (same as the Python model):  fb = s[0]^s[2]^s[3]^s[5];  next = {fb, s[15:1]}
// The output bit is bit 0 of the NEW state. A byte is 8 steps, and the first bit is the MSB.
// All 8 steps are done in one clock by the function below, so the state moves 8 steps per sample.
`timescale 1ns/1ps

module lfsr_byte #(
    parameter [15:0] SEED = 16'h0001          // must not be 0
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       step,
    output reg  [7:0] byte_q
);
    reg [15:0] state;

    // returns {state after 8 steps, the 8 output bits}
    function [23:0] adv8;
        input [15:0] s_in;
        reg   [15:0] s;
        reg   [7:0]  b;
        reg          fb;
        integer      i;
        begin
            s = s_in;
            b = 8'd0;
            for (i = 0; i < 8; i = i + 1) begin
                fb = s[0] ^ s[2] ^ s[3] ^ s[5];
                s  = {fb, s[15:1]};
                b  = {b[6:0], s[0]};
            end
            adv8 = {s, b};
        end
    endfunction

    wire [23:0] nxt = adv8(state);

    always @(posedge clk) begin
        if (rst) begin
            state  <= SEED;
            byte_q <= 8'd0;
        end else if (step) begin
            state  <= nxt[23:8];
            byte_q <= nxt[7:0];
        end
    end
endmodule
