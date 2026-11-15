// Tests gauss_noise against the Python reference vectors using 70000 samples.
// This checks the LFSR sequence, including its wraparound after 65535 samples.
// Random gaps are added between step pulses to check that noise advances only on step.
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
    localparam LATENCY = 2;                       // Number of clocks from step to output
    reg [LATENCY-1:0] vpipe;                      // Stores the delayed step signal

    // Check that raw_valid has the correct delay
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

    // Generate step pulses with random gaps
    always @(posedge clk) begin
        if (rst)
            step <= 1'b0;
        else if (sent < N && (($random(seed) & 3) != 0)) begin
            step <= 1'b1;
            sent <= sent + 1;
        end else
            step <= 1'b0;
    end

    // Compare generated noise with the expected values
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
