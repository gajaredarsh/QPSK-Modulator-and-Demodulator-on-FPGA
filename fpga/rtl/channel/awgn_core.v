// Main processing block of the AWGN channel.
// Generates noise, adds it to the transmitted signal and adjusts its scale.
// Also manages the pipeline timing of the samples.

`timescale 1ns/1ps
`include "qpsk_params.vh"

module awgn_core (
    input  wire                               clk,
    input  wire                               rst,
    input  wire                               in_valid,
    input  wire signed [`TX_BITS-1:0]         s_tx,
    input  wire        [`NOISE_GAIN_BITS-1:0] gain,
    output reg                                out_valid,
    output reg  signed [`RX_BITS-1:0]         r_rx,
    output reg  signed [`SUM_BITS-1:0]        wide
);
    // Signals used to connect the noise generation and scaling blocks.
    wire signed [`NOISE_RAW_BITS-1:0] raw;
    wire                              raw_valid;
    wire signed [`NOISE_BITS-1:0]     noise;
    wire                              noise_valid;

    // Delay the gain so it matches the correct noise sample.
    reg [`NOISE_GAIN_BITS-1:0] g_d1, g_d2;
    always @(posedge clk) begin
        if (rst) begin
            g_d1 <= 0; g_d2 <= 0;
        end else begin
            g_d1 <= gain;
            g_d2 <= g_d1;
        end
    end

    gauss_noise u_noise (
        .clk(clk), .rst(rst), .step(in_valid),
        .raw(raw), .raw_valid(raw_valid)
    );

    noise_scale u_scale (
        .clk(clk), .rst(rst), .raw_valid(raw_valid), .raw(raw), .gain(g_d2),
        .noise(noise), .noise_valid(noise_valid)
    );

    // Delay the transmitter sample until its noise value is ready.
    reg signed [`TX_BITS-1:0] s_d1, s_d2, s_d3, s_d4;

    reg signed [`SUM_BITS-1:0] sum5;
    reg                        v5;

    // Convert the result to the receiver scale and limit its value.
    wire signed [31:0] shifted = (sum5 + (1 << (`TX_TO_RX_SHIFT - 1))) >>> `TX_TO_RX_SHIFT;
    wire signed [`RX_BITS-1:0] rx_max = {1'b0, {(`RX_BITS-1){1'b1}}};
    wire signed [`RX_BITS-1:0] rx_min = {1'b1, {(`RX_BITS-1){1'b0}}};

    always @(posedge clk) begin
        if (rst) begin
            s_d1 <= 0; s_d2 <= 0; s_d3 <= 0; s_d4 <= 0;
            sum5 <= 0; v5 <= 1'b0;
            r_rx <= 0; wide <= 0; out_valid <= 1'b0;
        end else begin
            // Keep the input sample moving through the pipeline.
            s_d1 <= s_tx;
            s_d2 <= s_d1;
            s_d3 <= s_d2;
            s_d4 <= s_d3;

            // Add the noise when the corresponding sample is ready.
            v5 <= noise_valid;
            if (noise_valid)
                sum5 <= s_d4 + noise;

            // Send the final result to the receiver.
            out_valid <= v5;
            if (v5) begin
                wide <= sum5;
                if (shifted > rx_max)
                    r_rx <= rx_max;
                else if (shifted < rx_min)
                    r_rx <= rx_min;
                else
                    r_rx <= shifted[`RX_BITS-1:0];
            end
        end
    end
endmodule
