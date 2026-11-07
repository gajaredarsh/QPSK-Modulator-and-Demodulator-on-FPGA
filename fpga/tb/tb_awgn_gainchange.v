// tb_awgn_gainchange.v  (Part B)
// Proves that the gain travels with its sample: the gain changes every 1..7 samples (random value
// from the ROM table or 0 = noise off), and on clocks WITHOUT in_valid the gain input is set to
// random junk. Every output must still equal channel.awgn_int(s, gain=per-sample gain array).
// Run from the tb folder, so that the ../vectors path works.
`timescale 1ns/1ps
`include "qpsk_params.vh"

module tb_awgn_gainchange;
    localparam M = 6000;
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

    reg [`TX_BITS-1:0]         in_mem   [0:M-1];
    reg [`NOISE_GAIN_BITS-1:0] gain_mem [0:M-1];
    reg [`RX_BITS-1:0]         exp_r    [0:M-1];
    reg [`SUM_BITS-1:0]        exp_w    [0:M-1];
    integer sent, got, errors, seed, distinct;
    reg [`NOISE_GAIN_BITS-1:0] last_g;

    always @(posedge clk) begin
        if (!rst && out_valid) begin
            if (got < M && (r_rx !== exp_r[got] || wide !== exp_w[got])) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("MISMATCH sample %0d: r_rx got %0d exp %0d | wide got %0d exp %0d",
                             got, r_rx, $signed(exp_r[got]), wide, $signed(exp_w[got]));
            end
            got = got + 1;
        end
    end

    initial begin
        $readmemh("../vectors/gc_in.hex",   in_mem);
        $readmemh("../vectors/gc_gain.hex", gain_mem);
        $readmemh("../vectors/gc_r12.hex",  exp_r);
        $readmemh("../vectors/gc_wide.hex", exp_w);
        errors = 0; got = 0; sent = 0; seed = 5; distinct = 0; last_g = {`NOISE_GAIN_BITS{1'bx}};
        repeat (4) @(posedge clk);
        rst <= 1'b0;
        while (sent < M) begin
            @(posedge clk);
            if (($random(seed) & 3) != 0) begin               // sample with its own gain
                in_valid <= 1'b1;
                s_tx     <= in_mem[sent];
                gain     <= gain_mem[sent];
                if (gain_mem[sent] !== last_g) distinct = distinct + 1;
                last_g = gain_mem[sent];
                sent = sent + 1;
            end else begin                                      // no sample: junk on the gain input
                in_valid <= 1'b0;
                gain     <= $random(seed);
            end
        end
        @(posedge clk);
        in_valid <= 1'b0;
        gain     <= $random(seed);
        repeat (LATENCY + 6) @(posedge clk);
        if (got != M) begin
            errors = errors + 1;
            $display("got %0d outputs, expected %0d", got, M);
        end
        if (errors == 0) $display("PASS tb_awgn_gainchange: %0d samples, gain changed %0d times, every sample used its own gain", M, distinct);
        else             $display("FAIL tb_awgn_gainchange: %0d errors", errors);
        $finish;
    end

    initial begin
        #50000000;
        $display("FAIL tb_awgn_gainchange: timeout");
        $finish;
    end
endmodule
