// noise_scale.v  (Part B)
// Scales the raw noise with the gain. The gain sets the Eb/N0 (bigger gain = more noise).
//   noise = (raw * gain + 128) >>> 8      (the +128 makes the shift round to nearest)
//
// Mirrors:  channel.noise_int(n, gain)
// Ports  :  raw_valid, raw (signed 11 bit), gain (unsigned 13 bit, 0 = no noise)
//           noise (signed 16 bit), noise_valid
// Latency:  2 clocks
//
// The gain must not change while samples are going through (take it from a ROM or a
// synchronised switch). Worst case |raw * gain| = 765 * 8191, which fits in 24 bits signed.
`timescale 1ns/1ps
`include "qpsk_params.vh"

module noise_scale (
    input  wire                               clk,
    input  wire                               rst,
    input  wire                               raw_valid,
    input  wire signed [`NOISE_RAW_BITS-1:0]  raw,
    input  wire        [`NOISE_GAIN_BITS-1:0] gain,
    output reg  signed [`NOISE_BITS-1:0]      noise,
    output reg                                noise_valid
);
    // Both operands are extended to the full product width first: raw is sign-extended and the
    // unsigned gain is zero-extended. The product is then taken at double width and only the
    // low NOISE_PROD_BITS bits are kept (the worst case 765 * 8191 fits, see the note above).
    localparam PROD_FULL = 2 * `NOISE_PROD_BITS;

    wire signed [`NOISE_PROD_BITS-1:0] raw_ext =
        {{(`NOISE_PROD_BITS-`NOISE_RAW_BITS){raw[`NOISE_RAW_BITS-1]}}, raw};
    wire signed [`NOISE_PROD_BITS-1:0] gain_ext =
        {{(`NOISE_PROD_BITS-`NOISE_GAIN_BITS){1'b0}}, gain};
    wire signed [PROD_FULL-1:0]        prod_full = raw_ext * gain_ext;
    wire signed [`NOISE_PROD_BITS-1:0] prod_next = prod_full[`NOISE_PROD_BITS-1:0];

    reg signed [`NOISE_PROD_BITS-1:0] prod;
    reg                               prod_valid;

    always @(posedge clk) begin
        if (rst) begin
            prod        <= 0;
            prod_valid  <= 1'b0;
            noise       <= 0;
            noise_valid <= 1'b0;
        end else begin
            // stage 1: multiply
            prod_valid <= raw_valid;
            if (raw_valid)
                prod <= prod_next;
            // stage 2: add half an LSB and shift right (arithmetic shift keeps the sign)
            noise_valid <= prod_valid;
            if (prod_valid)
                noise <= (prod + (1 << (`NOISE_GAIN_SHIFT - 1))) >>> `NOISE_GAIN_SHIFT;
        end
    end
endmodule
