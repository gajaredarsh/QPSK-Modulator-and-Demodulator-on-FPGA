// Generates random bytes using a 16-bit LFSR.
// The LFSR advances when the step signal is enabled.
// Eight LFSR steps are used to generate each byte.

`timescale 1ns/1ps

module lfsr_byte #(
    parameter [15:0] SEED = 16'h0001
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       step,
    output reg  [7:0] byte_q
);
    reg [15:0] state;

    // Calculate the next LFSR state and the output byte.
    function [23:0] adv8;
        input [15:0] s_in;
        reg   [15:0] s;
        reg   [7:0]  b;
        reg          fb;
        integer      i;
        begin
            s = s_in;
            b = 8'd0;
            for (i = 0; i < 8; i = i + 1) begin
                // Generate the feedback bit and update the state.
                fb = s[0] ^ s[2] ^ s[3] ^ s[5];
                s  = {fb, s[15:1]};
                b  = {b[6:0], s[0]};
            end
            adv8 = {s, b};
        end
    endfunction

    wire [23:0] nxt = adv8(state);

    always @(posedge clk) begin
        if (rst) begin
            state  <= SEED;
            byte_q <= 8'd0;
        end else if (step) begin
            // Update the LFSR state and store the new byte.
            state  <= nxt[23:8];
            byte_q <= nxt[7:0];
        end
    end
endmodule
