// Gray-coded QPSK mapper, mirrors tx_nco.map_qpsk():
//   I = 1 - 2*b0, Q = 1 - 2*b1   (bit 0 -> +1, bit 1 -> -1)
// so the "negative" flags are simply the bits themselves.
module qpsk_mapper (
    input  wire [1:0] bits,      // {b0, b1}
    output wire       i_neg,     // 1 -> I = -1
    output wire       q_neg      // 1 -> Q = -1
);
    assign i_neg = bits[1];      // b0
    assign q_neg = bits[0];      // b1
endmodule
