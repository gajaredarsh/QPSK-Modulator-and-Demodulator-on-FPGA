// gauss_noise.v  (Part B)
// Integer "Gaussian" noise before the gain: sum of six random bytes minus 765.
// The result is centred on 0 and goes from -765 to +765.
//
// Mirrors:  channel.lfsr_noise_raw(n)
// Ports  :  step       one pulse per sample (this is the sample enable)
//           raw        signed 11 bit noise, valid when raw_valid is high
// Latency:  2 clocks from step to raw / raw_valid
//
// The six LFSRs start from the fixed seeds in qpsk_params.vh. The noise sequence is the same
// after every reset and repeats every 65535 samples.
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

    lfsr_byte #(.SEED(`NOISE_SEED0)) u0 (.clk(clk), .rst(rst), .step(step), .byte_q(b0));
    lfsr_byte #(.SEED(`NOISE_SEED1)) u1 (.clk(clk), .rst(rst), .step(step), .byte_q(b1));
    lfsr_byte #(.SEED(`NOISE_SEED2)) u2 (.clk(clk), .rst(rst), .step(step), .byte_q(b2));
    lfsr_byte #(.SEED(`NOISE_SEED3)) u3 (.clk(clk), .rst(rst), .step(step), .byte_q(b3));
    lfsr_byte #(.SEED(`NOISE_SEED4)) u4 (.clk(clk), .rst(rst), .step(step), .byte_q(b4));
    lfsr_byte #(.SEED(`NOISE_SEED5)) u5 (.clk(clk), .rst(rst), .step(step), .byte_q(b5));

    // six bytes add up to at most 6 * 255 = 1530, which fits in 11 bits.
    // Every byte is zero-extended to 11 bits explicitly, so the width never depends on the simulator.
    wire [`NOISE_RAW_BITS-1:0] sum = {3'b000, b0} + {3'b000, b1} + {3'b000, b2}
                                   + {3'b000, b3} + {3'b000, b4} + {3'b000, b5};

    // sum is 0..1530; one extra 0 bit makes it signed, then the exact mean (765) is subtracted
    localparam signed [`NOISE_RAW_BITS:0] MEAN_S = `NOISE_MEAN;
    wire signed [`NOISE_RAW_BITS:0] centered = $signed({1'b0, sum}) - MEAN_S;   // -765..+765

    reg step_d;                                    // the byte registers are valid one clock after step

    always @(posedge clk) begin
        if (rst) begin
            step_d    <= 1'b0;
            raw       <= 0;
            raw_valid <= 1'b0;
        end else begin
            step_d    <= step;
            raw_valid <= step_d;
            if (step_d)
                raw <= centered[`NOISE_RAW_BITS-1:0];
        end
    end
endmodule
