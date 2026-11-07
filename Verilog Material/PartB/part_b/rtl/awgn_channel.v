// awgn_channel.v  (Part B)
// The channel block that goes between the TX mixer and the RX mixer on the board.
// It adds noise with the Eb/N0 chosen by the switches.
//
// Mirrors:  channel.awgn_int(s13, ebn0_db=level)
// Ports  :  in_valid, s_tx     TX mixer output, signed 13 bit
//           level [3:0]        Eb/N0 setting, level n gives n dB (0..15 dB)
//           noise_off          1 = no noise, the output is just the TX sample moved to the RX
//                              scale: r_rx = (s_tx + 4) >>> 3
//           out_valid, r_rx    signed 12 bit RX word (256 = amplitude 1.0)
//           wide               16 bit sum before the shift (debug)
// Latency:  6 clocks (same as awgn_core)
//
// level and noise_off must come from a synchroniser / debouncer in top.v. They may change while
// samples are going through: each sample keeps the gain it entered with (see awgn_core).
`timescale 1ns/1ps
`include "qpsk_params.vh"

module awgn_channel (
    input  wire                               clk,
    input  wire                               rst,
    input  wire                               in_valid,
    input  wire signed [`TX_BITS-1:0]         s_tx,
    input  wire        [`NOISE_LEVEL_BITS-1:0] level,
    input  wire                               noise_off,
    output wire                               out_valid,
    output wire signed [`RX_BITS-1:0]         r_rx,
    output wire signed [`SUM_BITS-1:0]        wide
);
    wire [`NOISE_GAIN_BITS-1:0] rom_gain;
    wire [`NOISE_GAIN_BITS-1:0] gain = noise_off ? {`NOISE_GAIN_BITS{1'b0}} : rom_gain;

    noise_gain_rom u_rom (.level(level), .gain(rom_gain));

    awgn_core u_core (
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .s_tx(s_tx), .gain(gain),
        .out_valid(out_valid), .r_rx(r_rx), .wide(wide)
    );
endmodule
