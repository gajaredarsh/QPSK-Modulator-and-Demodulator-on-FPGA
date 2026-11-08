// bin2bcd14.v  (Part D)
// Sequential double-dabble: converts a 14-bit value (0..9999 after saturation) to 4 BCD digits.
// Runs continuously; `bcd` updates every ~16 clocks. Used only for the display, so latency does not matter.
module bin2bcd14 (
    input  wire        clk,
    input  wire        rst,
    input  wire [13:0] bin,
    output reg  [15:0] bcd
);
    reg [13:0] sh;
    reg [15:0] acc;
    reg [4:0]  n;
    reg        busy;

    function [15:0] add3;
        input [15:0] v;
        begin
            add3[3:0]   = (v[3:0]   >= 5) ? v[3:0]   + 4'd3 : v[3:0];
            add3[7:4]   = (v[7:4]   >= 5) ? v[7:4]   + 4'd3 : v[7:4];
            add3[11:8]  = (v[11:8]  >= 5) ? v[11:8]  + 4'd3 : v[11:8];
            add3[15:12] = (v[15:12] >= 5) ? v[15:12] + 4'd3 : v[15:12];
        end
    endfunction

    wire [15:0] adj = add3(acc);

    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0; n <= 0; acc <= 0; sh <= 0; bcd <= 0;
        end else if (!busy) begin
            sh <= bin; acc <= 0; n <= 0; busy <= 1'b1;
        end else begin
            acc <= {adj[14:0], sh[13]};
            sh  <= {sh[12:0], 1'b0};
            n   <= n + 1'b1;
            if (n == 5'd13) begin
                bcd  <= {adj[14:0], sh[13]};
                busy <= 1'b0;
            end
        end
    end
endmodule
