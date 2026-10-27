# Es/Eb for the AWGN channel (float domain, unscaled):
#    Over a symbol the carrier cross term averages to zero, so
#    E[s^2] = I^2/2 + Q^2/2 = 1.0 per sample.
#    Es = 1.0 * 16 = 16,  Eb = Es / 2 = 8  (2 bits per symbol).
#    Fixed-point outputs are scaled by DATAPATH_FULL_SCALE

import numpy as np

# ---------------- Timing ----------------
SAMPLES_PER_SYMBOL = 16            # samples in one symbol
CARRIER_CYCLES_PER_SYMBOL = 2      # whole carrier cycles per symbol
FC_OVER_FS = CARRIER_CYCLES_PER_SYMBOL / SAMPLES_PER_SYMBOL   # carrier, cycles/sample = 0.125

# ---------------- NCO ----------------
NCO_ACC_BITS = 16                  # phase accumulator width
NCO_LUT_BITS = 8                   # LUT address width
NCO_LUT_SIZE = 1 << NCO_LUT_BITS   # 256 entries

# fc/fs * 2^acc_bits; a multiple of 2^(16-8), so the LUT lookup is exact
NCO_PHASE_INC = round(FC_OVER_FS * (1 << NCO_ACC_BITS))       # = 8192

# awkward ratio used only by the precision-sweep tests
GENERIC_TEST_FC_OVER_FS = 0.12398

# ---------------- Fixed-point datapath ----------------
DATAPATH_BITS = 12                                     # cos/sin LUT width
DATAPATH_FULL_SCALE = (1 << (DATAPATH_BITS - 1)) - 1   # = 2047

# worst case |I*cos - Q*sin| = 2047*sqrt(2) ~= 2895, needs 13 bits signed
MIXER_OUT_BITS = 13

# ---------------- PRBS ----------------
PRBS_LEN = 7                       # PRBS-7, period 127
PRBS_TAPS = (1, 7)                 # 1-indexed, bits 0 and 6 in Verilog
PRBS_SEED = 0x7F                   # must be non-zero

# ---------------- QPSK mapping (LOCKED, demapper must invert it) ----------------
# I = 1 - 2*b0, Q = 1 - 2*b1
#   (0,0) -> (+1,+1)   45 deg
#   (0,1) -> (+1,-1)  315 deg
#   (1,1) -> (-1,-1)  225 deg
#   (1,0) -> (-1,+1)  135 deg
# Neighbouring points differ by one bit (Gray).

# ---------------- TX mixer (LOCKED) ----------------
# s[n] = I*cos[n] - Q*sin[n]

# ---------------- Receiver ----------------
FIR_ORDER = 24                     # 25 taps
FIR_FC = 0.125                     # -6 dB cutoff, cycles/sample
FIR_WINDOW = "hamming"
COEF_BITS = 12                     # signed coefficients, Q1.(COEF_BITS-1)
RX_IN_BITS = 12                    # receiver input ("ADC") word
RX_FULL_SCALE = 8.0                # float amplitude mapped to RX full scale
PASS_EDGE = 1.0 / SAMPLES_PER_SYMBOL                       # data band edge
STOP_EDGE = 2.0 * FC_OVER_FS - 1.0 / SAMPLES_PER_SYMBOL    # start of the 2*fc term
