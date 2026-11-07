// rx_frontend_top.v  (Part C)  --  receiver front end: LO -> mixer -> FIR low-pass (I and Q) -> integrate-and-dump
// Author: [FILL IN YOUR NAME] (Part C)  |  AI-assistance: drafted with Claude (Anthropic) for EE2000; cite per course AI-usage policy.
//
//   r_rx --+--> [align] --> rx_mixer --> fir_lpf (I) --+--> symbol_sampler --> i_hat, q_hat, sym_valid
//          |                    ^         fir_lpf (Q) --+
//   rx_nco (stepped by in_valid) -+
//
// Mirrors:  rx_frontend.rx_frontend_fixed(r, cos, sin, h, aligned=False)  then  rx_backend_eval.integrate_dump(.., OFFSET)
// Connect :  in_valid <- awgn_channel.out_valid,  r_rx <- awgn_channel.r_rx        (12 bit, 256 = amplitude 1.0)
//            rst is the SAME reset as the transmitter, so TX NCO and RX NCO both start at phase 0.
// Outputs :  y_i, y_q, y_valid          filtered samples (12 bit)       -> d_yi.hex / d_yq.hex of the team golden set
//            i_hat, q_hat, sym_valid    symbol values (16 bit signed)   -> d_acc_i.hex / d_acc_q.hex; Part D takes the sign
//            xi, xq, x_valid            mixer outputs (12 bit), for debugging / the testbench
// Latency (the flag is visible after the k-th clock edge following the edge that samples in_valid):
//            x_valid : 2        y_valid : 8        sym_valid : 9 after the last sample of a symbol window   (checked by tb_rx_frontend)
// Carrier phase is assumed known (TX and RX NCO share start and rate); there is no Costas loop here.
// Sample spacing: in_valid may pulse every clock or as slowly as you like.
`timescale 1ns/1ps
`include "qpsk_rx_params.vh"

module rx_frontend_top #(
    parameter COS_FILE  = "lut_cos.hex",
    parameter SIN_FILE  = "lut_sin.hex",
    parameter COEF_FILE = "fir_coeffs.hex"
)(
    input  wire                           clk,
    input  wire                           rst,
    input  wire                           in_valid,
    input  wire signed [`RXC_X_BITS-1:0]  r_rx,
    output wire signed [`RXC_X_BITS-1:0]  xi,
    output wire signed [`RXC_X_BITS-1:0]  xq,
    output wire                           x_valid,
    output wire signed [`RXC_X_BITS-1:0]  y_i,
    output wire signed [`RXC_X_BITS-1:0]  y_q,
    output wire                           y_valid,
    output wire signed [`RXC_ACC_BITS-1:0] i_hat,
    output wire signed [`RXC_ACC_BITS-1:0] q_hat,
    output wire                           sym_valid
);
    wire signed [`RXC_LO_BITS-1:0] lo_cos, lo_sin;
    rx_nco #(.COS_FILE(COS_FILE), .SIN_FILE(SIN_FILE))
        u_nco (.clk(clk), .rst(rst), .en(in_valid), .cos_o(lo_cos), .sin_o(lo_sin));

    // The NCO output for sample n appears one clock after in_valid is sampled, so the sample and its valid flag
    // are delayed by one clock to line up with it.
    reg signed [`RXC_X_BITS-1:0] r_d;
    reg                          v_d;
    always @(posedge clk) begin
        r_d <= r_rx;
        if (rst) v_d <= 1'b0; else v_d <= in_valid;
    end

    rx_mixer u_mix (.clk(clk), .rst(rst), .in_valid(v_d), .r(r_d), .cos_i(lo_cos), .sin_i(lo_sin),
                    .xi(xi), .xq(xq), .out_valid(x_valid));

    wire vq_unused;
    fir_lpf #(.COEF_FILE(COEF_FILE)) u_fir_i (.clk(clk), .rst(rst), .in_valid(x_valid), .x_in(xi),
                                              .out_valid(y_valid), .y(y_i));
    fir_lpf #(.COEF_FILE(COEF_FILE)) u_fir_q (.clk(clk), .rst(rst), .in_valid(x_valid), .x_in(xq),
                                              .out_valid(vq_unused), .y(y_q));

    symbol_sampler u_smp (.clk(clk), .rst(rst), .y_valid(y_valid), .y_i(y_i), .y_q(y_q),
                          .i_hat(i_hat), .q_hat(q_hat), .sym_valid(sym_valid));
endmodule
