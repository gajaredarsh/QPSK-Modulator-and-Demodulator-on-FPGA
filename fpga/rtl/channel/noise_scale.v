// Scales the generated noise using the selected gain value.
// The multiplication result is rounded and shifted.
// The final output is used by the AWGN channel.

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
    // Extend both values before multiplication.
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
            // Multiply the raw noise by the selected gain.
            prod_valid <= raw_valid;
            if (raw_valid)
                prod <= prod_next;

            // Round the result and shift it to get the final noise value.
            noise_valid <= prod_valid;
            if (prod_valid)
                noise <= (prod + (1 << (`NOISE_GAIN_SHIFT - 1))) >>> `NOISE_GAIN_SHIFT;
        end
    end
endmodule
