// tb_chain.v  (Part C)  --  integration test: Part A tx_top -> Part B awgn_channel -> Part C rx_frontend_top.
// Author: [FILL IN YOUR NAME] (Part C)  |  AI-assistance: drafted with Claude (Anthropic) for EE2000; cite per course AI-usage policy.
//
// Compares every symbol value (i_hat, q_hat) bit-exactly against the Python chain
//   golden TX waveform -> channel.awgn_int -> rx_frontend (mixer, FIR) -> integrate_dump
// and checks the hard decisions against the bits the transmitter really sent.
//   noise_off = 1 : the decisions must be 100 % correct (all 511 symbols)
//   noise_off = 0 : decisions are only counted (BER is printed), the bit-exact check is what must pass
// CLK_DIV  = clocks between samples (1 = every clock, 100 = 1 Msample/s at 100 MHz).
// Reports how many TX symbols are already started when RX symbol k comes out, which is the delay Part D needs for its
// reference bits (it should delay by SYMBOLS, counted with sym_stb / sym_valid, not by clocks).
`timescale 1ns/1ps
`include "qpsk_params.vh"
`include "qpsk_rx_params.vh"

module tb_chain;
    parameter CLK_DIV   = 1;
    parameter NOISE_OFF = 1;
    parameter LEVEL     = 6;
    parameter ACC_I = "vectors/chain_acc_i_off.hex";
    parameter ACC_Q = "vectors/chain_acc_q_off.hex";
    localparam NS = 511;                       // complete symbol windows in the 512-symbol golden waveform

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;

    integer div_cnt = 0;
    wire sample_en = (div_cnt == CLK_DIV-1);
    always @(posedge clk) div_cnt <= rst ? 0 : (sample_en ? 0 : div_cnt + 1);

    // transmitter (Part A)
    wire signed [`MIXER_OUT_BITS-1:0] s_out;
    wire s_stb, sym_stb;
    wire [1:0] tx_bits;
    tx_top u_tx (.clk(clk), .rst(rst), .sample_en(sample_en), .s_out(s_out), .s_stb(s_stb),
                 .tx_bits(tx_bits), .sym_stb(sym_stb), .pat_en(1'b0), .pat(8'h00));

    // channel (Part B)
    wire ch_valid;
    wire signed [`RX_BITS-1:0]  r_rx;
    wire signed [`SUM_BITS-1:0] wide;
    awgn_channel u_ch (.clk(clk), .rst(rst), .in_valid(s_stb), .s_tx(s_out), .level(LEVEL[3:0]),
                       .noise_off(NOISE_OFF[0]), .out_valid(ch_valid), .r_rx(r_rx), .wide(wide));

    // receiver front end (Part C)
    wire signed [`RXC_X_BITS-1:0]   xi, xq, y_i, y_q;
    wire signed [`RXC_ACC_BITS-1:0] i_hat, q_hat;
    wire x_valid, y_valid, sym_valid;
    rx_frontend_top u_rx (.clk(clk), .rst(rst), .in_valid(ch_valid), .r_rx(r_rx),
                          .xi(xi), .xq(xq), .x_valid(x_valid), .y_i(y_i), .y_q(y_q), .y_valid(y_valid),
                          .i_hat(i_hat), .q_hat(q_hat), .sym_valid(sym_valid));

    reg [`RXC_ACC_BITS-1:0] ai_mem [0:NS-1];
    reg [`RXC_ACC_BITS-1:0] aq_mem [0:NS-1];
    reg [1:0]               tb_mem [0:511];
    reg [1:0]               txb    [0:1023];
    initial begin
        $readmemh(ACC_I, ai_mem);
        $readmemh(ACC_Q, aq_mem);
        $readmemh("vectors/chain_tx_bits.hex", tb_mem);
        repeat (5) @(posedge clk);
        rst <= 1'b0;
    end

    integer k_tx = 0, k_rx = 0, err_acc = 0, err_bits = 0, err_gold = 0, ahead_min = 1000, ahead_max = -1000, ahead;
    reg [1:0] dec;
    always @(posedge clk) if (!rst) begin
        if (sym_stb) begin
            if (k_tx < 512 && tx_bits !== tb_mem[k_tx]) err_gold = err_gold + 1;
            txb[k_tx] = tx_bits;
            k_tx = k_tx + 1;
        end
        if (sym_valid && k_rx < NS) begin
            if (i_hat !== ai_mem[k_rx] || q_hat !== aq_mem[k_rx]) begin
                err_acc = err_acc + 1;
                if (err_acc <= 5) $display("MISMATCH symbol %0d: i_hat %0d/%0d q_hat %0d/%0d", k_rx,
                    i_hat, $signed(ai_mem[k_rx]), q_hat, $signed(aq_mem[k_rx]));
            end
            dec = {i_hat < 0, q_hat < 0};                      // bit = (value < 0), {b0 (I), b1 (Q)}
            err_bits = err_bits + (dec[1] !== txb[k_rx][1]) + (dec[0] !== txb[k_rx][0]);
            ahead = k_tx - k_rx - 1;                            // TX symbols already started beyond symbol k_rx
            if (ahead < ahead_min) ahead_min = ahead;
            if (ahead > ahead_max) ahead_max = ahead;
            k_rx = k_rx + 1;
            if (k_rx == NS) begin
                $display("chain: noise_off=%0d level=%0d CLK_DIV=%0d | %0d symbols | Python mismatches %0d | TX bit mismatches vs golden_bits %0d",
                         NOISE_OFF, LEVEL, CLK_DIV, NS, err_acc, err_gold);
                $display("chain: bit errors %0d / %0d (BER %f) | TX is %0d..%0d symbols ahead when RX symbol k is ready",
                         err_bits, 2*NS, err_bits / (2.0*NS), ahead_min, ahead_max);
                if (err_acc == 0 && err_gold == 0 && (NOISE_OFF == 0 || err_bits == 0))
                    $display("PASS: tb_chain bit-exact against the Python chain");
                else
                    $display("FAIL: tb_chain");
                $finish;
            end
        end
    end

    initial begin #(10*CLK_DIV*8192*3 + 100000); $display("FAIL: timeout (k_tx=%0d k_rx=%0d)", k_tx, k_rx); $finish; end
endmodule
