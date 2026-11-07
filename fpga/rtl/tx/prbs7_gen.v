// PRBS-7 bit source, 2 bits per symbol. Mirrors tx_nco.gen_bits():
//   out_bit = lfsr[0] (read before shifting); fb = lfsr[0]^lfsr[6];
//   lfsr <= {fb, lfsr[6:1]}; seed from params.py.
// One symbol = two consecutive PRBS bits: b0 -> I, b1 -> Q.
// After one shift lfsr[0] becomes old lfsr[1], so b1 = lfsr[1].
// The 2-step update is done in a single cycle.
`include "qpsk_params.vh"
module prbs7_gen (
    input  wire       clk,
    input  wire       rst,
    input  wire       sym_en,     // advance by one symbol (two PRBS bits)
    output wire [1:0] bits        // {b0, b1}
);
    reg  [6:0] lfsr;
    wire fb0 = lfsr[0] ^ lfsr[6];
    wire fb1 = lfsr[1] ^ fb0;           // feedback of the second step
    assign bits = {lfsr[0], lfsr[1]};

    always @(posedge clk)
        if (rst)         lfsr <= `PRBS_SEED;
        else if (sym_en) lfsr <= {fb1, fb0, lfsr[6:2]};
endmodule
