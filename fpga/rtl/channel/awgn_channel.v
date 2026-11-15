// Connects the transmitter and receiver through the AWGN channel.
// Adds noise according to the Eb/N0 level selected by the switches.
// Supports a noise-off mode when noise is not required.

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

    // Set the gain to zero when noise is disabled.
    wire [`NOISE_GAIN_BITS-1:0] gain = noise_off ? {`NOISE_GAIN_BITS{1'b0}} : rom_gain;

    // Select the gain according to the chosen noise level.
    noise_gain_rom u_rom (.level(level), .gain(rom_gain));

    awgn_core u_core (
        .clk(clk), .rst(rst),
        .in_valid(in_valid), .s_tx(s_tx), .gain(gain),
        .out_valid(out_valid), .r_rx(r_rx), .wide(wide)
    );
endmodule
