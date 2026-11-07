// NCO: phase accumulator + quantised sin/cos ROMs.
// Mirrors tx_nco.nco_fixed(): idx = phase >> (ACC-LUTB); output LUT[idx]; then
// phase += INC (mod 2^ACC). Sample 0 uses phase = 0. ROM contents come from
// lut_cos.hex / lut_sin.hex written by gen_rtl_vectors.py.
// One-register latency: outputs for sample n are valid after enable tick n.
`include "qpsk_params.vh"
module nco #(
    parameter ACC      = `NCO_ACC_BITS,
    parameter LUTB     = `NCO_LUT_BITS,
    parameter W        = `DATAPATH_BITS,
    parameter INC      = `NCO_PHASE_INC,
    parameter COS_FILE = "lut_cos.hex",
    parameter SIN_FILE = "lut_sin.hex"
)(
    input  wire                clk,
    input  wire                rst,
    input  wire                en,        // sample-rate enable
    output reg signed [W-1:0]  cos_o,
    output reg signed [W-1:0]  sin_o
);
    reg signed [W-1:0] rom_c [0:(1<<LUTB)-1];
    reg signed [W-1:0] rom_s [0:(1<<LUTB)-1];
    initial begin
        $readmemh(COS_FILE, rom_c);
        $readmemh(SIN_FILE, rom_s);
    end

    reg  [ACC-1:0]  phase;
    wire [LUTB-1:0] idx = phase[ACC-1 -: LUTB];

    always @(posedge clk) begin
        if (rst) begin
            phase <= {ACC{1'b0}};
            cos_o <= {W{1'b0}};
            sin_o <= {W{1'b0}};
        end else if (en) begin
            cos_o <= rom_c[idx];
            sin_o <= rom_s[idx];
            phase <= phase + INC[ACC-1:0];
        end
    end
endmodule
