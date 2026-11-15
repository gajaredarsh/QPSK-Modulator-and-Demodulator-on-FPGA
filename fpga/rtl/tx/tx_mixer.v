// TX mixer, LOCKED convention (params.py): s = I*cos - Q*sin, I,Q in {+1,-1}.
// Because I,Q are +1/-1 this is a sign-select, no multipliers / DSP slices.
// MIXER_OUT_BITS (13) covers the worst case 2047*sqrt(2) ~ 2895, so no overflow.
`include "qpsk_params.vh"
module tx_mixer #(
    parameter W  = `DATAPATH_BITS,      // NCO sample width
    parameter OW = `MIXER_OUT_BITS      // output width (headroom for I*cos - Q*sin)
)(
    input  wire                 clk,
    input  wire                 rst,
    input  wire                 en,       // sample-rate enable
    input  wire                 i_neg,    // 1 -> I = -1
    input  wire                 q_neg,    // 1 -> Q = -1
    input  wire signed [W-1:0]  cos_i,    // carrier cosine
    input  wire signed [W-1:0]  sin_i,    // carrier sine
    output reg  signed [OW-1:0] s_out     // modulated sample
);
    wire signed [OW-1:0] c  = cos_i;               // sign-extended
    wire signed [OW-1:0] sn = sin_i;
    wire signed [OW-1:0] ic = i_neg ? -c  : c;     // I*cos
    wire signed [OW-1:0] qs = q_neg ? -sn : sn;    // Q*sin
    always @(posedge clk)
        if (rst)     s_out <= {OW{1'b0}};
        else if (en) s_out <= ic - qs;             // register I*cos - Q*sin
endmodule
