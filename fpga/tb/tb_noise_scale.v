// tb_noise_scale.v  (Part B)
// Checks noise_scale against vectors/scale_exp_all.hex (channel.noise_int) for four gains:
// 0 (no noise), 2902 (6 dB), 5790 (0 dB) and 8191 (the largest value the gain register can hold).
// Run from the tb folder, so that the ../vectors path works.
`timescale 1ns/1ps
`include "qpsk_params.vh"

module tb_noise_scale;
    localparam NS = 4096;
    localparam NRAW = 70000;                       // length of vectors/noise_raw.hex
    localparam NG = 4;

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;
    reg                               raw_valid = 1'b0;
    reg  signed [`NOISE_RAW_BITS-1:0] raw       = 0;
    reg         [`NOISE_GAIN_BITS-1:0] gain     = 0;
    wire signed [`NOISE_BITS-1:0]     noise;
    wire                              noise_valid;

    noise_scale dut (.clk(clk), .rst(rst), .raw_valid(raw_valid), .raw(raw), .gain(gain),
                     .noise(noise), .noise_valid(noise_valid));

    reg [`NOISE_RAW_BITS-1:0]   raw_mem   [0:NRAW-1];
    reg [`NOISE_BITS-1:0]       exp_mem   [0:NG*NS-1];
    reg [`NOISE_GAIN_BITS-1:0]  gains_mem [0:NG-1];
    integer t, sent, got, base, errors, seed, lat_errors;
    localparam LATENCY = 2;                       // clocks from raw_valid to noise_valid
    reg [LATENCY-1:0] vpipe;

    // valid timing: noise_valid must be exactly raw_valid delayed by LATENCY clocks
    always @(posedge clk) begin
        if (rst) vpipe <= 0;
        else begin
            vpipe <= {vpipe[LATENCY-2:0], raw_valid};
            if (noise_valid !== vpipe[LATENCY-1]) lat_errors = lat_errors + 1;
        end
    end

    // checker
    always @(posedge clk) begin
        if (!rst && noise_valid) begin
            if (noise !== exp_mem[base + got]) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("MISMATCH gain %0d sample %0d: got %0d, expected %0d",
                             gain, got, noise, $signed(exp_mem[base + got]));
            end
            got = got + 1;
        end
    end

    initial begin
        $readmemh("../vectors/noise_raw.hex", raw_mem);
        $readmemh("../vectors/scale_exp_all.hex", exp_mem);
        $readmemh("../vectors/scale_gains.hex", gains_mem);
        errors = 0; lat_errors = 0; seed = 3; got = 0; base = 0;

        for (t = 0; t < NG; t = t + 1) begin
            rst <= 1'b1; raw_valid <= 1'b0;
            gain <= gains_mem[t];
            repeat (3) @(posedge clk);
            got = 0; base = t * NS;                  // still in reset, nothing is being checked
            rst <= 1'b0;
            sent = 0;
            while (sent < NS) begin
                @(posedge clk);
                if (($random(seed) & 3) != 0) begin
                    raw_valid <= 1'b1;
                    raw       <= raw_mem[sent];
                    sent = sent + 1;
                end else
                    raw_valid <= 1'b0;
            end
            @(posedge clk);
            raw_valid <= 1'b0;
            repeat (10) @(posedge clk);              // let the pipeline empty
            if (got != NS) begin
                errors = errors + 1;
                $display("gain %0d: got %0d outputs, expected %0d", gains_mem[t], got, NS);
            end else
                $display("  gain %5d: %0d samples checked", gains_mem[t], NS);
        end

        if (errors == 0 && lat_errors == 0)
            $display("PASS tb_noise_scale: all gains match the Python model, noise_valid is exactly %0d clocks after raw_valid", LATENCY);
        else
            $display("FAIL tb_noise_scale: %0d value errors, %0d valid-timing errors", errors, lat_errors);
        $finish;
    end

    initial begin
        #50000000;
        $display("FAIL tb_noise_scale: timeout");
        $finish;
    end
endmodule
