// tb_awgn_channel.v  (Part B)
// Checks the top level channel block:
//   1. the gain ROM against vectors/noise_gain_table.hex (exported by channel.export_noise_vectors)
//   2. all 16 level settings (0..15 dB) against channel.awgn_int, 2000 samples each
//   3. noise_off = 1, both against Python and against (s_tx + 4) >>> 3 computed right here
// Run from the tb folder, so that the ../vectors path works.
`timescale 1ns/1ps
`include "qpsk_params.vh"

module tb_awgn_channel;
    localparam MC   = 2000;
    localparam MIN  = 16000;                       // length of vectors/core_in.hex
    localparam NSET = 17;                          // 16 levels + noise_off

    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;
    reg                                  in_valid  = 1'b0;
    reg  signed [`TX_BITS-1:0]           s_tx      = 0;
    reg         [`NOISE_LEVEL_BITS-1:0]  level     = 0;
    reg                                  noise_off = 1'b0;
    wire                                 out_valid;
    wire signed [`RX_BITS-1:0]           r_rx;
    wire signed [`SUM_BITS-1:0]          wide;

    awgn_channel dut (.clk(clk), .rst(rst), .in_valid(in_valid), .s_tx(s_tx),
                      .level(level), .noise_off(noise_off),
                      .out_valid(out_valid), .r_rx(r_rx), .wide(wide));

    reg [`TX_BITS-1:0]         in_mem  [0:MIN-1];
    reg [`RX_BITS-1:0]         exp_r   [0:NSET*MC-1];
    reg [`NOISE_GAIN_BITS-1:0] tbl_mem [0:`NOISE_LEVELS-1];
    integer t, l, sent, got, base, errors, rom_errors, off_errors, seed;
    reg signed [31:0] calc;

    always @(posedge clk) begin
        if (!rst && out_valid) begin
            if (r_rx !== exp_r[base + got]) begin
                errors = errors + 1;
                if (errors <= 10)
                    $display("MISMATCH set %0d sample %0d: got %0d, expected %0d", t, got, r_rx, $signed(exp_r[base + got]));
            end
            if (noise_off) begin
                calc = ($signed(in_mem[got]) + 4) >>> `TX_TO_RX_SHIFT;
                if (r_rx !== calc[`RX_BITS-1:0]) off_errors = off_errors + 1;
            end
            got = got + 1;
        end
    end

    initial begin
        $readmemh("../vectors/core_in.hex", in_mem);
        $readmemh("../vectors/chan_r12_all.hex", exp_r);
        $readmemh("../vectors/noise_gain_table.hex", tbl_mem);
        errors = 0; rom_errors = 0; off_errors = 0; seed = 5; got = 0; base = 0;

        // 1. the ROM
        for (l = 0; l < `NOISE_LEVELS; l = l + 1) begin
            level = l;
            #1;
            if (dut.rom_gain !== tbl_mem[l]) begin
                rom_errors = rom_errors + 1;
                $display("ROM level %0d: got %0d, expected %0d", l, dut.rom_gain, tbl_mem[l]);
            end
        end
        $display("  gain ROM: %0d entries checked", `NOISE_LEVELS);

        // 2. and 3. the whole block
        for (t = 0; t < NSET; t = t + 1) begin
            rst <= 1'b1; in_valid <= 1'b0;
            if (t < `NOISE_LEVELS) begin level <= t; noise_off <= 1'b0; end
            else                   begin level <= 0; noise_off <= 1'b1; end
            repeat (3) @(posedge clk);
            got = 0; base = t * MC;
            rst <= 1'b0;
            sent = 0;
            while (sent < MC) begin
                @(posedge clk);
                if (($random(seed) & 3) != 0) begin
                    in_valid <= 1'b1;
                    s_tx     <= in_mem[sent];
                    sent = sent + 1;
                end else
                    in_valid <= 1'b0;
            end
            @(posedge clk);
            in_valid <= 1'b0;
            repeat (12) @(posedge clk);
            if (got != MC) begin
                errors = errors + 1;
                $display("set %0d: got %0d outputs, expected %0d", t, got, MC);
            end
        end
        $display("  %0d level settings + noise_off checked, %0d samples each", `NOISE_LEVELS, MC);

        if (errors == 0 && rom_errors == 0 && off_errors == 0)
            $display("PASS tb_awgn_channel: ROM, all levels and noise_off match");
        else
            $display("FAIL tb_awgn_channel: %0d value errors, %0d ROM errors, %0d noise_off errors", errors, rom_errors, off_errors);
        $finish;
    end

    initial begin
        #100000000;
        $display("FAIL tb_awgn_channel: timeout");
        $finish;
    end
endmodule
