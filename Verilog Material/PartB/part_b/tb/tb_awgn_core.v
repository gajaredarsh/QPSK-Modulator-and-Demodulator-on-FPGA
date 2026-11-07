// tb_awgn_core.v  (Part B)
// Checks awgn_core against channel.awgn_int for five gains, using 16000 TX samples:
// 500 QPSK symbols, then 8000 random full range 13 bit values (this makes the 12 bit
// saturation happen at the high gains). It checks both r_rx and the 16 bit wide sum.
// It also checks that out_valid comes exactly 6 clocks after in_valid, with random gaps.
// Run from the tb folder, so that the ../vectors path works.
`timescale 1ns/1ps
`include "qpsk_params.vh"

module tb_awgn_core;
    localparam M  = 16000;
    localparam NG = 5;
    localparam LATENCY = 6;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;
    reg                                in_valid = 1'b0;
    reg  signed [`TX_BITS-1:0]         s_tx     = 0;
    reg         [`NOISE_GAIN_BITS-1:0] gain     = 0;
    wire                               out_valid;
    wire signed [`RX_BITS-1:0]         r_rx;
    wire signed [`SUM_BITS-1:0]        wide;

    awgn_core dut (.clk(clk), .rst(rst), .in_valid(in_valid), .s_tx(s_tx), .gain(gain),
                   .out_valid(out_valid), .r_rx(r_rx), .wide(wide));

    reg [`TX_BITS-1:0]         in_mem    [0:M-1];
    reg [`RX_BITS-1:0]         exp_r     [0:NG*M-1];
    reg [`SUM_BITS-1:0]        exp_w     [0:NG*M-1];
    reg [`NOISE_GAIN_BITS-1:0] gains_mem [0:NG-1];

    integer t, sent, got, base, errors, lat_errors, sat_hi, sat_lo, seed;
    reg [LATENCY-1:0] vpipe;                      // in_valid delayed by 1..6 clocks

    // checker
    always @(posedge clk) begin
        if (rst) vpipe <= 0;
        else     vpipe <= {vpipe[LATENCY-2:0], in_valid};

        if (!rst) begin
            if (out_valid !== vpipe[LATENCY-1]) lat_errors = lat_errors + 1;
            if (out_valid) begin
                if (r_rx !== exp_r[base + got] || wide !== exp_w[base + got]) begin
                    errors = errors + 1;
                    if (errors <= 10)
                        $display("MISMATCH gain %0d sample %0d: r_rx got %0d exp %0d | wide got %0d exp %0d",
                                 gain, got, r_rx, $signed(exp_r[base + got]), wide, $signed(exp_w[base + got]));
                end
                if (r_rx ===  12'sd2047) sat_hi = sat_hi + 1;
                if (r_rx === -12'sd2048) sat_lo = sat_lo + 1;
                got = got + 1;
            end
        end
    end

    initial begin
        $readmemh("../vectors/core_in.hex", in_mem);
        $readmemh("../vectors/core_r12_all.hex", exp_r);
        $readmemh("../vectors/core_wide_all.hex", exp_w);
        $readmemh("../vectors/core_gains.hex", gains_mem);
        errors = 0; lat_errors = 0; sat_hi = 0; sat_lo = 0; seed = 11; got = 0; base = 0;

        for (t = 0; t < NG; t = t + 1) begin
            rst <= 1'b1; in_valid <= 1'b0;
            gain <= gains_mem[t];
            repeat (3) @(posedge clk);
            got = 0; base = t * M;
            rst <= 1'b0;
            sent = 0;
            while (sent < M) begin
                @(posedge clk);
                if (($random(seed) & 3) != 0) begin       // about 75 % of the clocks carry a sample
                    in_valid <= 1'b1;
                    s_tx     <= in_mem[sent];
                    sent = sent + 1;
                end else
                    in_valid <= 1'b0;
            end
            @(posedge clk);
            in_valid <= 1'b0;
            repeat (LATENCY + 6) @(posedge clk);
            if (got != M) begin
                errors = errors + 1;
                $display("gain %0d: got %0d outputs, expected %0d", gains_mem[t], got, M);
            end else
                $display("  gain %5d: %0d samples checked", gains_mem[t], M);
        end

        $display("  12 bit saturation was exercised: %0d samples at +2047, %0d samples at -2048", sat_hi, sat_lo);
        if (sat_hi == 0 || sat_lo == 0) begin
            errors = errors + 1;
            $display("saturation was NOT exercised at both limits (hi %0d, lo %0d): the test is too weak", sat_hi, sat_lo);
        end
        if (lat_errors != 0) $display("latency check: %0d cycles where out_valid was not in_valid delayed by %0d", lat_errors, LATENCY);
        if (errors == 0 && lat_errors == 0) $display("PASS tb_awgn_core: outputs match the Python model, latency is exactly %0d clocks", LATENCY);
        else                                $display("FAIL tb_awgn_core: %0d value errors, %0d latency errors", errors, lat_errors);
        $finish;
    end

    initial begin
        #100000000;
        $display("FAIL tb_awgn_core: timeout");
        $finish;
    end
endmodule
