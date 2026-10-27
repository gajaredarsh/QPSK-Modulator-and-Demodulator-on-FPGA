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

    # all-zero state XORs to zero and never leaves it, so it is not allowed

    if seed == 0:
        raise ValueError("LFSR seed must be non-zero")

    # keeping only reg_len bits of the seed
    state = seed & ((1 << reg_len) - 1)
    bits = np.zeros(n, dtype=np.uint8)
    t0, t1 = taps

    for i in range(n):
        out_bit = state & 1                                       # LSB is the output 
        fb = ((state >> (t0 - 1)) ^ (state >> (t1 - 1))) & 1      # XOR of the taps
        state = (state >> 1) | (fb << (reg_len - 1))              # shift right, fb into MSB
        bits[i] = out_bit
    return bits


def _prbs7_rtl_reference(n, seed=0x7F):
# Hardcoded copy of the Verilog LFSR, used to cross-check gen_bits().
    lfsr = seed & 0x7F
    bits = np.zeros(n, dtype=np.uint8)
    for i in range(n):
        out_bit = lfsr & 1                              # lfsr[0]
        fb = (lfsr & 1) ^ ((lfsr >> 6) & 1)             # lfsr[0] ^ lfsr[6]
        lfsr = (fb << 6) | (lfsr >> 1)                  # shift right, put fb at bit 6
        bits[i] = out_bit
    return bits


# -----------------QPSK mapper / demapper-------------------------
# QPSK sends 2 bits per symbol by choosing one of 4 points on the I/Q
# plane, (+1,+1), (+1,-1), (-1,-1), (-1,+1)
def map_qpsk(bits):

    # Gray-coded mapping (table in params.py). Neighbouring points differ
    # by one bit, so a nearest-neighbour error costs only 1 bit.

    bits = np.asarray(bits)
    # every symbol uses 2 bits, so the length must be even
    if len(bits) % 2 != 0:
        raise ValueError("bit stream length must be even")


    pairs = bits.reshape(-1, 2)        # row = (b0, b1) of one symbol
    b0 = pairs[:, 0].astype(float)
    b1 = pairs[:, 1].astype(float)


    I = 1.0 - 2.0 * b0      # bit 0 -> +1, bit 1 -> -1
    Q = 1.0 - 2.0 * b1
    return I, Q


def demap_qpsk_reference(I, Q):
    # Ideal inverse of map_qpsk, only used to self-check
    b0 = (np.asarray(I) < 0).astype(np.uint8)   # negative -> bit 1
    b1 = (np.asarray(Q) < 0).astype(np.uint8)

   
    bits = np.empty(2 * len(I), dtype=np.uint8)
    bits[0::2] = b0            # interleave back into b0, b1, b0, b1, ...
    bits[1::2] = b1
    return bits


# -------------NCO (floating point)---------------------
# Ideal carrier: no accumulator, LUT or word length 
# This is the reference that the fixed-point NCO
def nco_float(n_samples, fc_over_fs=params.FC_OVER_FS, init_phase=0.0):

    # Ideal carrier. fc_over_fs (cycles/sample) must equal
    # phase_inc / 2^acc_bits of the fixed-point NCO, or the two models
    # using different carriers.

    n = np.arange(n_samples)   # sample index
    phase = 2 * np.pi * fc_over_fs * n + init_phase    # radians at sample n
    return np.cos(phase), np.sin(phase)   # same phase -> 90 deg apart


# ---------------- TX mixer ----------------
# s = I*cos - Q*sin (I on the cosine, Q on the sine).
def modulate(I, Q, cos, sin, sps=params.SAMPLES_PER_SYMBOL):

    # Float TX mixer. No overflow check (floats have no word length);
    # The amplitude can reach sqrt(2) when I and Q are both +/-1.
    I = np.asarray(I)
    Q = np.asarray(Q)

    # one carrier sample for every output sample
    n_expected = len(I) * sps
    if len(cos) < n_expected or len(sin) < n_expected:
        raise ValueError("carrier arrays too short for given I/Q length and sps")

   
    I_up = np.repeat(I, sps)  # hold each symbol for sps samples (rectangular pulse, no filtering)
    Q_up = np.repeat(Q, sps)

    # the actual modulation: I on the cosine, Q on the sine
    return I_up * cos[:n_expected] - Q_up * sin[:n_expected]
