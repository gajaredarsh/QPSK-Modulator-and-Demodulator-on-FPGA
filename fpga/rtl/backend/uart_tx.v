// UART 8N1: one start bit, eight data bits LSB-first, one stop bit.
// data: unsigned 8-bit byte. No direct Python signal-processing mirror.
// Acceptance: valid && ready. Completion: 10 * CLKS_PER_BIT clocks.
// Reset: synchronous active-high; serial output idles high.
module uart_tx #(
    parameter integer CLK_HZ = 100_000_000,
    parameter integer BAUD   = 115200
)(
    input  wire       clk,
    input  wire       rst,
    input  wire [7:0] data,
    input  wire       valid,
    output wire       ready,
    output wire       tx
);

    localparam integer CLKS_PER_BIT =
        (CLK_HZ + BAUD / 2) / BAUD;

    localparam integer CW =
        (CLKS_PER_BIT <= 1) ? 1 : $clog2(CLKS_PER_BIT);

    reg [CW-1:0] count;
    reg [3:0] bit_index;
    reg [9:0] frame;
    reg busy;

    assign ready = !busy;
    assign tx = busy ? frame[0] : 1'b1;

    always @(posedge clk) begin
        if (rst) begin
            count     <= 0;
            bit_index <= 0;
            frame     <= 10'h3FF;
            busy      <= 1'b0;
        end else if (!busy) begin
            if (valid) begin
                frame     <= {1'b1, data, 1'b0};
                count     <= 0;
                bit_index <= 0;
                busy      <= 1'b1;
            end
        end else if (count == CLKS_PER_BIT - 1) begin
            count <= 0;

            if (bit_index == 9) begin
                busy <= 1'b0;
            end else begin
                frame     <= {1'b1, frame[9:1]};
                bit_index <= bit_index + 1'b1;
            end
        end else begin
            count <= count + 1'b1;
        end
    end

endmodule