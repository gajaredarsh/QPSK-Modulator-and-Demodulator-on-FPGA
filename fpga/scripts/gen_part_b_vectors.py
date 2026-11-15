# gen_part_b_vectors.py (Part B)

import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)

import params
import channel
import fixedpoint

RTL = os.path.join(ROOT, "rtl")
VEC = os.path.join(ROOT, "vectors")
os.makedirs(RTL, exist_ok=True)
os.makedirs(VEC, exist_ok=True)


def write(name, codes, bits):
    fixedpoint.write_hex(os.path.join(VEC, name), codes, bits)


# Create the QPSK parameter file
w = channel.noise_path_widths()
level_bits = int(np.ceil(np.log2(len(channel.EBN0_TABLE_DB))))
lines = [
    "// qpsk_params.vh",
    "// Generated from the Python files. Do not edit by hand.",
    "`ifndef QPSK_PARAMS_VH",
    "`define QPSK_PARAMS_VH",
    "`define TX_BITS           %d    // TX output width" % params.MIXER_OUT_BITS,
    "`define RX_BITS           %d    // RX input width" % channel.RX_BITS,
    "`define NOISE_RAW_BITS    %d    // Raw noise width" % w["raw"],
    "`define NOISE_PROD_BITS   %d    // Noise and gain product width" % w["prod"],
    "`define NOISE_BITS        %d    // Scaled noise width" % w["noise"],
    "`define SUM_BITS          %d    // Final sum width" % w["sum"],
    "`define NOISE_GAIN_BITS   %d    // Gain register width" % channel.NOISE_GAIN_BITS,
    "`define NOISE_GAIN_SHIFT  %d    // Gain shift value" % channel.NOISE_GAIN_SHIFT,
    "`define TX_TO_RX_SHIFT    %d    // TX to RX conversion shift" % channel.TX_TO_RX_SHIFT,
    "`define NOISE_MEAN        %d  // Average value of six bytes" % channel.NOISE_MEAN,
    "`define NOISE_LEVELS      %d" % len(channel.EBN0_TABLE_DB),
    "`define NOISE_LEVEL_BITS  %d" % level_bits,
]
for i, s in enumerate(channel.NOISE_SEEDS):
    lines.append("`define NOISE_SEED%d        16'h%04X" % (i, s))
lines.append("`endif")
open(os.path.join(RTL, "qpsk_params.vh"), "w").write("\n".join(lines) + "\n")

# Create the noise gain ROM
table = channel.gain_table()
rom = [
    "// noise_gain_rom.v",
    "// Generated from the Python gain table. Do not edit by hand.",
    "// Each level represents an Eb/N0 value in dB.",
    "`timescale 1ns/1ps",
    '`include "qpsk_params.vh"',
    "",
    "module noise_gain_rom (",
    "    input  wire [`NOISE_LEVEL_BITS-1:0] level,",
    "    output reg  [`NOISE_GAIN_BITS-1:0]  gain",
    ");",
    "    always @(*) begin",
    "        case (level)",
]
for i, g in enumerate(table):
    rom.append("            %d'd%-2d: gain = %d'd%d;   // %d dB" % (level_bits, i, channel.NOISE_GAIN_BITS, g, channel.EBN0_TABLE_DB[i]))
rom += ["            default: gain = %d'd%d;" % (channel.NOISE_GAIN_BITS, table[-1]),
        "        endcase", "    end", "endmodule"]
open(os.path.join(RTL, "noise_gain_rom.v"), "w").write("\n".join(rom) + "\n")

# Generate noise test vectors
N_NOISE = 70000
channel.export_noise_vectors(VEC, n_samples=N_NOISE, ebn0_db=6.0)

# Generate noise scaling test vectors
NS = 4096
SCALE_GAINS = [0, 2902, 5790, 8191]          # Different gain values
write("scale_gains.hex", SCALE_GAINS, channel.NOISE_GAIN_BITS)
write("scale_exp_all.hex", np.concatenate([channel.noise_int(NS, g) for g in SCALE_GAINS]), w["noise"])

# Generate input and output vectors for the AWGN core
rng = np.random.default_rng(2024)
n_sym = 500
bits = rng.integers(0, 2, 2 * n_sym)
I, Q = 1 - 2 * bits[0::2], 1 - 2 * bits[1::2]
k = np.arange(params.SAMPLES_PER_SYMBOL)
full = params.DATAPATH_FULL_SCALE
c1 = np.round(full * np.cos(2 * np.pi * params.CARRIER_CYCLES_PER_SYMBOL * k / params.SAMPLES_PER_SYMBOL)).astype(int)
s1 = np.round(full * np.sin(2 * np.pi * params.CARRIER_CYCLES_PER_SYMBOL * k / params.SAMPLES_PER_SYMBOL)).astype(int)
qpsk = np.repeat(I, params.SAMPLES_PER_SYMBOL) * np.tile(c1, n_sym) - np.repeat(Q, params.SAMPLES_PER_SYMBOL) * np.tile(s1, n_sym)
wide_rand = rng.integers(-4096, 4096, 8000)
s13 = np.concatenate([qpsk, wide_rand]).astype(np.int64)
M = len(s13)
CORE_GAINS = [0, 5790, 2902, 1030, 8191]
write("core_in.hex", s13, params.MIXER_OUT_BITS)
write("core_gains.hex", CORE_GAINS, channel.NOISE_GAIN_BITS)
r12_all, wide_all = [], []
for g in CORE_GAINS:
    r12, total = channel.awgn_int(s13, gain=g, return_wide=True)
    r12_all.append(r12)
    wide_all.append(total)
write("core_r12_all.hex", np.concatenate(r12_all), channel.RX_BITS)
write("core_wide_all.hex", np.concatenate(wide_all), w["sum"])

# Generate AWGN channel test vectors
MC = 2000
chan = [channel.awgn_int(s13[:MC], gain=g) for g in table] + [channel.awgn_int(s13[:MC], gain=0)]
write("chan_r12_all.hex", np.concatenate(chan), channel.RX_BITS)

# Generate vectors for changing gain values
MG = 6000
rng_g = np.random.default_rng(77)
choices = np.array(table + [0], dtype=np.int64)
gain_seq = np.concatenate([np.full(rng_g.integers(1, 8), choices[rng_g.integers(0, len(choices))])
                           for _ in range(MG)])[:MG]
r12_g, wide_g = channel.awgn_int(s13[:MG], gain=gain_seq, return_wide=True)
write("gc_in.hex", s13[:MG], params.MIXER_OUT_BITS)
write("gc_gain.hex", gain_seq, channel.NOISE_GAIN_BITS)
write("gc_r12.hex", r12_g, channel.RX_BITS)
write("gc_wide.hex", wide_g, w["sum"])

# Check that the output reaches both saturation limits
sat_r12 = channel.awgn_int(s13, gain=8191)
assert (sat_r12 == 2047).sum() > 0 and (sat_r12 == -2048).sum() > 0, "vectors do not exercise saturation"

print("wrote rtl/qpsk_params.vh, rtl/noise_gain_rom.v and vectors/ (core: %d samples x %d gains, channel: %d samples x %d settings)"
      % (M, len(CORE_GAINS), MC, len(chan)))
print("gain table (Eb/N0 0..15 dB):", table)
