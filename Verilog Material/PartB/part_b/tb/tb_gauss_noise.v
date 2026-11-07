// tb_gauss_noise.v  (Part B)
// Checks gauss_noise against vectors/noise_raw.hex (channel.lfsr_noise_raw, 70000 samples).
// 70000 is more than one LFSR period (65535), so the wrap around is checked too.
// The step pulses have random gaps (some back to back) to prove the noise only advances on step.
// Run from the tb folder, so that the ../vectors path works.
`timescale 1ns/1ps
`include "qpsk_params.vh"

module tb_gauss_noise;
    localparam N = 70000;

    reg clk = 1'b0;
    always #5 clk = ~clk;                       // 100 MHz
    reg rst  = 1'b1;
    reg step = 1'b0;
    wire signed [`NOISE_RAW_BITS-1:0] raw;
    wire                              raw_valid;

    gauss_noise dut (.clk(clk), .rst(rst), .step(step), .raw(raw), .raw_valid(raw_valid));

    reg [`NOISE_RAW_BITS-1:0] exp_mem [0:N-1];
    integer sent, got, errors, seed, lat_errors;
    localparam LATENCY = 2;                       // clocks from step to raw / raw_valid
    reg [LATENCY-1:0] vpipe;                      // step delayed by 1..2 clocks

    // valid timing: raw_valid must be exactly step delayed by LATENCY clocks
    always @(posedge clk) begin
        if (rst) vpipe <= 0;
        else begin
            vpipe <= {vpipe[LATENCY-2:0], step};
            if (raw_valid !== vpipe[LATENCY-1]) lat_errors = lat_errors + 1;
        end
    end

    initial begin
        $readmemh("../vectors/noise_raw.hex", exp_mem);
        sent = 0; got = 0; errors = 0; seed = 1; lat_errors = 0;
        repeat (4) @(posedge clk);
        rst <= 1'b0;
    end

    // stimulus: one step pulse per sample, 3 clocks out of 4 on average
    always @(posedge clk) begin
        if (rst)
            step <= 1'b0;
        else if (sent < N && (($random(seed) & 3) != 0)) begin
            step <= 1'b1;
            sent <= sent + 1;
        end else
            step <= 1'b0;
    end

    // checker
    always @(posedge clk) begin
        if (!rst && raw_valid) begin
            if (raw !== exp_mem[got]) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("MISMATCH at sample %0d: got %0d, expected %0d", got, raw, $signed(exp_mem[got]));
            end
            got = got + 1;
            if (got == N) begin
                if (errors == 0 && lat_errors == 0)
                    $display("PASS tb_gauss_noise: all %0d noise samples match the Python model, raw_valid is exactly %0d clocks after step", N, LATENCY);
                else
                    $display("FAIL tb_gauss_noise: %0d mismatches, %0d valid-timing errors", errors, lat_errors);
                $finish;
            end
        end
    end

    initial begin
        #20000000;
        $display("FAIL tb_gauss_noise: timeout (got %0d of %0d samples)", got, N);
        $finish;
    end
endmodule
