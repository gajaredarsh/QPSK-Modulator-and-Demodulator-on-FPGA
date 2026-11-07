// Self-checking testbench: tx_top vs Python golden vectors (bit-exact).
// Run from the directory holding golden_*.hex, lut_*.hex, qpsk_params.vh.
`timescale 1ns/1ps
`include "qpsk_params.vh"
module tb_tx_top;
    parameter CLK_DIV = 1;                       // clocks per sample_en tick
    localparam NS    = `TB_N_SYMBOLS;
    localparam NSAMP = NS * `SPS;

    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    integer div_cnt = 0;
    wire sample_en = (div_cnt == CLK_DIV-1);
    always @(posedge clk) div_cnt <= rst ? 0 : (sample_en ? 0 : div_cnt + 1);

    wire signed [`MIXER_OUT_BITS-1:0] s_out;
    wire s_stb, sym_stb;
    wire [1:0] tx_bits;
    tx_top dut (.clk(clk), .rst(rst), .sample_en(sample_en),
                .s_out(s_out), .s_stb(s_stb), .tx_bits(tx_bits), .sym_stb(sym_stb));

    reg [`MIXER_OUT_BITS-1:0] gold_s [0:NSAMP-1];
    reg [1:0]                 gold_b [0:NS-1];
    initial begin
        $readmemh("golden_s.hex", gold_s);
        $readmemh("golden_bits.hex", gold_b);
        repeat (5) @(posedge clk);
        rst <= 0;
    end

    integer n = 0, k = 0, err_s = 0, err_b = 0;
    always @(posedge clk) if (!rst) begin
        if (s_stb && n < NSAMP) begin
            if (s_out !== gold_s[n]) begin
                err_s = err_s + 1;
                if (err_s <= 5) $display("MISMATCH sample %0d: got %0d exp %0d", n, s_out, $signed(gold_s[n]));
            end
            n = n + 1;
        end
        if (sym_stb && k < NS) begin
            if (tx_bits !== gold_b[k]) begin
                err_b = err_b + 1;
                if (err_b <= 5) $display("MISMATCH symbol %0d: got %b exp %b", k, tx_bits, gold_b[k]);
            end
            k = k + 1;
        end
        if (n == NSAMP && k == NS) begin
            if (err_s == 0 && err_b == 0)
                $display("PASS: %0d samples and %0d symbols bit-exact (CLK_DIV=%0d)", n, k, CLK_DIV);
            else
                $display("FAIL: %0d sample errors, %0d symbol errors", err_s, err_b);
            $finish;
        end
    end

    initial begin #(10*CLK_DIV*NSAMP*2 + 1000); $display("FAIL: timeout (n=%0d k=%0d)", n, k); $finish; end
endmodule
