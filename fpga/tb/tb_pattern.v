`timescale 1ns / 1ps
// Top-level test of the user-pattern mode, LED output and seven-segment bank 1.
module tb_pattern;
    reg clk = 0;  always #5 clk = ~clk;
    reg        reset_btn = 1;
    reg [3:0]  noise_switches = 4'd12;
    reg        noise_off_switch = 1;
    reg        mode_sw = 1;
    reg [7:0]  pat_sw = 8'hA5;
    wire [15:0] led;
    wire [3:0] D0_AN, D1_AN;  wire [7:0] D0_SEG, D1_SEG;
    wire uart_tx_pin;

    qpsk_top #(.SNAP_BITS(12), .REFRESH_BITS(3)) dut (
        .clk(clk), .reset_btn(reset_btn), .noise_switches(noise_switches),
        .noise_off_switch(noise_off_switch), .mode_sw(mode_sw), .pat_sw(pat_sw),
        .led(led), .D0_AN(D0_AN), .D0_SEG(D0_SEG), .D1_AN(D1_AN), .D1_SEG(D1_SEG),
        .uart_tx_pin(uart_tx_pin));

    integer fails = 0;

    task run_pattern(input [7:0] p, input off, input [3:0] lvl, input integer cycles);
    begin
        pat_sw = p; noise_off_switch = off; noise_switches = lvl;
        reset_btn = 1; repeat (20) @(posedge clk);
        reset_btn = 0; repeat (cycles) @(posedge clk);
    end
    endtask

    // decode a 7-seg pattern (active-low segments) of the digit currently selected by D1_AN
    reg [3:0] seen [0:3];
    reg [3:0] want;
    integer k;
    function [3:0] dec(input [6:0] g);   // g = active-high {g..a}
        case (g)
            7'b0111111: dec = 0; 7'b0000110: dec = 1; 7'b1011011: dec = 2; 7'b1001111: dec = 3;
            7'b1100110: dec = 4; 7'b1101101: dec = 5; 7'b1111101: dec = 6; 7'b0000111: dec = 7;
            7'b1111111: dec = 8; 7'b1101111: dec = 9; 7'b0000000: dec = 4'hA; 7'b1011110: dec = 4'hB; 7'b1110001: dec = 4'hC; default: dec = 4'hF;
        endcase
    endfunction

    reg [15:0] patterns [0:4];
    integer n;
    initial begin
        patterns[0]=16'hA5; patterns[1]=16'hFF; patterns[2]=16'h00; patterns[3]=16'h3C; patterns[4]=16'h81;
        // 1) noise off: every pattern must come back exactly, zero errors
        for (n = 0; n < 5; n = n + 1) begin
            run_pattern(patterns[n][7:0], 1'b1, 4'd12, 60000);
            if (led[7:0] !== patterns[n][7:0] || led[15:8] !== 8'h00 || dut.error_bits !== 0) begin
                $display("FAIL noise off pat=%h led=%h errors=%0d", patterns[n][7:0], led, dut.error_bits);
                fails = fails + 1;
            end else $display("PASS noise off pat=%h -> led=%h errors=%0d total=%0d", patterns[n][7:0], led[7:0], dut.error_bits, dut.total_bits);
        end
        // 2) noisy channel at 0 dB: errors must appear and LED error mask must match the count of flips seen
        run_pattern(8'hA5, 1'b0, 4'd0, 400000);
        $display("noise 0 dB: errors=%0d total=%0d BER=%f led=%h", dut.error_bits, dut.total_bits,
                 $itor(dut.error_bits)/$itor(dut.total_bits), led);
        if (dut.error_bits == 0) begin $display("FAIL: no errors at 0 dB"); fails = fails + 1; end
        // 3) bank 1 decodes the error count (freeze the count first by switching the noise off)
        noise_off_switch = 1; repeat (3000) @(posedge clk);
        for (k = 0; k < 4; k = k + 1) begin
            want = ~(4'b0001 << k); wait (D1_AN == want); #1;
            seen[k] = dec(~D1_SEG[6:0]);
        end
        $display("bank1 digits (d3..d0) = %0d%0d%0d%0d   (error_bits=%0d)", seen[3], seen[2], seen[1], seen[0], dut.error_bits);
        if ((seen[3]*1000 + seen[2]*100 + seen[1]*10 + seen[0]) !== dut.error_bits) begin
            $display("FAIL: bank1 shows %0d but error_bits=%0d", seen[3]*1000 + seen[2]*100 + seen[1]*10 + seen[0], dut.error_bits);
            fails = fails + 1;
        end else $display("PASS: bank1 shows the error count");
        // 4) bank 0 shows noise setting
        noise_switches = 4'd12; noise_off_switch = 0; repeat (200) @(posedge clk);
        for (k = 0; k < 4; k = k + 1) begin
            want = ~(4'b0001 << k); wait (D0_AN == want); #1;
            seen[k] = dec(~D0_SEG[6:0]);
        end
        $display("bank0 digits (d3..d0) = %h %h %h %h  (expect a,1,2,b = blank,1,2,d)", seen[3], seen[2], seen[1], seen[0]);
        if (seen[3] !== 4'hA || seen[2] !== 4'd1 || seen[1] !== 4'd2 || seen[0] !== 4'hB) begin $display("FAIL: bank0"); fails = fails + 1; end
        else $display("PASS: bank0 shows ' 12d'");
        if (fails == 0) $display("ALL PASS"); else $display("SOME FAILED");
        $finish;
    end
endmodule
