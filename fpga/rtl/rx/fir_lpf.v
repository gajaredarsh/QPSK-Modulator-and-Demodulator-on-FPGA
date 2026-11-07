// fir_lpf.v  (Part C)
// Author: [FILL IN YOUR NAME] (Part C)  |  AI-assistance: drafted with Claude (Anthropic) for EE2000; cite per course AI-usage policy.
// One rail of the receiver low-pass filter: 25-tap symmetric (linear-phase) FIR, causal, zero history at reset.
//
// Mirrors:  rx_frontend.lpf_fixed(x, h_int, aligned=False)
//     acc = sum_k h[k] * x[n-k]            exact integer arithmetic
//     y   = clip12( (acc + 1024) >> 11 )
// Because h[k] == h[N-1-k] the two samples that share a tap are added first (pre-adder), so only 13 multipliers
// are needed instead of 25 (13 DSP slices per rail, 26 for I and Q).
//
// Ports  :  in_valid, x_in   one sample per in_valid pulse, any spacing from 1 clock up
//           out_valid, y     12 bit signed, out_valid is one pulse per input pulse
// Latency:  5 clocks from the edge that samples in_valid to the cycle where out_valid is high (measured by the testbench).
//           The FILTER delay is 12 SAMPLES (group delay): symbol 0's energy peaks at output sample 12.
// Coefficients: loaded from COEF_FILE (fir_coeffs.hex written by gen_rx_vectors.py, 25 words, two's complement).
//               Only the first (N+1)/2 words are used; gen_rx_vectors.py asserts the file is symmetric.
// The pipeline registers are free-running; only the delay line moves on in_valid, and a valid bit travels with
// the data, so the output does not depend on how the input pulses are spaced.
`timescale 1ns/1ps
`include "qpsk_rx_params.vh"

module fir_lpf #(
    parameter XW        = `RXC_X_BITS,
    parameter CW        = `RXC_COEF_BITS,
    parameter N         = `RXC_TAPS,
    parameter SH        = `RXC_FIR_SHIFT,
    parameter COEF_FILE = "fir_coeffs.hex"
)(
    input  wire                 clk,
    input  wire                 rst,
    input  wire                 in_valid,
    input  wire signed [XW-1:0] x_in,
    output reg                  out_valid,
    output reg  signed [XW-1:0] y
);
    localparam H  = (N - 1) / 2;                 // 12: tap pairs (k, N-1-k) for k < H, plus the centre tap
    localparam NP = H + 1;                       // 13 multipliers
    localparam PW = XW + 1 + CW;                 // 25 bit product
    localparam GS = 4;                           // products added per stage-3 adder
    localparam NG = (NP + GS - 1) / GS;          // 4 partial sums
    localparam AW = PW + $clog2(NP);             // 29 bit accumulator: exact, cannot overflow
    localparam signed [AW-1:0] RND  = 1 <<< (SH-1);
    localparam signed [AW-1:0] MAXV = (1 <<< (XW-1)) - 1;
    localparam signed [AW-1:0] MINV = -(1 <<< (XW-1));

    reg signed [CW-1:0] coef [0:N-1];
    initial $readmemh(COEF_FILE, coef);

    integer i, k, g, j;

    // stage 0: delay line, newest sample in x[0]
    reg signed [XW-1:0] x [0:N-1];
    reg v0;
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < N; i = i + 1) x[i] <= 0;
            v0 <= 1'b0;
        end else begin
            v0 <= in_valid;
            if (in_valid) begin
                x[0] <= x_in;
                for (i = 1; i < N; i = i + 1) x[i] <= x[i-1];
            end
        end
    end

    // stage 1: pre-adders
    reg signed [XW:0] pa [0:NP-1];
    reg v1;
    always @(posedge clk) begin
        for (k = 0; k < H; k = k + 1) pa[k] <= x[k] + x[N-1-k];
        pa[H] <= x[H];
        if (rst) v1 <= 1'b0; else v1 <= v0;
    end

    // stage 2: multipliers
    reg signed [PW-1:0] pm [0:NP-1];
    reg v2;
    always @(posedge clk) begin
        for (k = 0; k < NP; k = k + 1) pm[k] <= pa[k] * coef[k];
        if (rst) v2 <= 1'b0; else v2 <= v1;
    end

    // stage 3: partial sums of up to GS products
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

    // stage 4: final sum + rounding constant
    reg signed [AW-1:0] acc, tmp2;
    reg v4;
    always @(posedge clk) begin
        tmp2 = RND;
        for (g = 0; g < NG; g = g + 1) tmp2 = tmp2 + part[g];
        acc <= tmp2;
        if (rst) v4 <= 1'b0; else v4 <= v3;
    end

    // stage 5: shift and clip
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
