`timescale 1ns / 1ps
`include "qpsk_params.vh"
`include "qpsk_rx_params.vh"

module tb_qpsk;
    localparam integer N_COMPARE = 50_000;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    wire signed [`MIXER_OUT_BITS-1:0] s_tx;
    wire tx_valid;

    wire signed [`RXC_X_BITS-1:0] r_rx;
    wire channel_valid;

    wire signed [`RXC_ACC_BITS-1:0] i_hat, q_hat;
    wire sym_valid;

    wire [1:0] rx_bits;
    wire bits_valid;
    wire [31:0] total_bits, error_bits;
    reg seen_first = 1'b0;

    tx_top tx (
        .clk(clk),
        .rst(rst),
        .sample_en(~rst),
        .s_out(s_tx),
        .s_stb(tx_valid),
        .tx_bits(),
        .sym_stb(),
        .pat_en(1'b0),
        .pat(8'h00)
    );

    awgn_channel channel (
        .clk(clk),
        .rst(rst),
        .in_valid(tx_valid),
        .s_tx(s_tx),
        .level(4'd12),
        .noise_off(1'b0),
        .out_valid(channel_valid),
        .r_rx(r_rx),
        .wide()
    );

    rx_frontend_top rx (
        .clk(clk),
        .rst(rst),
        .in_valid(channel_valid),
        .r_rx(r_rx),
        .xi(), .xq(), .x_valid(),
        .y_i(), .y_q(), .y_valid(),
        .i_hat(i_hat),
        .q_hat(q_hat),
        .sym_valid(sym_valid)
    );

    symbol_decision #(.W(`RXC_ACC_BITS)) decision (
        .clk(clk),
        .rst(rst),
        .symbol_en(sym_valid),
        .i_symbol(i_hat),
        .q_symbol(q_hat),
        .bits_out(rx_bits),
        .bits_valid(bits_valid)
    );

    always @(posedge clk) begin
        if (rst)
            seen_first <= 1'b0;
        else if (bits_valid)
            seen_first <= 1'b1;
    end

    ber_counter #(.START_SYMBOL(0)) ber (
        .clk(clk),
        .rst(rst),
        .clear(1'b0),
        .rx_valid(bits_valid),
        .compare_en(seen_first),
        .rx_bits(rx_bits),
        .pat_en(1'b0),
        .pat(8'h00),
        .total_bits(total_bits),
        .error_bits(error_bits)
    );

    initial begin
        repeat (5) @(negedge clk);
        rst = 1'b0;

        wait (total_bits == 2 * N_COMPARE);
        @(negedge clk);

        $display("Eb/N0 = 4 dB: errors=%0d, bits=%0d, BER=%f",
                 error_bits, total_bits,
                 $itor(error_bits) / $itor(total_bits));

        $finish;
    end
    integer constellation_file;

initial begin
    constellation_file = $fopen("constellation.csv", "w");
    if (constellation_file == 0) begin
        $display("FAIL: Cannot create constellation.csv");
        $finish;
    end
    $fwrite(constellation_file, "I,Q\n");
end

always @(posedge clk) begin
    if (!rst && sym_valid)
        $fwrite(constellation_file, "%0d,%0d\n",
                $signed(i_hat), $signed(q_hat));
end
wire snapshot_ready;
wire [7:0] uart_data;
wire uart_valid;
wire uart_ready;
wire uart_tx_pin;

packetizer #(.W(`RXC_ACC_BITS)) packet (
    .clk(clk),
    .rst(rst),
    .snapshot_en(sym_valid && snapshot_ready),
    .snapshot_ready(snapshot_ready),
    .i_symbol(i_hat),
    .q_symbol(q_hat),
    .total_bits(total_bits),
    .error_bits(error_bits),
    .noise_level(8'd4),
    .byte_data(uart_data),
    .byte_valid(uart_valid),
    .byte_ready(uart_ready)
);

uart_tx #(
    .CLK_HZ(100_000_000),
    .BAUD(115200)
) serial_tx (
    .clk(clk),
    .rst(rst),
    .data(uart_data),
    .valid(uart_valid),
    .ready(uart_ready),
    .tx(uart_tx_pin)
);
endmodule