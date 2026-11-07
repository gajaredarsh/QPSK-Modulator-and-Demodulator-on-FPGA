`include "qpsk_params.vh"
`include "qpsk_rx_params.vh"

module qpsk_top #(
    parameter COS_FILE  = "lut_cos.hex",
    parameter SIN_FILE  = "lut_sin.hex",
    parameter COEF_FILE = "fir_coeffs.hex"
)(
    input  wire       clk,
    input  wire       reset_btn,
    input  wire [3:0]  noise_switches,
    input  wire       noise_off_switch,
    output wire       uart_tx_pin
);

    // Synchronize external controls to the FPGA clock.
    (* ASYNC_REG = "TRUE" *) reg reset_meta = 1'b1;
    (* ASYNC_REG = "TRUE" *) reg rst = 1'b1;

    (* ASYNC_REG = "TRUE" *) reg [3:0] level_meta = 0;
    (* ASYNC_REG = "TRUE" *) reg [3:0] level = 0;

    (* ASYNC_REG = "TRUE" *) reg off_meta = 1'b1;
    (* ASYNC_REG = "TRUE" *) reg noise_off = 1'b1;

    always @(posedge clk) begin
        reset_meta <= reset_btn;
        rst <= reset_meta;

        level_meta <= noise_switches;
        level <= level_meta;

        off_meta <= noise_off_switch;
        noise_off <= off_meta;
    end

    wire signed [`MIXER_OUT_BITS-1:0] s_tx;
    wire tx_valid;

    wire signed [`RXC_X_BITS-1:0] r_rx;
    wire channel_valid;

    wire signed [`RXC_ACC_BITS-1:0] i_hat;
    wire signed [`RXC_ACC_BITS-1:0] q_hat;
    wire sym_valid;

    wire [1:0] rx_bits;
    wire bits_valid;
    wire [31:0] total_bits;
    wire [31:0] error_bits;

    reg seen_first;

    tx_top #(
        .COS_FILE(COS_FILE),
        .SIN_FILE(SIN_FILE)
    ) tx (
        .clk(clk),
        .rst(rst),
        .sample_en(~rst),
        .s_out(s_tx),
        .s_stb(tx_valid),
        .tx_bits(),
        .sym_stb()
    );

    awgn_channel channel (
        .clk(clk),
        .rst(rst),
        .in_valid(tx_valid),
        .s_tx(s_tx),
        .level(level),
        .noise_off(noise_off),
        .out_valid(channel_valid),
        .r_rx(r_rx),
        .wide()
    );

    rx_frontend_top #(
        .COS_FILE(COS_FILE),
        .SIN_FILE(SIN_FILE),
        .COEF_FILE(COEF_FILE)
    ) rx (
        .clk(clk),
        .rst(rst),
        .in_valid(channel_valid),
        .r_rx(r_rx),
        .xi(),
        .xq(),
        .x_valid(),
        .y_i(),
        .y_q(),
        .y_valid(),
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
        .total_bits(total_bits),
        .error_bits(error_bits)
    );

    wire snapshot_ready;
    wire [7:0] uart_data;
    wire uart_valid;
    wire uart_ready;

    packetizer #(.W(`RXC_ACC_BITS)) packet (
        .clk(clk),
        .rst(rst),
        .snapshot_en(sym_valid && snapshot_ready),
        .snapshot_ready(snapshot_ready),
        .i_symbol(i_hat),
        .q_symbol(q_hat),
        .total_bits(total_bits),
        .error_bits(error_bits),
        .noise_level({4'b0000, level}),
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