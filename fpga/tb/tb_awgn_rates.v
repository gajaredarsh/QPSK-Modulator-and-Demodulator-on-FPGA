// tb_awgn_rates.v  (Part B)
// Checks awgn_core at the sample rates it will really see, with gain 5790 (0 dB):
//   mode 0: a sample on every clock (the fastest possible, 100 Msamples/s)
//   mode 1: one sample every 100 clocks (1 Msample/s on a 100 MHz clock, the rate in the plan)
//   mode 2: bursts of 10 back to back samples with a gap of 7 clocks
// Results are compared with the same Python vectors as tb_awgn_core.
// Run from the tb folder, so that the ../vectors path works.
`timescale 1ns/1ps
`include "qpsk_params.vh"

module tb_awgn_rates;
    localparam M       = 16000;
    localparam GAIN_IX = 1;                         // index of gain 5790 in vectors/core_gains.hex
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
    reg [`RX_BITS-1:0]         exp_r     [0:5*M-1];
    reg [`SUM_BITS-1:0]        exp_w     [0:5*M-1];
    reg [`NOISE_GAIN_BITS-1:0] gains_mem [0:4];
    integer got, errors, lat_errors;
    reg [LATENCY-1:0] vpipe;

    always @(posedge clk) begin
        if (rst) vpipe <= 0;
        else     vpipe <= {vpipe[LATENCY-2:0], in_valid};
        if (!rst) begin
            if (out_valid !== vpipe[LATENCY-1]) lat_errors = lat_errors + 1;
            if (out_valid) begin
                if (r_rx !== exp_r[GAIN_IX*M + got] || wide !== exp_w[GAIN_IX*M + got]) begin
                    errors = errors + 1;
                    if (errors <= 10) $display("MISMATCH sample %0d: got %0d, expected %0d", got, r_rx, $signed(exp_r[GAIN_IX*M + got]));
                end
                got = got + 1;
            end
        end
    end

    // mode: 0 every clock, 1 one sample per 100 clocks, 2 bursts of 10 with a gap of 7
    task run;
        input integer mode;
        input integer nsamp;
        integer i, gap;
        begin
            rst <= 1'b1; in_valid <= 1'b0;
            repeat (3) @(posedge clk);
            got = 0;
            rst <= 1'b0;
            for (i = 0; i < nsamp; i = i + 1) begin
                @(posedge clk);
                in_valid <= 1'b1;
                s_tx     <= in_mem[i];
                gap = 0;
                if (mode == 1) gap = 99;
                if (mode == 2 && ((i % 10) == 9)) gap = 7;
                repeat (gap) begin
                    @(posedge clk);
                    in_valid <= 1'b0;
                end
            end
            @(posedge clk);
            in_valid <= 1'b0;
            repeat (LATENCY + 6) @(posedge clk);
            if (got != nsamp) begin
                errors = errors + 1;
                $display("mode %0d: got %0d outputs, expected %0d", mode, got, nsamp);
            end else
                $display("  mode %0d: %0d samples checked", mode, nsamp);
        end
    endtask

    initial begin
        $readmemh("../vectors/core_in.hex", in_mem);
        $readmemh("../vectors/core_r12_all.hex", exp_r);
        $readmemh("../vectors/core_wide_all.hex", exp_w);
        $readmemh("../vectors/core_gains.hex", gains_mem);
        errors = 0; lat_errors = 0; got = 0;
        gain <= gains_mem[GAIN_IX];
        run(0, 4000);        // every clock
        run(1, 300);         // one sample per 100 clocks
        run(2, 4000);        // bursts
        if (errors == 0 && lat_errors == 0) $display("PASS tb_awgn_rates: every clock, 1 Msample/s and bursts all match, latency exactly %0d clocks", LATENCY);
        else                                $display("FAIL tb_awgn_rates: %0d value errors, %0d latency errors", errors, lat_errors);
        $finish;
    end

    initial begin
        #100000000;
        $display("FAIL tb_awgn_rates: timeout");
        $finish;
    end
endmodule
