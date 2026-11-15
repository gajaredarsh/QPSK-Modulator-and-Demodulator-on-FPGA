// rx_frontend_top.v 
// Aditya 

// Connect:  in_valid <- awgn_channel.out_valid,  r_rx <- awgn_channel.r_rx        (12 bit, 256 = amplitude 1.0)
//           rst is the SAME reset as the transmitter, so the TX NCO and the RX NCO both start at phase 0.
// Outputs:  y_i, y_q, y_valid          filtered samples (12 bit)       -> d_yi.hex / d_yq.hex of the team golden set
//           i_hat, q_hat, sym_valid    symbol values (16 bit signed)   -> d_acc_i.hex / d_acc_q.hex, Part D takes the sign
//           xi, xq, x_valid            mixer outputs (12 bit), only for debugging / the testbench
// Latency (flag is high after the k-th clock edge following the edge that samples in_valid):
//           x_valid : 2        y_valid : 8        sym_valid : 9 after the last sample of a symbol window   (tb_rx_frontend checks this)
// Carrier phase is assumed known (TX and RX NCO have same start and same rate), so there is no Costas loop here.
// Sample spacing: in_valid can pulse every clock or as slowly as you like.
`timescale 1ns/1ps
`include "qpsk_rx_params.vh"

module rx_frontend_top #(
    parameter COS_FILE  = "lut_cos.hex",
    parameter SIN_FILE  = "lut_sin.hex",
    parameter COEF_FILE = "fir_coeffs.hex"
)(
    input  wire                           clk,
    input  wire                           rst,
    input  wire                           in_valid,   // a new received sample is there
    input  wire signed [`RXC_X_BITS-1:0]  r_rx,       // the received sample
    output wire signed [`RXC_X_BITS-1:0]  xi,         // mixer outputs
    output wire signed [`RXC_X_BITS-1:0]  xq,
    output wire                           x_valid,
    output wire signed [`RXC_X_BITS-1:0]  y_i,        // filter outputs
    output wire signed [`RXC_X_BITS-1:0]  y_q,
    output wire                           y_valid,
    output wire signed [`RXC_ACC_BITS-1:0] i_hat,     // one value per symbol
    output wire signed [`RXC_ACC_BITS-1:0] q_hat,
    output wire                           sym_valid
);
    // the local oscillator, steps one time for every received sample
    wire signed [`RXC_LO_BITS-1:0] lo_cos, lo_sin;
    rx_nco #(.COS_FILE(COS_FILE), .SIN_FILE(SIN_FILE))
        u_nco (.clk(clk), .rst(rst), .en(in_valid), .cos_o(lo_cos), .sin_o(lo_sin));

    // The NCO output for sample n comes one clock after in_valid is sampled, so we delay the sample
    // and its valid flag by one clock to line them up with it.
    reg signed [`RXC_X_BITS-1:0] r_d;
    reg                          v_d;
    always @(posedge clk) begin
        r_d <= r_rx;
        if (rst) v_d <= 1'b0; else v_d <= in_valid;
    end

    // mixer, gives xi and xq
    rx_mixer u_mix (.clk(clk), .rst(rst), .in_valid(v_d), .r(r_d), .cos_i(lo_cos), .sin_i(lo_sin),
                    .xi(xi), .xq(xq), .out_valid(x_valid));

    // two filters, one for I and one for Q. Both have the same timing so we use only the I valid flag
    // (vq_unused is the Q one, nothing is connected to it)
    wire vq_unused;
    fir_lpf #(.COEF_FILE(COEF_FILE)) u_fir_i (.clk(clk), .rst(rst), .in_valid(x_valid), .x_in(xi),
                                              .out_valid(y_valid), .y(y_i));
    fir_lpf #(.COEF_FILE(COEF_FILE)) u_fir_q (.clk(clk), .rst(rst), .in_valid(x_valid), .x_in(xq),
                                              .out_valid(vq_unused), .y(y_q));

    // adds up every 16 filtered samples to get one value per symbol
    symbol_sampler u_smp (.clk(clk), .rst(rst), .y_valid(y_valid), .y_i(y_i), .y_q(y_q),
                          .i_hat(i_hat), .q_hat(q_hat), .sym_valid(sym_valid));
endmodule
