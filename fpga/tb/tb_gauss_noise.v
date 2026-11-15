// Compares gauss_noise with Python reference values over 70000 samples.
// Checks the LFSR sequence and its wraparound after 65535 samples.
// Random gaps between step pulses check that noise changes only on step.
// Run from the tb folder so the ../vectors path works.
`timescale 1ns/1ps
`include "qpsk_params.vh"

module tb_gauss_noise;
    localparam N = 70000;

    reg clk = 1'b0;
    always #5 clk = ~clk;                       // 100 MHz clock
    reg rst  = 1'b1;
    reg step = 1'b0;
    wire signed [`NOISE_RAW_BITS-1:0] raw;
    wire                              raw_valid;

    gauss_noise dut (.clk(clk), .rst(rst), .step(step), .raw(raw), .raw_valid(raw_valid));

    reg [`NOISE_RAW_BITS-1:0] exp_mem [0:N-1];
    integer sent, got, errors, seed, lat_errors;
    localparam LATENCY = 2;                       // Delay from step to output
    reg [LATENCY-1:0] vpipe;                      // Stores delayed step signals

    // Checks the delay of raw_valid
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

    // Sends step pulses with random gaps
    always @(posedge clk) begin
        if (rst)
            step <= 1'b0;
        else if (sent < N && (($random(seed) & 3) != 0)) begin
            step <= 1'b1;
            sent <= sent + 1;
        end else
            step <= 1'b0;
    end

    // Compares generated noise with the reference values
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
