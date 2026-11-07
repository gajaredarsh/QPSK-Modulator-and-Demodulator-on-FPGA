// rx_mixer.v  (Part C)
// Author: [FILL IN YOUR NAME] (Part C)  |  AI-assistance: drafted with Claude (Anthropic) for EE2000; cite per course AI-usage policy.
// Down-conversion to baseband:   xi = r * cos,   xq = -(r * sin)
// each product is scaled back by 2^(LO_BITS-1) with rounding, then clipped to the RX word width.
//
// Mirrors:  rx_frontend.downconvert_fixed()
//     xi = (r*cos + 1024) >> 11        xq = (-(r*sin) + 1024) >> 11        clip to 12 bit signed
// Ports  :  in_valid, r, cos_i, sin_i   all three data inputs must belong to the same sample, in the same clock
//           xi, xq, out_valid            12 bit signed
// Latency:  2 clocks (stage 1: two multipliers, stage 2: round + shift + clip). Uses 2 DSP slices.
`timescale 1ns/1ps
`include "qpsk_rx_params.vh"

module rx_mixer #(
    parameter XW = `RXC_X_BITS,
    parameter LW = `RXC_LO_BITS,
    parameter SH = `RXC_MIX_SHIFT
)(
    input  wire                clk,
    input  wire                rst,
    input  wire                in_valid,
    input  wire signed [XW-1:0] r,
    input  wire signed [LW-1:0] cos_i,
    input  wire signed [LW-1:0] sin_i,
    output reg  signed [XW-1:0] xi,
    output reg  signed [XW-1:0] xq,
    output reg                 out_valid
);
    localparam PW = XW + LW + 1;                         // product + 1 bit so that -(r*sin) cannot overflow
    localparam signed [PW-1:0] RND  = 1 <<< (SH-1);
    localparam signed [PW-1:0] MAXV = (1 <<< (XW-1)) - 1;
    localparam signed [PW-1:0] MINV = -(1 <<< (XW-1));

    reg signed [PW-1:0] pc, ps;                          // r*cos, -(r*sin)
    reg                 v1;

    always @(posedge clk) begin
        pc <= r * cos_i;
        ps <= -(r * sin_i);
        if (rst) v1 <= 1'b0; else v1 <= in_valid;
    end

    wire signed [PW-1:0] ti = (pc + RND) >>> SH;
    wire signed [PW-1:0] tq = (ps + RND) >>> SH;

    always @(posedge clk) begin
        if (rst) begin
            xi <= 0; xq <= 0; out_valid <= 1'b0;
        end else begin
            out_valid <= v1;
            xi <= (ti > MAXV) ? MAXV[XW-1:0] : (ti < MINV) ? MINV[XW-1:0] : ti[XW-1:0];
            xq <= (tq > MAXV) ? MAXV[XW-1:0] : (tq < MINV) ? MINV[XW-1:0] : tq[XW-1:0];
        end
    end
endmodule
