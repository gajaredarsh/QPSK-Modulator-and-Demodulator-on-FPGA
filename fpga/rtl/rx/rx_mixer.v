// rx_mixer.v
// Aditya

// Brings the signal down to baseband:  xi = r * cos,   xq = -(r * sin)
// cos and sin are about 2048 times bigger than the real values, so each product is shifted right by 11
// (with rounding) and then clipped to 12 bits.

// Matches rx_frontend.downconvert_fixed() in python:
//     xi = (r*cos + 1024) >> 11        xq = (-(r*sin) + 1024) >> 11        clip to 12 bit signed
// Ports:
//   in_valid, r, cos_i, sin_i   all three data inputs must be of the same sample, in the same clock
//   xi, xq, out_valid           12 bit signed outputs
// Latency: 2 clocks (stage 1 = the two multipliers, stage 2 = round + shift + clip). Uses 2 DSP slices.
`timescale 1ns/1ps
`include "qpsk_rx_params.vh"

module rx_mixer #(
    parameter XW = `RXC_X_BITS,        // bits of r and of the outputs
    parameter LW = `RXC_LO_BITS,       // bits of cos and sin
    parameter SH = `RXC_MIX_SHIFT      // shift = 11 (divide by 2048)
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
    // product needs XW+LW bits, one extra bit so that -(r*sin) can never overflow
    localparam PW = XW + LW + 1;
    // rounding part = half of 2048 = 1024
    localparam signed [PW-1:0] RND  = 1 <<< (SH-1);
    // biggest and smallest 12 bit numbers (2047 and -2048) for clipping
    localparam signed [PW-1:0] MAXV = (1 <<< (XW-1)) - 1;
    localparam signed [PW-1:0] MINV = -(1 <<< (XW-1));

    // products from stage 1: r*cos and -(r*sin), v1 is the valid flag that goes with them
    reg signed [PW-1:0] pc, ps;
    reg                 v1;

    // stage 1: just multiply (the minus sign for q goes here)
    always @(posedge clk) begin
        pc <= r * cos_i;
        ps <= -(r * sin_i);
        if (rst) v1 <= 1'b0; else v1 <= in_valid;
    end

    // add the rounding part and shift right by 11 (>>> keeps the sign)
    wire signed [PW-1:0] ti = (pc + RND) >>> SH;
    wire signed [PW-1:0] tq = (ps + RND) >>> SH;

    // stage 2: clip to 12 bits (saturate, hardware doesn't wrap around) and send out
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
