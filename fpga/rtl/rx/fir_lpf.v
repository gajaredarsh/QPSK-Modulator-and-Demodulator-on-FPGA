// fir_lpf.v  
// Aditya 

// Low pass filter for ONE rail (we use two copies, one for I and one for Q).
// 25 taps, symmetric (linear phase), causal, delay line is zero after reset.
//
// Matches rx_frontend.lpf_fixed(x, h_int, aligned=False) in python:
//     acc = sum_k h[k] * x[n-k]            exact integer maths
//     y   = clip12( (acc + 1024) >> 11 )
// The taps are symmetric (h[k] == h[N-1-k]) so the two samples that share a tap are added first (pre-adder).
// Then we need only 13 multipliers instead of 25 (13 DSP slices per rail, 26 for I and Q).

// Ports:
//   in_valid, x_in    one sample per in_valid pulse, pulses can be 1 clock apart or as far apart as you like
//   out_valid, y      12 bit signed, one out_valid pulse for every input pulse
// Latency: 5 clocks from the edge that samples in_valid to the cycle where out_valid is high (testbench measures it).
//          The filter delay is 12 SAMPLES (group delay), so symbol 0's energy peaks at output sample 12.
// Taps are read from COEF_FILE (fir_coeffs.hex made by gen_rx_vectors.py, 25 words, two's complement).
//          Only the first 13 are used, the python script checks that the file is symmetric.
// The pipeline registers run all the time, only the delay line moves when in_valid is 1, and a valid bit
// travels along with the data, so the output doesn't depend on the gaps between input samples.
`timescale 1ns/1ps
`include "qpsk_rx_params.vh"

module fir_lpf #(
    parameter XW        = `RXC_X_BITS,       // bits of input and output (12)
    parameter CW        = `RXC_COEF_BITS,    // bits of each tap (12)
    parameter N         = `RXC_TAPS,         // number of taps (25)
    parameter SH        = `RXC_FIR_SHIFT,    // shift = 11 (taps are 2048 times bigger)
    parameter COEF_FILE = "fir_coeffs.hex"
)(
    input  wire                 clk,
    input  wire                 rst,
    input  wire                 in_valid,
    input  wire signed [XW-1:0] x_in,
    output reg                  out_valid,
    output reg  signed [XW-1:0] y
);
    localparam H  = (N - 1) / 2;                 // 12 tap pairs (k and N-1-k), plus one centre tap
    localparam NP = H + 1;                       // 13 multipliers
    localparam PW = XW + 1 + CW;                 // product is 25 bits (sum of two samples is 13 bits, times 12 bit tap)
    localparam GS = 4;                           // how many products one adder in stage 3 adds
    localparam NG = (NP + GS - 1) / GS;          // so we get 4 partial sums
    localparam AW = PW + $clog2(NP);             // accumulator is 29 bits, enough that it can never overflow
    // half of 2048 = 1024, added so the shift rounds to nearest
    localparam signed [AW-1:0] RND  = 1 <<< (SH-1);
    // biggest and smallest 12 bit numbers (2047 and -2048) for clipping
    localparam signed [AW-1:0] MAXV = (1 <<< (XW-1)) - 1;
    localparam signed [AW-1:0] MINV = -(1 <<< (XW-1));

    // tap memory, filled from the hex file at start
    reg signed [CW-1:0] coef [0:N-1];
    initial $readmemh(COEF_FILE, coef);

    // loop counters (only used inside for loops, they become wires/wiring in hardware)
    integer i, k, g, j;

    // stage 0: delay line of the last 25 samples, newest one in x[0]
    // v0 is the valid flag, it follows the data through every stage
    reg signed [XW-1:0] x [0:N-1];
    reg v0;
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < N; i = i + 1) x[i] <= 0;
            v0 <= 1'b0;
        end else begin
            v0 <= in_valid;
            // shift only when a new sample comes
            if (in_valid) begin
                x[0] <= x_in;
                for (i = 1; i < N; i = i + 1) x[i] <= x[i-1];
            end
        end
    end

    // stage 1: pre-adders, add the two samples that share a tap. The centre sample has no partner so it goes alone
    reg signed [XW:0] pa [0:NP-1];
    reg v1;
    always @(posedge clk) begin
        for (k = 0; k < H; k = k + 1) pa[k] <= x[k] + x[N-1-k];
        pa[H] <= x[H];
        if (rst) v1 <= 1'b0; else v1 <= v0;
    end

    // stage 2: multipliers, each sum times its tap
    reg signed [PW-1:0] pm [0:NP-1];
    reg v2;
    always @(posedge clk) begin
        for (k = 0; k < NP; k = k + 1) pm[k] <= pa[k] * coef[k];
        if (rst) v2 <= 1'b0; else v2 <= v1;
    end

    // stage 3: add the products in groups of 4 (13 products so the last group has only 1)
    // tmp is a blocking variable, just a helper for the sum inside the loop
    reg signed [AW-1:0] part [0:NG-1];
    reg signed [AW-1:0] tmp;
    reg v3;
    always @(posedge clk) begin
        for (g = 0; g < NG; g = g + 1) begin
            tmp = 0;
            for (j = 0; j < GS; j = j + 1)
                if (g*GS + j < NP) tmp = tmp + pm[g*GS + j];
            part[g] <= tmp;
        end
        if (rst) v3 <= 1'b0; else v3 <= v2;
    end

    // stage 4: add the 4 partial sums, and the rounding part (1024) too
    reg signed [AW-1:0] acc, tmp2;
    reg v4;
    always @(posedge clk) begin
        tmp2 = RND;
        for (g = 0; g < NG; g = g + 1) tmp2 = tmp2 + part[g];
        acc <= tmp2;
        if (rst) v4 <= 1'b0; else v4 <= v3;
    end

    // stage 5: shift right by 11 (>>> keeps the sign), clip to 12 bits and send out
    wire signed [AW-1:0] ts = acc >>> SH;
    always @(posedge clk) begin
        if (rst) begin
            y <= 0; out_valid <= 1'b0;
        end else begin
            out_valid <= v4;
            y <= (ts > MAXV) ? MAXV[XW-1:0] : (ts < MINV) ? MINV[XW-1:0] : ts[XW-1:0];
        end
    end
endmodule
