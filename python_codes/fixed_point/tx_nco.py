import sys
import os
import numpy as np

import params


# ---------------- PRBS ----------------
# Repeatable test bits: the receiver/testbench can regenerate the same
# sequence and count errors.
def gen_bits(n, seed=params.PRBS_SEED, taps=params.PRBS_TAPS,
             reg_len=params.PRBS_LEN):
   
    # Fibonacci LFSR: a shift register whose new input bit is the XOR of
    # a few tapped bits. The Verilog LFSR has to match this bit for bit:

    #     reg [6:0] lfsr;
    #     wire feedback = lfsr[0] ^ lfsr[6];
    #     wire out_bit  = lfsr[0];              // output is read before the shift
    #     always @(posedge clk)
    #         lfsr <= {feedback, lfsr[6:1]};    // shift right, feedback into MSB
    #     initial lfsr = 7'b1111111;            // seed = 0x7F

    # taps=(1,7) here is 1-indexed, so it means bit 0 and bit 6 in the
    # Verilog above. With reg_len=7 this is PRBS-7: it cycles through all
    # 2^7 - 1 = 127 non-zero states before repeating, and has 64 ones out
    # of 127 (~0.5039), so 0s and 1s are almost perfectly balanced.

    if seed == 0:                       # all-zero state never changes
        raise ValueError("LFSR seed must be non-zero")

    state = seed & ((1 << reg_len) - 1)     # keep reg_len bits of the seed
    bits = np.zeros(n, dtype=np.uint8)
    t0, t1 = taps

    for i in range(n):
        out_bit = state & 1                                       # LSB is the output
        fb = ((state >> (t0 - 1)) ^ (state >> (t1 - 1))) & 1      # XOR of the taps
        state = (state >> 1) | (fb << (reg_len - 1))              # shift right, fb into MSB
        bits[i] = out_bit
    return bits


def _prbs7_rtl_reference(n, seed=0x7F):
    # Hardcoded copy of the Verilog LFSR, used to cross-check gen_bits()
    lfsr = seed & 0x7F
    bits = np.zeros(n, dtype=np.uint8)
    for i in range(n):
        out_bit = lfsr & 1                              # lfsr[0]
        fb = (lfsr & 1) ^ ((lfsr >> 6) & 1)             # lfsr[0] ^ lfsr[6]
        lfsr = (fb << 6) | (lfsr >> 1)
        bits[i] = out_bit
    return bits


# ---------------- QPSK mapper ----------------
# 2 bits per symbol -> one of 4 points (+-1, +-1) on the I/Q plane.
def map_qpsk(bits):
  
    # Gray-coded mapping (table in params.py). Neighbouring points differ
    # by one bit, so a nearest-neighbour error costs only 1 bit.
  
    bits = np.asarray(bits)
    if len(bits) % 2 != 0:              # 2 bits per symbol
        raise ValueError("bit stream length must be even")

    pairs = bits.reshape(-1, 2)         # row = (b0, b1) of one symbol
    b0 = pairs[:, 0].astype(float)
    b1 = pairs[:, 1].astype(float)

    I = 1.0 - 2.0 * b0                  # bit 0 -> +1, bit 1 -> -1
    Q = 1.0 - 2.0 * b1
    return I, Q


def demap_qpsk_reference(I, Q):
    # Inverse of map_qpsk, only for self-checks
    b0 = (np.asarray(I) < 0).astype(np.uint8)   # negative -> bit 1
    b1 = (np.asarray(Q) < 0).astype(np.uint8)

    bits = np.empty(2 * len(I), dtype=np.uint8)
    bits[0::2] = b0                     # interleave b0, b1, b0, b1, ...
    bits[1::2] = b1
    return bits


# ---------------- NCO ----------------
# Carrier generator: a phase accumulator steps by phase_inc every
# sample and a LUT turns the phase into cos/sin.
def build_nco_lut(lut_size=params.NCO_LUT_SIZE,
                  datapath_bits=params.DATAPATH_BITS):
    # One cycle of cos and sin as signed integers.
    full_scale = (1 << (datapath_bits - 1)) - 1             # e.g. 2047 for 12 bits
    angles = 2 * np.pi * np.arange(lut_size) / lut_size     # 0 to 2*pi in equal steps
    lut_cos = np.round(full_scale * np.cos(angles)).astype(int)
    lut_sin = np.round(full_scale * np.sin(angles)).astype(int)
    return lut_cos, lut_sin


def phase_inc_is_exact_for_lut(phase_inc, acc_bits, lut_bits):

    # True if the LUT lookup drops no phase information, i.e. the low
    # (acc_bits - lut_bits) bits of every phase value are 0. Checking
    # phase_inc alone is enough, since adding it keeps that divisibility.

    shift = acc_bits - lut_bits
    return (phase_inc % (1 << shift)) == 0


def nco_fixed(n_samples, phase_inc=params.NCO_PHASE_INC,
              acc_bits=params.NCO_ACC_BITS, lut_bits=params.NCO_LUT_BITS,
              datapath_bits=params.DATAPATH_BITS, init_phase=0):

    # Bit-accurate model of the FPGA NCO.
    # f_out = phase_inc * fs / 2^acc_bits.
   
    lut_cos, lut_sin = build_nco_lut(lut_size=(1 << lut_bits),
                                     datapath_bits=datapath_bits)

    acc_max = 1 << acc_bits             # accumulator range = one full turn (2*pi)
    shift = acc_bits - lut_bits         # low bits dropped when addressing the LUT
    if shift < 0:
        raise ValueError("LUT address width cannot exceed accumulator width")

    phase = init_phase % acc_max
    cos_out = np.zeros(n_samples, dtype=int)
    sin_out = np.zeros(n_samples, dtype=int)

    for i in range(n_samples):
        idx = phase >> shift                    # top lut_bits bits = LUT address
        cos_out[i] = lut_cos[idx]
        sin_out[i] = lut_sin[idx]
        phase = (phase + phase_inc) % acc_max   # wrap-around = 2*pi rollover
    return cos_out, sin_out


# ---------------- TX mixer ----------------
# s = I*cos - Q*sin (I on the cosine, Q on the sine).
def required_mixer_bits(datapath_bits):
 
    # Smallest signed width that holds I*cos - Q*sin. Worst case is
    # full_scale * sqrt(2), at the +/-45 deg LUT entries.
   
    full_scale = (1 << (datapath_bits - 1)) - 1
    worst_case = full_scale * np.sqrt(2)

    bits = 1
    while (1 << (bits - 1)) - 1 < worst_case:   # grow until the signed max covers it
        bits += 1
    return bits


def modulate_fixed(I, Q, cos_int, sin_int, sps=params.SAMPLES_PER_SYMBOL,
                   out_bits=params.MIXER_OUT_BITS):

    # Integer TX mixer, same arithmetic as tx_mixer.v. The result is
    # exact, so it only needs an overflow check; raises OverflowError
    # instead of wrapping.

    I = np.asarray(I).astype(int)
    Q = np.asarray(Q).astype(int)

    # one carrier sample for every output sample
    n_expected = len(I) * sps
    if len(cos_int) < n_expected or len(sin_int) < n_expected:
        raise ValueError("carrier arrays too short for given I/Q length and sps")

    I_up = np.repeat(I, sps)            # hold each symbol for sps samples (rectangular pulse, no filtering)
    Q_up = np.repeat(Q, sps)

    s = I_up * cos_int[:n_expected] - Q_up * sin_int[:n_expected]

    max_val = (1 << (out_bits - 1)) - 1     # signed out_bits range
    min_val = -(1 << (out_bits - 1))
    if np.any(s > max_val) or np.any(s < min_val):
        raise OverflowError(
            f"modulate_fixed output [{s.min()},{s.max()}] exceeds "
            f"{out_bits}-bit signed range [{min_val},{max_val}]"
        )
    return s


# ---------------- LUT export for $readmemh ----------------
# The FPGA ROM loads the same tables, so hardware and model match.

def export_lut_hex(lut, bits, filename):
    # Write the LUT as hex for $readmemh: one two's-complement value per line.
    mask = (1 << bits) - 1
    hex_width = (bits + 3) // 4         # hex digits per value

    with open(filename, "w") as f:
        for val in lut:
            twos = int(val) & mask      # negative -> two's complement
            f.write(f"{twos:0{hex_width}x}\n")


def read_hex_twos_complement(filename, bits):
    # Reads an exported hex file back into signed ints, to verify the round-trip
    half = 1 << (bits - 1)
    full = 1 << bits
    vals = []
    with open(filename) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            u = int(line, 16)
            # MSB set means a negative number, subtract 2^bits to undo two's complement
            if u >= half:               
                u -= full
            vals.append(u)
    return np.array(vals)


if __name__ == "__main__":
    # generating the hex files that the Verilog NCO loads with $readmemh
    lut_cos, lut_sin = build_nco_lut()
    export_lut_hex(lut_cos, params.DATAPATH_BITS, "lut_cos.hex")
    export_lut_hex(lut_sin, params.DATAPATH_BITS, "lut_sin.hex")
    print("Wrote lut_cos.hex and lut_sin.hex "
          f"({params.NCO_LUT_SIZE} entries, {params.DATAPATH_BITS}-bit two's complement)")
