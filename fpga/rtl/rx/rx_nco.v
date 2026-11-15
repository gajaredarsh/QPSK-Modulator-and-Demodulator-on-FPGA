// rx_nco.v  
// Aditya

// Receiver local oscillator (gives cos and sin for the mixer).
// It is just Part A's nco used a second time. Same ROM files, same phase step, same start phase (0).
// Matches tx_nco.nco_fixed() in python (the python receiver uses the same cos/sin as the transmitter).

// Ports:
//   en           one pulse for every received sample (this is out_valid of awgn_channel)
//   cos_o/sin_o  12 bit signed, LO value for the sample that was there when en was high.
//                They change on the clock edge after en (1 register, same as Part A)

// Why a second NCO and not just wire the TX one: the channel and the mixer delay the sample by a few clocks,
// so the TX NCO is already ahead by then. If the RX counts its own samples, LO sample n always lines up with
// received sample n, no matter how deep the pipeline is. Both NCOs get the same reset so both start at phase 0.
// Latency: 1 clock.
`timescale 1ns/1ps
`include "qpsk_rx_params.vh"

module rx_nco #(
    parameter ACC      = `RXC_NCO_ACC_BITS,      // phase accumulator bits
    parameter LUTB     = `RXC_NCO_LUT_BITS,      // bits used to address the sin/cos table
    parameter W        = `RXC_LO_BITS,           // bits of cos and sin
    parameter INC      = `RXC_NCO_INC,           // phase step per sample (8192/65536 = 0.125 cycles)
    parameter COS_FILE = "lut_cos.hex",
    parameter SIN_FILE = "lut_sin.hex"
)(
    input  wire                clk,
    input  wire                rst,
    input  wire                en,
    output wire signed [W-1:0] cos_o,
    output wire signed [W-1:0] sin_o
);
    // nothing new here, just Part A's nco with our settings
    nco #(.ACC(ACC), .LUTB(LUTB), .W(W), .INC(INC), .COS_FILE(COS_FILE), .SIN_FILE(SIN_FILE))
        u_nco (.clk(clk), .rst(rst), .en(en), .cos_o(cos_o), .sin_o(sin_o));
endmodule
