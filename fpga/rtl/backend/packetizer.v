`include "qpsk_rx_params.vh"

// Serializes a coherent measurement snapshot.
// I/Q: signed W bits, sign-extended to whole bytes.
// Counters: unsigned 32 bits; noise_level: unsigned 8-bit setting.
// No direct Python DSP mirror; host decoder implements the inverse.
// snapshot_en && snapshot_ready accepts a snapshot.
// First output byte becomes valid after the accepting edge.
// Total latency depends on downstream byte_ready.
module packetizer #(
    parameter integer W = `RXC_ACC_BITS
)(
    input  wire                clk,
    input  wire                rst,
    input  wire                snapshot_en,
    output wire                snapshot_ready,

    input  wire signed [W-1:0] i_symbol,
    input  wire signed [W-1:0] q_symbol,
    input  wire [31:0]         total_bits,
    input  wire [31:0]         error_bits,
    input  wire [7:0]          noise_level,

    output wire [7:0]          byte_data,
    output wire                byte_valid,
    input  wire                byte_ready
);

    localparam integer IQ_BYTES = (W + 7) / 8;
    localparam integer PAD_W = 8 * IQ_BYTES;
    localparam integer PAYLOAD_BYTES = 2 * IQ_BYTES + 9;
    localparam integer PACKET_BYTES = PAYLOAD_BYTES + 3;
    localparam integer INDEX_W = $clog2(PACKET_BYTES);

    wire [PAD_W-1:0] i_padded =
        {{(PAD_W-W){i_symbol[W-1]}}, i_symbol};

    wire [PAD_W-1:0] q_padded =
        {{(PAD_W-W){q_symbol[W-1]}}, q_symbol};

    // Lowest byte is sent first.
    wire [8*PAYLOAD_BYTES-1:0] payload = {
        noise_level, error_bits, total_bits, q_padded, i_padded
    };

    reg [7:0] checksum;
    integer k;

    always @* begin
        checksum = 8'h00;
        for (k = 0; k < PAYLOAD_BYTES; k = k + 1)
            checksum = checksum ^ payload[8*k +: 8];
    end

    reg [8*PACKET_BYTES-1:0] packet;
    reg [INDEX_W-1:0] index;
    reg busy;

    assign snapshot_ready = !busy;
    assign byte_valid = busy;
    assign byte_data = packet[7:0];

    always @(posedge clk) begin
        if (rst) begin
            packet <= 0;
            index  <= 0;
            busy   <= 1'b0;
        end else if (!busy) begin
            if (snapshot_en) begin
                packet <= {checksum, payload, 8'h5A, 8'hA5};
                index  <= 0;
                busy   <= 1'b1;
            end
        end else if (byte_ready) begin
            if (index == PACKET_BYTES - 1) begin
                busy <= 1'b0;
            end else begin
                packet <= packet >> 8;
                index  <= index + 1'b1;
            end
        end
    end

endmodule