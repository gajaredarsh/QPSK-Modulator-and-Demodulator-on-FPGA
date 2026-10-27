import sys
import os
import numpy as np

import params

"""
 ---------------------------------------------------------------------
 PRBS generator :
 It is a Test data source for the transmitter. A known pseudo-random sequence
 looks like random data (so it exercises all four QPSK symbols) but is
 fully repeatable, so the receiver/testbench can regenerate the same
 bits and compare them to count errors.
 ---------------------------------------------------------------------
"""

def gen_bits(n, seed=params.PRBS_SEED, taps=params.PRBS_TAPS,
             reg_len=params.PRBS_LEN):

    """
    Fibonacci LFSR: a shift register whose new input bit is the XOR of
    a few tapped bits. The Verilog LFSR has to match this bit for bit:

        reg [6:0] lfsr;
        wire feedback = lfsr[0] ^ lfsr[6];
        wire out_bit  = lfsr[0];              // output is read before the shift
        always @(posedge clk)
            lfsr <= {feedback, lfsr[6:1]};    // shift right, feedback into MSB
        initial lfsr = 7'b1111111;            // seed = 0x7F

    taps=(1,7) here is 1-indexed, so it means bit 0 and bit 6 in the
    Verilog above. With reg_len=7 this is PRBS-7: it cycles through all
    2^7 - 1 = 127 non-zero states before repeating, and has 64 ones out
    of 127 (~0.5039), so 0s and 1s are almost perfectly balanced.
    """

    # all-zero state XORs to zero and never leaves it, so it is not allowed , so if seed == 0 , it should raise error
    if seed == 0:
        raise ValueError("LFSR seed must be non-zero")

    # keeping only reg_len bits of the seed
    state = seed & ((1 << reg_len) - 1)
    bits = np.zeros(n, dtype=np.uint8)
    t0, t1 = taps

    for i in range(n):
        # the bit being shifted out (LSB) is the output bit
        out_bit = state & 1
        # new bit = XOR of the two tapped bits (taps are 1-indexed, hence -1)
        fb = ((state >> (t0 - 1)) ^ (state >> (t1 - 1))) & 1
        # shift right by one and insert the feedback bit at the MSB
        state = (state >> 1) | (fb << (reg_len - 1))
        bits[i] = out_bit
    return bits


def _prbs7_rtl_reference(n, seed=0x7F):
    """
    PRBS-7 written exactly the way the Verilog does it, with the taps
    hardcoded. Only used to confirm that gen_bits() with taps=(1,7)
    produces the same sequence as the RTL, not just a sequence with
    the right period.
    """
    lfsr = seed & 0x7F
    bits = np.zeros(n, dtype=np.uint8)
    for i in range(n):
        out_bit = lfsr & 1                              # lfsr[0]
        fb = (lfsr & 1) ^ ((lfsr >> 6) & 1)             # lfsr[0] ^ lfsr[6]
        lfsr = (fb << 6) | (lfsr >> 1)                  # shift right, put fb at bit 6
        bits[i] = out_bit
    return bits


# ---------------------------------------------------------------------
# QPSK mapper / demapper
# QPSK sends 2 bits per symbol by choosing one of 4 points on the I/Q
# plane, (+1,+1), (+1,-1), (-1,-1), (-1,+1), which sit 90 deg apart.
# ---------------------------------------------------------------------
def map_qpsk(bits):
    """
    Gray-coded QPSK mapper (table is the one locked in params.py).
    Gray coding means neighbouring constellation points differ in only
    one bit, so when noise pushes a symbol into the nearest neighbour
    only 1 bit is wrong instead of 2.
    """
    bits = np.asarray(bits)
    # every symbol uses 2 bits, so the length must be even
    if len(bits) % 2 != 0:
        raise ValueError("bit stream length must be even")

    # row i holds (b0, b1) of symbol i
    pairs = bits.reshape(-1, 2)
    b0 = pairs[:, 0].astype(float)
    b1 = pairs[:, 1].astype(float)

    # b0 sets the I sign and b1 sets the Q sign: bit 0 -> +1, bit 1 -> -1
    # (levels are +/-1, not scaled to unit energy)
    I = 1.0 - 2.0 * b0
    Q = 1.0 - 2.0 * b1
    return I, Q


def demap_qpsk_reference(I, Q):
    """Ideal inverse of map_qpsk, only used to self-check Part A."""
    # a hard decision is just the sign: negative means the bit was 1
    b0 = (np.asarray(I) < 0).astype(np.uint8)
    b1 = (np.asarray(Q) < 0).astype(np.uint8)

    # interleave back into b0, b1, b0, b1, ...
    bits = np.empty(2 * len(I), dtype=np.uint8)
    bits[0::2] = b0
    bits[1::2] = b1
    return bits

"""
 NCO (numerically controlled oscillator)
 ---------------------------------------------------------------------
 Generates the carrier digitally. A phase accumulator adds a fixed
 phase_inc every sample, and the accumulated phase is converted to
 cos/sin by a lookup table instead of computing trig in hardware.
 ---------------------------------------------------------------------
"""

def build_nco_lut(lut_size=params.NCO_LUT_SIZE,
                  datapath_bits=params.DATAPATH_BITS):
    """Stores one full cycle of cos and sin as signed fixed-point integers."""
    # largest positive value of a signed word (e.g. 2047 for 12 bits);
    # using this instead of 2^(bits-1) keeps +1.0 from overflowing
    full_scale = (1 << (datapath_bits - 1)) - 1

    # lut_size equally spaced angles covering 0 to 2*pi
    angles = 2 * np.pi * np.arange(lut_size) / lut_size

    # scale [-1, 1] up to the integer range and round to the nearest integer
    lut_cos = np.round(full_scale * np.cos(angles)).astype(int)
    lut_sin = np.round(full_scale * np.sin(angles)).astype(int)
    return lut_cos, lut_sin


def phase_inc_is_exact_for_lut(phase_inc, acc_bits, lut_bits):
    """
    Checks if indexing the LUT loses any phase information.
    The accumulator is wider than the LUT address, so its low
    (acc_bits - lut_bits) bits get dropped. If those bits are always 0
    the lookup is exact. Adding phase_inc repeatedly preserves
    divisibility by 2^shift, so checking phase_inc alone is enough.
    """
    shift = acc_bits - lut_bits
    return (phase_inc % (1 << shift)) == 0


def nco_fixed(n_samples, phase_inc=params.NCO_PHASE_INC,
              acc_bits=params.NCO_ACC_BITS, lut_bits=params.NCO_LUT_BITS,
              datapath_bits=params.DATAPATH_BITS, init_phase=0):
    """
    Bit-accurate model of the NCO that goes on the FPGA.
    Output frequency is f_out = phase_inc * f_s / 2^acc_bits, where f_s
    is the rate the NCO is updated at, so phase_inc sets the carrier.
    """
    lut_cos, lut_sin = build_nco_lut(lut_size=(1 << lut_bits),
                                     datapath_bits=datapath_bits)

    # the accumulator value 0 .. 2^acc_bits maps to a phase of 0 .. 2*pi
    acc_max = 1 << acc_bits
    # number of low accumulator bits dropped when addressing the LUT
    shift = acc_bits - lut_bits
    if shift < 0:
        raise ValueError("LUT address width cannot exceed accumulator width")

    phase = init_phase % acc_max
    cos_out = np.zeros(n_samples, dtype=int)
    sin_out = np.zeros(n_samples, dtype=int)

    for i in range(n_samples):
        # the top lut_bits bits of the accumulator are the LUT address
        idx = phase >> shift
        # cos and sin come from the same address, so they stay 90 deg apart
        cos_out[i] = lut_cos[idx]
        sin_out[i] = lut_sin[idx]
        # advance the phase; the wrap-around at acc_max is the 2*pi rollover
        phase = (phase + phase_inc) % acc_max
    return cos_out, sin_out


# ---------------------------------------------------------------------
# TX mixer
# Combines the symbols with the carrier to get the QPSK signal:
#     s[n] = I[n]*cos(w*n) - Q[n]*sin(w*n)
# I rides on the cosine and Q on the sine, the two are orthogonal, so
# both bit streams share the same frequency band without interfering.
# ---------------------------------------------------------------------
def required_mixer_bits(datapath_bits):
    """
    Smallest signed width that can hold I*cos - Q*sin without overflow.
    With I,Q = +1/-1 the sum of cos and sin terms can reach
    full_scale * sqrt(2) (at the +/-45 deg LUT entries), which is more
    than a datapath_bits word can hold, so the mixer needs extra bits.
    """
    full_scale = (1 << (datapath_bits - 1)) - 1
    worst_case = full_scale * np.sqrt(2)

    # increasing the width until the signed maximum covers the worst case
    bits = 1
    while (1 << (bits - 1)) - 1 < worst_case:
        bits += 1
    return bits


def modulate_fixed(I, Q, cos_int, sin_int, sps=params.SAMPLES_PER_SYMBOL,
                   out_bits=params.MIXER_OUT_BITS):
    """
    Integer model of the TX mixer, doing the same arithmetic as
    tx_mixer.v. I,Q are +1/-1 and cos_int/sin_int are integers from
    nco_fixed(), so the products and the subtraction are exact and no
    rounding is needed. The only thing left to check is that the result
    fits in out_bits.

    Raises OverflowError instead of wrapping or clipping, so an
    overflow is caught here and doesn't show up later as a distorted
    constellation.
    """
    I = np.asarray(I).astype(int)
    Q = np.asarray(Q).astype(int)

    # one carrier sample is needed for every output sample
    n_expected = len(I) * sps
    if len(cos_int) < n_expected or len(sin_int) < n_expected:
        raise ValueError("carrier arrays too short for given I/Q length and sps")

    # each symbol is held constant for sps samples (rectangular pulse, no filtering)
    I_up = np.repeat(I, sps)
    Q_up = np.repeat(Q, sps)

    # the actual modulation: I on the cosine, Q on the sine
    s = I_up * cos_int[:n_expected] - Q_up * sin_int[:n_expected]

    # range of a signed out_bits-wide register
    max_val = (1 << (out_bits - 1)) - 1
    min_val = -(1 << (out_bits - 1))
    if np.any(s > max_val) or np.any(s < min_val):
        raise OverflowError(
            f"modulate_fixed output [{s.min()},{s.max()}] exceeds "
            f"{out_bits}-bit signed range [{min_val},{max_val}]"
        )
    return s


# ---------------------------------------------------------------------
# LUT hex export for Verilog $readmemh
# The same cos/sin tables used in Python are loaded into the FPGA's
# ROM, so the hardware and this model use identical values.
# ---------------------------------------------------------------------
def export_lut_hex(lut, bits, filename):
    """
    Writes the LUT as a hex file that $readmemh can load: one value per
    line, two's complement over `bits` bits, no 0x prefix, no commas.
    """
    mask = (1 << bits) - 1
    hex_width = (bits + 3) // 4        # hex digits needed to cover `bits` bits

    with open(filename, "w") as f:
        for val in lut:
            # masking to `bits` bits turns a negative number into its two's complement
            twos = int(val) & mask
            f.write(f"{twos:0{hex_width}x}\n")


def read_hex_twos_complement(filename, bits):
    """Reads an exported hex file back into signed ints, to verify the round-trip."""
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
    # generate the hex files that the Verilog NCO loads with $readmemh
    lut_cos, lut_sin = build_nco_lut()
    export_lut_hex(lut_cos, params.DATAPATH_BITS, "lut_cos.hex")
    export_lut_hex(lut_sin, params.DATAPATH_BITS, "lut_sin.hex")
    print("Wrote lut_cos.hex and lut_sin.hex "
          f"({params.NCO_LUT_SIZE} entries, {params.DATAPATH_BITS}-bit two's complement)")
