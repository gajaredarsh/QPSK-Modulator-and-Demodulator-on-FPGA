// Part A transmitter: PRBS-7 -> Gray mapper -> NCO -> I*cos - Q*sin.
// Driven by a sample-rate enable (sample_en), one pulse per Python sample.
//
// Timing (n = sample index, tick n = n-th sample_en):
//   tick 16k      : symbol k loaded into symbol regs (and PRBS advances)
//   tick n        : NCO output for sample n registered
//   tick n+1      : mixer output for sample n registered -> s_stb pulses the
//                   clock after that tick, with s_out = Python s[n].
// Symbol k is held for SPS samples; NCO phase is never re-synchronised
// (SPS*INC is a whole number of carrier cycles, checked by the generator).
`include "qpsk_params.vh"
module tx_top #(
    parameter COS_FILE = "lut_cos.hex",
    parameter SIN_FILE = "lut_sin.hex"
)(
    input  wire                              clk,
    input  wire                              rst,
    input  wire                              sample_en,
    output wire signed [`MIXER_OUT_BITS-1:0] s_out,    // modulated sample
    output reg                               s_stb,    // s_out holds a new sample
    output reg  [1:0]                        tx_bits,  // {b0,b1} of current symbol (for BER)
    output reg                               sym_stb,  // tx_bits holds a new symbol
    input  wire                              pat_en,   // 1: send pat[] repeatedly instead of the PRBS
    input  wire [7:0]                        pat       // 8-bit user pattern = 4 symbols, symbol k = {pat[2k], pat[2k+1]}
);
    localparam CW = (`SPS > 1) ? $clog2(`SPS) : 1;
    reg [CW-1:0] cnt;                                  // sample index within symbol
    wire sym_start = sample_en & (cnt == 0);          // first tick of each symbol

    always @(posedge clk)
        if (rst)            cnt <= 0;
        else if (sample_en) cnt <= (cnt == `SPS-1) ? 0 : cnt + 1'b1;

    wire [1:0] prbs_bits;
    prbs7_gen u_prbs (.clk(clk), .rst(rst), .sym_en(sym_start), .bits(prbs_bits));

    // User-pattern mode: symbol k of the stream uses pattern symbol (k mod 4).
    reg [1:0] pidx;
    always @(posedge clk)
        if (rst)            pidx <= 2'd0;
        else if (sym_start) pidx <= pidx + 1'b1;
    wire [1:0] pat_bits = {pat[{pidx, 1'b0}], pat[{pidx, 1'b1}]};   // {b0, b1}
    wire [1:0] bits = pat_en ? pat_bits : prbs_bits;

    wire i_neg_w, q_neg_w;
    qpsk_mapper u_map (.bits(bits), .i_neg(i_neg_w), .q_neg(q_neg_w));

    reg i_neg_r, q_neg_r;
    always @(posedge clk)
        if (rst) begin
            i_neg_r <= 1'b0; q_neg_r <= 1'b0; tx_bits <= 2'b00; sym_stb <= 1'b0;
        end else begin
            sym_stb <= sym_start;
            if (sym_start) begin
                i_neg_r <= i_neg_w; q_neg_r <= q_neg_w; tx_bits <= bits;
            end
        end

    wire signed [`DATAPATH_BITS-1:0] cos_w, sin_w;
    nco #(.COS_FILE(COS_FILE), .SIN_FILE(SIN_FILE)) u_nco
        (.clk(clk), .rst(rst), .en(sample_en), .cos_o(cos_w), .sin_o(sin_w));

    reg nco_v;                                         // first NCO sample is valid
    always @(posedge clk)
        if (rst)            begin nco_v <= 1'b0; s_stb <= 1'b0; end
        else begin
            s_stb <= sample_en & nco_v;
            if (sample_en) nco_v <= 1'b1;
        end

    tx_mixer u_mix (.clk(clk), .rst(rst), .en(sample_en),
                    .i_neg(i_neg_r), .q_neg(q_neg_r),
                    .cos_i(cos_w), .sin_i(sin_w), .s_out(s_out));
endmodule
