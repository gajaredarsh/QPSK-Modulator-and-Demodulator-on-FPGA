// rx_nco.v  (Part C)
// Author: [FILL IN YOUR NAME] (Part C)  |  AI-assistance: drafted with Claude (Anthropic) for EE2000; cite per course AI-usage policy.
// Receiver local oscillator. It is Part A's NCO (same ROM files, same phase step, same start phase = 0),
// instantiated a second time and stepped by the receiver's own sample strobe.
//
// Mirrors:  tx_nco.nco_fixed()   (the Python receiver uses the same cos/sin sequence as the transmitter)
// Ports  :  en       one pulse per received sample (= out_valid of awgn_channel)
//           cos_o / sin_o  signed 12 bit, LO value for the sample that was present when en was high.
//                          They change on the clock edge AFTER en is sampled (1 register, same as Part A).
// Why a second NCO and not a wire to the TX one: the channel + mixer pipelines delay the sample by a few
// clocks, so the TX NCO is already ahead. Counting the receiver's own samples keeps LO sample n paired
// with received sample n, whatever the pipeline depth. Both NCOs are reset together, so both start at phase 0.
// Latency: 1 clock.
`timescale 1ns/1ps
`include "qpsk_rx_params.vh"

module rx_nco #(
    parameter ACC      = `RXC_NCO_ACC_BITS,
    parameter LUTB     = `RXC_NCO_LUT_BITS,
    parameter W        = `RXC_LO_BITS,
    parameter INC      = `RXC_NCO_INC,
    parameter COS_FILE = "lut_cos.hex",
    parameter SIN_FILE = "lut_sin.hex"
)(
    input  wire                clk,
    input  wire                rst,
    input  wire                en,
    output wire signed [W-1:0] cos_o,
    output wire signed [W-1:0] sin_o
);
    nco #(.ACC(ACC), .LUTB(LUTB), .W(W), .INC(INC), .COS_FILE(COS_FILE), .SIN_FILE(SIN_FILE))
        u_nco (.clk(clk), .rst(rst), .en(en), .cos_o(cos_o), .sin_o(sin_o));
endmodule
