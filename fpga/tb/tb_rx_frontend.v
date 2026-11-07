// tb_rx_frontend.v  (Part C)  --  self-checking, bit-exact against the Python model.
// Author: [FILL IN YOUR NAME] (Part C)  |  AI-assistance: drafted with Claude (Anthropic) for EE2000; cite per course AI-usage policy.
//
// Drives rx_frontend_top with six input sets and compares EVERY sample at three points:
//   mixer output (xi, xq)      vs rx_frontend.downconvert_fixed      (sets 0-4)
//   FIR output   (y_i, y_q)    vs rx_frontend.lpf_fixed(aligned=False)
//   symbol value (i_hat,q_hat) vs rx_backend_eval.integrate_dump(timing_offset=12)
// Sets 0-4: the Part B channel output at five noise gains (gain 0 = noise free ... gain 0x1FFF = very noisy, with
//           12 bit saturation), 16000 samples each (500 QPSK symbols, then 8000 random full-range words as a stress test).
// Set 5   : the team's own golden file set (d_yi, d_yq, d_acc_i, d_acc_q from d_outputs/golden), reproduced from the
//           LFSR-noise run at 6 dB.
// It also checks the pipeline latency of every output flag.
//
// MODE selects the spacing of the input samples:   0 = one sample every clock (fastest possible)
//                                                  1 = one sample every 4 clocks
//                                                  2 = random gaps of 0..6 clocks (r_rx carries random junk in the gaps)
// Run from a folder that contains vectors/, lut_cos.hex, lut_sin.hex  (run_sim.sh does this).
`timescale 1ns/1ps
`include "qpsk_rx_params.vh"

module tb_rx_frontend;
    parameter MODE = 0;

    localparam NSET = 6;
    localparam M    = 16000;
    localparam NSYM = 999;
    localparam NT   = 2048;
    localparam NTS  = 127;
    localparam NIN  = 5*M + NT;
    localparam NACC = 5*NSYM + NTS;
    localparam LAT_X = 2, LAT_Y = 8, LAT_S = 9;         // clocks after the edge that samples in_valid

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;
    reg in_valid = 1'b0;
    reg signed [`RXC_X_BITS-1:0] r_rx = 0;

    wire signed [`RXC_X_BITS-1:0]   xi, xq, y_i, y_q;
    wire signed [`RXC_ACC_BITS-1:0] i_hat, q_hat;
    wire x_valid, y_valid, sym_valid;

    rx_frontend_top dut (.clk(clk), .rst(rst), .in_valid(in_valid), .r_rx(r_rx),
                         .xi(xi), .xq(xq), .x_valid(x_valid), .y_i(y_i), .y_q(y_q), .y_valid(y_valid),
                         .i_hat(i_hat), .q_hat(q_hat), .sym_valid(sym_valid));

    reg [`RXC_X_BITS-1:0]   in_mem [0:NIN-1];
    reg [`RXC_X_BITS-1:0]   xi_mem [0:NIN-1];
    reg [`RXC_X_BITS-1:0]   xq_mem [0:NIN-1];
    reg [`RXC_X_BITS-1:0]   yi_mem [0:NIN-1];
    reg [`RXC_X_BITS-1:0]   yq_mem [0:NIN-1];
    reg [`RXC_ACC_BITS-1:0] ai_mem [0:NACC-1];
    reg [`RXC_ACC_BITS-1:0] aq_mem [0:NACC-1];

    initial begin
        $readmemh("vectors/rx_in_all.hex",    in_mem, 0, 5*M-1);
        $readmemh("vectors/rx_xi_all.hex",    xi_mem, 0, 5*M-1);
        $readmemh("vectors/rx_xq_all.hex",    xq_mem, 0, 5*M-1);
        $readmemh("vectors/rx_yi_all.hex",    yi_mem, 0, 5*M-1);
        $readmemh("vectors/rx_yq_all.hex",    yq_mem, 0, 5*M-1);
        $readmemh("vectors/rx_acc_i_all.hex", ai_mem, 0, 5*NSYM-1);
        $readmemh("vectors/rx_acc_q_all.hex", aq_mem, 0, 5*NSYM-1);
        $readmemh("vectors/team_in.hex",      in_mem, 5*M, NIN-1);
        $readmemh("vectors/team_yi.hex",      yi_mem, 5*M, NIN-1);
        $readmemh("vectors/team_yq.hex",      yq_mem, 5*M, NIN-1);
        $readmemh("vectors/team_acc_i.hex",   ai_mem, 5*NSYM, NACC-1);
        $readmemh("vectors/team_acc_q.hex",   aq_mem, 5*NSYM, NACC-1);
    end

    // ---- per-set bookkeeping -------------------------------------------------------------------------------
    integer set_i, base_in, len_in, base_acc, n_acc, check_x;
    integer cyc = 0;
    integer n_in, n_x, n_y, n_s;
    integer err_x, err_y, err_s, err_lat, tot_err;
    integer lat_x_seen, lat_y_seen, lat_s_seen;
    integer in_cyc [0:NIN-1];
    integer win_end;
    reg     active = 1'b0;

    always @(posedge clk) begin
        cyc = cyc + 1;
        if (active && !rst) begin
            if (in_valid) begin in_cyc[n_in] = cyc; n_in = n_in + 1; end

            if (x_valid && n_x < len_in) begin
                if (check_x != 0 && (xi !== xi_mem[base_in + n_x] || xq !== xq_mem[base_in + n_x])) begin
                    err_x = err_x + 1;
                    if (err_x <= 5) $display("MISMATCH set %0d mixer sample %0d: xi %0d/%0d xq %0d/%0d", set_i, n_x,
                        xi, $signed(xi_mem[base_in + n_x]), xq, $signed(xq_mem[base_in + n_x]));
                end
                if (cyc - in_cyc[n_x] - 1 !== LAT_X) begin
                    err_lat = err_lat + 1;
                    if (err_lat <= 5) $display("LATENCY set %0d x_valid sample %0d: %0d clocks, expected %0d", set_i, n_x,
                        cyc - in_cyc[n_x] - 1, LAT_X);
                end
                n_x = n_x + 1;
            end

            if (y_valid && n_y < len_in) begin
                if (y_i !== yi_mem[base_in + n_y] || y_q !== yq_mem[base_in + n_y]) begin
                    err_y = err_y + 1;
                    if (err_y <= 5) $display("MISMATCH set %0d FIR sample %0d: y_i %0d/%0d y_q %0d/%0d", set_i, n_y,
                        y_i, $signed(yi_mem[base_in + n_y]), y_q, $signed(yq_mem[base_in + n_y]));
                end
                if (cyc - in_cyc[n_y] - 1 !== LAT_Y) begin
                    err_lat = err_lat + 1;
                    if (err_lat <= 5) $display("LATENCY set %0d y_valid sample %0d: %0d clocks, expected %0d", set_i, n_y,
                        cyc - in_cyc[n_y] - 1, LAT_Y);
                end
                n_y = n_y + 1;
            end

            if (sym_valid && n_s < n_acc) begin
                if (i_hat !== ai_mem[base_acc + n_s] || q_hat !== aq_mem[base_acc + n_s]) begin
                    err_s = err_s + 1;
                    if (err_s <= 5) $display("MISMATCH set %0d symbol %0d: i_hat %0d/%0d q_hat %0d/%0d", set_i, n_s,
                        i_hat, $signed(ai_mem[base_acc + n_s]), q_hat, $signed(aq_mem[base_acc + n_s]));
                end
                win_end = `RXC_OFFSET + `RXC_SPS*n_s + `RXC_SPS - 1;           // input sample that closes this window
                if (cyc - in_cyc[win_end] - 1 !== LAT_S) begin
                    err_lat = err_lat + 1;
                    if (err_lat <= 5) $display("LATENCY set %0d sym_valid symbol %0d: %0d clocks, expected %0d", set_i, n_s,
                        cyc - in_cyc[win_end] - 1, LAT_S);
                end
                n_s = n_s + 1;
            end
        end
    end

    // ---- stimulus -----------------------------------------------------------------------------------------
    integer q, gap, seed = 7;
    task send;
        input [`RXC_X_BITS-1:0] v;
        begin
            in_valid <= 1'b1; r_rx <= v;
            @(posedge clk);
            case (MODE)
                0: gap = 0;
                1: gap = 3;
                default: gap = {$random(seed)} % 7;
            endcase
            for (q = 0; q < gap; q = q + 1) begin
                in_valid <= 1'b0; r_rx <= $random(seed);
                @(posedge clk);
            end
        end
    endtask

    integer n;
    initial begin
        tot_err = 0;
        for (set_i = 0; set_i < NSET; set_i = set_i + 1) begin
            base_in  = (set_i < 5) ? set_i*M : 5*M;
            len_in   = (set_i < 5) ? M : NT;
            base_acc = (set_i < 5) ? set_i*NSYM : 5*NSYM;
            n_acc    = (set_i < 5) ? NSYM : NTS;
            check_x  = (set_i < 5);
            n_in = 0; n_x = 0; n_y = 0; n_s = 0;
            err_x = 0; err_y = 0; err_s = 0; err_lat = 0;
            active = 1'b0; rst = 1'b1; in_valid = 1'b0;
            repeat (4) @(posedge clk);
            rst <= 1'b0;
            repeat (2) @(posedge clk);
            active = 1'b1;
            for (n = 0; n < len_in; n = n + 1) send(in_mem[base_in + n]);
            in_valid <= 1'b0;
            repeat (40) @(posedge clk);
            if (n_x != len_in || n_y != len_in || n_s != n_acc) begin
                err_lat = err_lat + 1;
                $display("COUNT set %0d: mixer %0d/%0d, FIR %0d/%0d, symbols %0d/%0d", set_i, n_x, len_in, n_y, len_in, n_s, n_acc);
            end
            $display("set %0d: %0d samples, %0d symbols | mixer errors %0d, FIR errors %0d, symbol errors %0d, latency/count errors %0d",
                     set_i, len_in, n_acc, err_x, err_y, err_s, err_lat);
            tot_err = tot_err + err_x + err_y + err_s + err_lat;
        end
        if (tot_err == 0) $display("PASS: tb_rx_frontend MODE=%0d, all %0d sets bit-exact", MODE, NSET);
        else              $display("FAIL: tb_rx_frontend MODE=%0d, %0d errors", MODE, tot_err);
        $finish;
    end

    initial begin #(10*20_000_000); $display("FAIL: timeout"); $finish; end
endmodule
