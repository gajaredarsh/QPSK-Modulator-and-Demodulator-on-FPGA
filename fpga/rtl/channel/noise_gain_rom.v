// Stores the gain values for different Eb/N0 levels.
// The selected level determines the amount of noise added.
// The gain values are taken from the Python reference model.

`timescale 1ns/1ps
`include "qpsk_params.vh"

module noise_gain_rom (
    input  wire [`NOISE_LEVEL_BITS-1:0] level,
    output reg  [`NOISE_GAIN_BITS-1:0]  gain
);
    // Select the gain value for the chosen noise level.
    always @(*) begin
        case (level)
            4'd0 : gain = 13'd5790;   // 0 dB
            4'd1 : gain = 13'd5160;   // 1 dB
            4'd2 : gain = 13'd4599;   // 2 dB
            4'd3 : gain = 13'd4099;   // 3 dB
            4'd4 : gain = 13'd3653;   // 4 dB
            4'd5 : gain = 13'd3256;   // 5 dB
            4'd6 : gain = 13'd2902;   // 6 dB
            4'd7 : gain = 13'd2586;   // 7 dB
            4'd8 : gain = 13'd2305;   // 8 dB
            4'd9 : gain = 13'd2054;   // 9 dB
            4'd10: gain = 13'd1831;   // 10 dB
            4'd11: gain = 13'd1632;   // 11 dB
            4'd12: gain = 13'd1454;   // 12 dB
            4'd13: gain = 13'd1296;   // 13 dB
            4'd14: gain = 13'd1155;   // 14 dB
            4'd15: gain = 13'd1030;   // 15 dB
            default: gain = 13'd1030;
        endcase
    end
endmodule
