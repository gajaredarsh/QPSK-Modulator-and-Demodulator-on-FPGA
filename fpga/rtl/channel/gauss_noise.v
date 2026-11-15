// Generates approximately Gaussian noise using six LFSRs.
// The six random bytes are added and centred around zero.
// A valid signal indicates when the noise sample is ready.

`timescale 1ns/1ps
`include "qpsk_params.vh"

module gauss_noise (
    input  wire                              clk,
    input  wire                              rst,
    input  wire                              step,
    output reg  signed [`NOISE_RAW_BITS-1:0] raw,
    output reg                               raw_valid
);
    wire [7:0] b0, b1, b2, b3, b4, b5;

    // Each LFSR generates one random byte for every sample.
    lfsr_byte #(.SEED(`NOISE_SEED0)) u0 (.clk(clk), .rst(rst), .step(step), .byte_q(b0));
    lfsr_byte #(.SEED(`NOISE_SEED1)) u1 (.clk(clk), .rst(rst), .step(step), .byte_q(b1));
    lfsr_byte #(.SEED(`NOISE_SEED2)) u2 (.clk(clk), .rst(rst), .step(step), .byte_q(b2));
    lfsr_byte #(.SEED(`NOISE_SEED3)) u3 (.clk(clk), .rst(rst), .step(step), .byte_q(b3));
    lfsr_byte #(.SEED(`NOISE_SEED4)) u4 (.clk(clk), .rst(rst), .step(step), .byte_q(b4));
    lfsr_byte #(.SEED(`NOISE_SEED5)) u5 (.clk(clk), .rst(rst), .step(step), .byte_q(b5));

    // Add the six random bytes together.
    wire [`NOISE_RAW_BITS-1:0] sum = {3'b000, b0} + {3'b000, b1} + {3'b000, b2}
                                   + {3'b000, b3} + {3'b000, b4} + {3'b000, b5};

    // Subtract the mean to centre the noise around zero.
    localparam signed [`NOISE_RAW_BITS:0] MEAN_S = `NOISE_MEAN;
    wire signed [`NOISE_RAW_BITS:0] centered = $signed({1'b0, sum}) - MEAN_S;

    reg step_d;

    always @(posedge clk) begin
        if (rst) begin
            step_d    <= 1'b0;
            raw       <= 0;
            raw_valid <= 1'b0;
        end else begin
            // Match the output valid signal with the generated noise.
            step_d    <= step;
            raw_valid <= step_d;
            if (step_d)
                raw <= centered[`NOISE_RAW_BITS-1:0];
        end
    end
endmodule
