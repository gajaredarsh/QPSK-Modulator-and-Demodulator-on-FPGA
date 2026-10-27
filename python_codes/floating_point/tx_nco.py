import sys
import os
import numpy as np

import params


# ---------------------------------------------------------------------
# PRBS generator
# Test data source for the transmitter. A known pseudo-random sequence
# looks like random data (so it exercises all four QPSK symbols) but is
# fully repeatable, so the receiver/testbench can regenerate the same
# bits and compare them to count errors.
# ---------------------------------------------------------------------
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
    # all-zero state XORs to zero and never leaves it, so it is not allowed
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


# ---------------------------------------------------------------------
# NCO (floating point)
# Ideal carrier with no quantization: no phase accumulator, no LUT and
# no word length. This is the reference that the fixed-point NCO
# (nco_fixed) is compared against.
# ---------------------------------------------------------------------
def nco_float(n_samples, fc_over_fs=params.FC_OVER_FS, init_phase=0.0):
    """
    Ideal floating-point carrier generator.
    fc_over_fs is the carrier frequency as a fraction of the sample
    rate (cycles per sample). It should equal phase_inc / 2^acc_bits of
    the fixed-point NCO, otherwise the two models use different carriers.
    """
    # sample index 0, 1, 2, ...
    n = np.arange(n_samples)
    # phase in radians at sample n: w*n = 2*pi*(fc/fs)*n, plus a start offset
    phase = 2 * np.pi * fc_over_fs * n + init_phase
    # cos and sin from the same phase, so they stay 90 deg apart
    return np.cos(phase), np.sin(phase)


# ---------------------------------------------------------------------
# TX mixer
# Combines the symbols with the carrier to get the QPSK signal:
#     s[n] = I[n]*cos(w*n) - Q[n]*sin(w*n)
# I rides on the cosine and Q on the sine, the two are orthogonal, so
# both bit streams share the same frequency band without interfering.
# ---------------------------------------------------------------------
def modulate(I, Q, cos, sin, sps=params.SAMPLES_PER_SYMBOL):
    """
    Float-domain TX mixer: s[n] = I_up[n]*cos[n] - Q_up[n]*sin[n].
    Floats have no fixed word length, so there is no overflow check
    here. The amplitude can reach sqrt(2) when I and Q are both +/-1,
    which is the headroom the fixed-point mixer has to budget bits for.
    """
    I = np.asarray(I)
    Q = np.asarray(Q)

    # one carrier sample is needed for every output sample
    n_expected = len(I) * sps
    if len(cos) < n_expected or len(sin) < n_expected:
        raise ValueError("carrier arrays too short for given I/Q length and sps")

    # each symbol is held constant for sps samples (rectangular pulse, no filtering)
    I_up = np.repeat(I, sps)
    Q_up = np.repeat(Q, sps)

    # the actual modulation: I on the cosine, Q on the sine
    return I_up * cos[:n_expected] - Q_up * sin[:n_expected]
