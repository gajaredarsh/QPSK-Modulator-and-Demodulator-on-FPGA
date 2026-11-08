`include "qpsk_params.vh"
`include "qpsk_rx_params.vh"

module qpsk_top #(
    parameter COS_FILE  = "lut_cos.hex",
    parameter SIN_FILE  = "lut_sin.hex",
    parameter COEF_FILE = "fir_coeffs.hex",
    parameter SNAP_BITS = 24,           // LED snapshot period = 2^SNAP_BITS clocks (~0.17 s at 100 MHz)
    parameter REFRESH_BITS = 17         // 7-seg digit scan period = 2^REFRESH_BITS clocks (lower only in simulation)
)(
    input  wire        clk,
    input  wire        reset_btn,
    input  wire [3:0]  noise_switches,
    input  wire        noise_off_switch,
    input  wire        mode_sw,         // 1 = send the 8-bit pattern from pat_sw, 0 = PRBS (latched while reset is held)
    input  wire [7:0]  pat_sw,          // user pattern, 4 QPSK symbols (latched while reset is held)
    output wire [15:0] led,             // [7:0] received pattern, [15:8] error mask (1 = bit in error)
    output wire [3:0]  D0_AN,           // bank 0: noise setting
    output wire [7:0]  D0_SEG,
    output wire [3:0]  D1_AN,           // bank 1: error-bit count (decimal, saturates at 9999)
    output wire [7:0]  D1_SEG,
    output wire        uart_tx_pin
);

    // Synchronize external controls to the FPGA clock.
    (* ASYNC_REG = "TRUE" *) reg reset_meta = 1'b1;
    (* ASYNC_REG = "TRUE" *) reg rst = 1'b1;

    (* ASYNC_REG = "TRUE" *) reg [3:0] level_meta = 0;
    (* ASYNC_REG = "TRUE" *) reg [3:0] level = 0;

    (* ASYNC_REG = "TRUE" *) reg off_meta = 1'b1;
    (* ASYNC_REG = "TRUE" *) reg noise_off = 1'b1;

    // Pattern controls: sampled continuously while reset is held, frozen once reset is released.
    (* ASYNC_REG = "TRUE" *) reg [8:0] pat_meta = 0;
    (* ASYNC_REG = "TRUE" *) reg [8:0] pat_sync = 0;
    reg [7:0] pat_r = 8'h00;
    reg       pat_en_r = 1'b0;

    always @(posedge clk) begin
        pat_meta <= {mode_sw, pat_sw};
        pat_sync <= pat_meta;
        if (rst) begin
            pat_r    <= pat_sync[7:0];
            pat_en_r <= pat_sync[8];
        end
    end

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
        .sym_stb(),
        .pat_en(pat_en_r),
        .pat(pat_r)
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
        .pat_en(pat_en_r),
        .pat(pat_r),
        .total_bits(total_bits),
        .error_bits(error_bits)
    );

    // ---- Pattern mode: capture the decoded 8-bit word and show it on the LEDs ----
    reg [1:0] ridx;
    reg [7:0] rx_word;
    reg [SNAP_BITS-1:0] snap_cnt;
    reg [7:0] snap_word;

    always @(posedge clk) begin
        if (rst) begin
            ridx <= 2'd0; rx_word <= 8'h00; snap_cnt <= 0; snap_word <= 8'h00;
        end else begin
            if (bits_valid) begin
                ridx <= ridx + 1'b1;
                rx_word[{ridx, 1'b0}] <= rx_bits[1];      // b0 (I bit)
                rx_word[{ridx, 1'b1}] <= rx_bits[0];      // b1 (Q bit)
            end
            snap_cnt <= snap_cnt + 1'b1;
            if (&snap_cnt) snap_word <= rx_word;
        end
    end

    assign led = pat_en_r ? {snap_word ^ pat_r, snap_word} : 16'h0000;

    // ---- Seven-segment displays ----
    // Bank 0: "<level>d" (e.g. " 12d" = 12 dB), or "0FF" when the noise is switched off.
    wire [3:0] tens = (level >= 4'd10) ? 4'd1 : 4'hA;
    wire [3:0] ones = (level >= 4'd10) ? (level - 4'd10) : level;
    wire [15:0] bank0 = noise_off ? {4'hA, 4'd0, 4'hC, 4'hC}
                                  : {4'hA, tens, ones, 4'hB};

    // Bank 1: error-bit count in decimal, saturating at 9999.
    wire [13:0] err_sat = (error_bits > 32'd9999) ? 14'd9999 : error_bits[13:0];
    wire [15:0] err_bcd;
    bin2bcd14 u_bcd (.clk(clk), .rst(rst), .bin(err_sat), .bcd(err_bcd));

    seg7_display #(.REFRESH_BITS(REFRESH_BITS)) u_seg0 (.clk(clk), .rst(1'b0), .digits(bank0),   .an(D0_AN), .seg(D0_SEG));
    seg7_display #(.REFRESH_BITS(REFRESH_BITS)) u_seg1 (.clk(clk), .rst(1'b0), .digits(err_bcd), .an(D1_AN), .seg(D1_SEG));

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