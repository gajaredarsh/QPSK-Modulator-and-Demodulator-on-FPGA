// awgn_core.v  (Part B)
// The integer channel, with the gain given as a port.
//   noise = (raw * gain + 128) >>> 8
//   sum   = s_tx + noise                       (16 bit, cannot overflow)
//   r_rx  = clip12( (sum + 4) >>> 3 )          (12 bit RX word, 256 = amplitude 1.0)
//
// Mirrors:  channel.awgn_int(s13, gain=gain, return_wide=True)
// Ports  :  in_valid, s_tx   TX mixer output, signed 13 bit (2047 = amplitude 1.0)
//           gain             unsigned 13 bit. It is captured together with each sample and travels down the
//                            pipe with it, so it MAY change at any time: every sample is scaled with the gain
//                            that was present when that sample entered (tested in tb_awgn_gainchange)
//           out_valid, r_rx  signed 12 bit RX word
//           wide             the 16 bit sum before the shift (handy for debugging)
// Latency:  6 clocks from in_valid / s_tx to out_valid / r_rx / wide
//
// The noise generator only advances when in_valid is high, so sample number n always gets
// noise number n, whatever the gaps between samples.
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
    // ---- noise path (4 clocks: LFSR byte, sum, multiply, shift) ----
    wire signed [`NOISE_RAW_BITS-1:0] raw;
    wire                              raw_valid;
    wire signed [`NOISE_BITS-1:0]     noise;
    wire                              noise_valid;

    // ---- the gain is captured with the sample and delayed 2 clocks, which is how long the sample
    //      needs to get from in_valid to the multiplier inside noise_scale (gauss_noise: 2 clocks)
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

    // ---- the TX sample waits 4 clocks so that it meets its own noise sample ----
    reg signed [`TX_BITS-1:0] s_d1, s_d2, s_d3, s_d4;

    // ---- stage 5: add the noise ----
    reg signed [`SUM_BITS-1:0] sum5;
    reg                        v5;

    // ---- stage 6: shift to the RX scale and clip to 12 bits ----
    wire signed [31:0] shifted = (sum5 + (1 << (`TX_TO_RX_SHIFT - 1))) >>> `TX_TO_RX_SHIFT;
    wire signed [`RX_BITS-1:0] rx_max = {1'b0, {(`RX_BITS-1){1'b1}}};     //  2047
    wire signed [`RX_BITS-1:0] rx_min = {1'b1, {(`RX_BITS-1){1'b0}}};     // -2048

    always @(posedge clk) begin
        if (rst) begin
            s_d1 <= 0; s_d2 <= 0; s_d3 <= 0; s_d4 <= 0;
            sum5 <= 0; v5 <= 1'b0;
            r_rx <= 0; wide <= 0; out_valid <= 1'b0;
        end else begin
            s_d1 <= s_tx;
            s_d2 <= s_d1;
            s_d3 <= s_d2;
            s_d4 <= s_d3;

            v5 <= noise_valid;
            if (noise_valid)
                sum5 <= s_d4 + noise;

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
