`timescale 1ns / 1ps
`include "qpsk_rx_params.vh"

module tb_uart;
    localparam integer W = `RXC_ACC_BITS;
    localparam integer CLK_HZ = 100_000_000;
    localparam integer BAUD = 115200;
    localparam integer BIT_NS = 10 * ((CLK_HZ + BAUD/2) / BAUD);

    // Header | I=1234 | Q=FFFE | total=8 | errors=2 | noise=3 | XOR=2E
    localparam [127:0] EXPECTED =
        128'hA55A_3412_FEFF_08000000_02000000_03_2E;

    reg clk, rst, snapshot_en;
    reg signed [W-1:0] i_symbol, q_symbol;
    wire snapshot_ready, byte_valid, byte_ready, tx;
    wire [7:0] byte_data;
    reg [7:0] received;
    integer index;

    always #5 clk = ~clk;

    packetizer #(.W(W)) packet (
        .clk(clk), .rst(rst), .snapshot_en(snapshot_en),
        .snapshot_ready(snapshot_ready),
        .i_symbol(i_symbol), .q_symbol(q_symbol),
        .total_bits(32'd8), .error_bits(32'd2), .noise_level(8'd3),
        .byte_data(byte_data), .byte_valid(byte_valid),
        .byte_ready(byte_ready)
    );

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) uart (
        .clk(clk), .rst(rst), .data(byte_data), .valid(byte_valid),
        .ready(byte_ready), .tx(tx)
    );

    task receive_byte;
        output [7:0] value;
        integer bit_index;
        begin
            @(negedge tx);
            #(BIT_NS / 2);
            if (tx !== 1'b0) begin
                $display("FAIL: Bad UART start bit");
                $finish;
            end

            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                #(BIT_NS);
                value[bit_index] = tx;
            end

            #(BIT_NS);
            if (tx !== 1'b1) begin
                $display("FAIL: Bad UART stop bit");
                $finish;
            end
        end
    endtask

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        snapshot_en = 1'b0;
        i_symbol = 16'sh1234;
        q_symbol = -2;

        if (W != 16) begin
            $display("FAIL: Expected packet assumes 16-bit I/Q");
            $finish;
        end

        repeat (2) @(posedge clk);
        #1;
        if (tx !== 1'b1 || snapshot_ready !== 1'b1) begin
            $display("FAIL: UART or packetizer failed to idle after reset");
            $finish;
        end

        @(negedge clk);
        rst = 1'b0;
        snapshot_en = 1'b1;

        fork
            begin
                @(negedge clk);
                snapshot_en = 1'b0;
                i_symbol = 0;
                q_symbol = 0;
            end
            begin
                for (index = 0; index < 16; index = index + 1) begin
                    receive_byte(received);
                    if (received !== EXPECTED[127-8*index -: 8]) begin
                        $display("FAIL: Packet byte %0d expected %02h got %02h",
                                 index, EXPECTED[127-8*index -: 8], received);
                        $finish;
                    end
                end
            end
        join

        #(BIT_NS);
        if (snapshot_ready !== 1'b1 || byte_valid !== 1'b0 ||
            byte_ready !== 1'b1 || tx !== 1'b1) begin
            $display("FAIL: Packetizer or UART did not return to idle");
            $finish;
        end

        $display("PASS: Part D packetizer and UART");
        $finish;
    end

    initial begin
        #2_000_000;
        $display("FAIL: Timeout waiting for UART packet");
        $finish;
    end
endmodule