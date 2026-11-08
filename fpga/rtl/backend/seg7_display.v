// seg7_display.v  (Part D)
// Drives one 4-digit multiplexed seven-segment bank (the board has two).
// Digit codes (4 bits each, d0 = rightmost digit):
//   0-9 = decimal digit, 4'hA = blank, 4'hB = 'd', 4'hC = 'F', 4'hD = 'n', 4'hE = 'E', 4'hF = '-'
// Polarity: set SEG_ACTIVE_LOW / AN_ACTIVE_LOW to match the board. The Boolean board is
// believed to use active-low anodes and cathodes; if the display looks inverted, flip the parameters.
// seg[6:0] = {g,f,e,d,c,b,a}, seg[7] = decimal point (always off).
module seg7_display #(
    parameter SEG_ACTIVE_LOW = 1,
    parameter AN_ACTIVE_LOW  = 1,
    parameter REFRESH_BITS   = 17          // 100 MHz / 2^17 = ~760 Hz per digit step
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [15:0] digits,             // {d3, d2, d1, d0}
    output wire [3:0]  an,
    output wire [7:0]  seg
);
    reg [REFRESH_BITS+1:0] cnt = 0;
    always @(posedge clk) cnt <= rst ? {(REFRESH_BITS+2){1'b0}} : cnt + 1'b1;
    wire [1:0] sel = cnt[REFRESH_BITS+1:REFRESH_BITS];

    reg [3:0] code;
    always @* case (sel)
        2'd0: code = digits[3:0];
        2'd1: code = digits[7:4];
        2'd2: code = digits[11:8];
        default: code = digits[15:12];
    endcase

    reg [6:0] g;                           // active-high {g,f,e,d,c,b,a}
    always @* case (code)
        4'd0: g = 7'b0111111;  4'd1: g = 7'b0000110;
        4'd2: g = 7'b1011011;  4'd3: g = 7'b1001111;
        4'd4: g = 7'b1100110;  4'd5: g = 7'b1101101;
        4'd6: g = 7'b1111101;  4'd7: g = 7'b0000111;
        4'd8: g = 7'b1111111;  4'd9: g = 7'b1101111;
        4'hA: g = 7'b0000000;                   // blank
        4'hB: g = 7'b1011110;                   // d
        4'hC: g = 7'b1110001;                   // F
        4'hD: g = 7'b1010100;                   // n
        4'hE: g = 7'b1111001;                   // E
        default: g = 7'b1000000;                // -
    endcase

    wire [3:0] an_hot = 4'b0001 << sel;
    assign an  = AN_ACTIVE_LOW  ? ~an_hot            : an_hot;
    assign seg = SEG_ACTIVE_LOW ? ~{1'b0, g}         : {1'b0, g};
endmodule
