# rx_frontend.py (floating point)
# this part was written by Aditya

import os                             
import sys                            

import numpy as np
from scipy import signal              #for filter design, frequency response
from scipy.optimize import brentq     #for finding the point where a function becomes zero
from scipy.special import erfc        #this is needed for the Q function
import matplotlib.pyplot as plt      

import params
import channel
import tx_nco                         

#for simplicity, short forms for the numbers we keep in params.py
SPS = params.SAMPLES_PER_SYMBOL       # 16 samples in one symbol
FC_OVER_FS = params.FC_OVER_FS        # carrier cycles per sample (0.125)
FIR_ORDER = params.FIR_ORDER          # 24, so 25 taps
FIR_FC = params.FIR_FC                # filter cutoff (0.125)
FIR_WINDOW = params.FIR_WINDOW        # hamming window
COEF_BITS = params.COEF_BITS          # bits for each tap
RX_IN_BITS = params.RX_IN_BITS        # bits of the receiver input
RX_FULL_SCALE = params.RX_FULL_SCALE  # float value that becomes the biggest receiver input
PASS_EDGE = params.PASS_EDGE          # data band ending (1/16)
STOP_EDGE = params.STOP_EDGE          # junk band starting (0.1875)


#In RX mixer we basically multiply the received signal with cos and -sin to make the data DC (0 Hz).
# xi = r*cos gives I/2 and xq = -r*sin gives Q/2
#whatever is left at 2*fc, the filter removes it later.
def downconvert(r, cos, sin):
    # this makes sure r is a numpy array so the multiplication is sample by sample
    r = np.asarray(r)
    n = len(r)
    #here the carrier should be at least as long as the signal, otherwise stop
    if len(cos) < n or len(sin) < n:
        raise ValueError("local carrier arrays are shorter than the received signal")
    # cutting the carrier to the same length as r, then multiply
    return r * cos[:n], -r * sin[:n]


# Makeing the low pass FIR filter (order 24 means 25 taps).
# fc is in cycles per sample, so 0.125 is fs/8. The window smooths the sinc.
#The taps add up to 1, so the DC data (0 Hz) passes without any change.

def design_lpf(order=FIR_ORDER, fc=FIR_FC, window=FIR_WINDOW):
    # order must be even so the delay (order/2) is a whole number of samples
    if order % 2 != 0:
        raise ValueError("order must be even")
    # fc must be between 0 and 0.5 because 0.5 is the highest frequency (sample rate = 1)
    if not (0.0 < fc < 0.5):
        raise ValueError("fc is in cycles/sample and must be between 0 and 0.5")
    #firwin does the sinc + window. fs=1 means fc is in cycles per sample
    return signal.firwin(order + 1, fc, window=window, fs=1.0)


# How many samples the filter delays the signal. For a symmetric filter it is (taps-1)/2, so 12 for us.

def group_delay_samples(h):
    h = np.asarray(h)
    # h[::-1] is h reversed, anyway a symmetric filter looks the same both ways
    if len(h) % 2 == 0 or not np.allclose(h, h[::-1]):
        raise ValueError("filter is not a symmetric odd-length (linear-phase type I) FIR")
    return (len(h) - 1) // 2


# Gives the frequencies (0 to 0.5) and how much the filter passes at each one.
def freq_response(h, n_points=4096):
    return signal.freqz(h, worN=n_points, fs=1.0)


# Checks the filter against what we wanted. Data band (up to 1/16) should pass almost unchanged,
# junk band (from 0.1875 up) should be very small. Our targets: within +-0.5 dB in the data band
# and at least 35 dB down in the junk band.
def check_mask(h):
    f, H = freq_response(h, 8192)
    # gain in dB. The tiny number added is so log never sees a zero
    mag_db = 20 * np.log10(np.abs(H) + 1e-300)
    # biggest and smallest gain in the data band, biggest gain in the junk band, and the delay
    return {
        "pass_max": float(mag_db[f <= PASS_EDGE].max()),
        "pass_min": float(mag_db[f <= PASS_EDGE].min()),
        "stop_max": float(mag_db[f >= STOP_EDGE].max()),
        "delay": group_delay_samples(h),
    }


# Finds the zeros of the filter (for the pole-zero plot).
# The first and last taps of our filter are exactly 0, which would put zeros at infinity.
# So we cut them off here and just count how many we cut.
def finite_zeros(h, tol=1e-9):
    h = np.asarray(h, dtype=float)
    # keep = taps that are not (almost) zero
    keep = np.abs(h) > tol * np.abs(h).max()
    # lo = first good tap, hi = just after the last good tap
    lo, hi = np.argmax(keep), len(h) - np.argmax(keep[::-1])
    # the roots of the trimmed taps are the zeros
    z = np.roots(h[lo:hi])
    # also return how many zeros went to infinity
    return z, (len(h) - 1) - len(z)


# The actual filtering: y[n] = sum of h[k] * x[n-k]. 
# aligned=False, the output comes 12 samples late.
# aligned=True removes that delay.
def _fir(x, h, aligned):
    x = np.asarray(x)
    if aligned:
        d = group_delay_samples(h)
        # add d zeros at the end, filter, then remove the first d outputs (that is the delay)
        xp = np.concatenate([x, np.zeros(d, dtype=x.dtype)])
        return np.convolve(xp, h)[d:d + len(x)]
    # not aligned, just filter and keep the first len(x) outputs
    return np.convolve(x, h)[:len(x)]


# float low pass filter, uses _fir
def lpf(x, h, aligned=False):
    return _fir(x, h, aligned)


# The whole front end in float, mixer, then the same filter on I and on Q.
# Gives yi, yq with the data at +-0.5.
def rx_frontend(r, cos, sin, h, aligned=False):
    xi, xq = downconvert(r, cos, sin)
    return lpf(xi, h, aligned), lpf(xq, h, aligned)


# Q function (tail of the normal curve). Chance that noise is bigger than x standard deviations.
def _q(x):
    return 0.5 * erfc(np.asarray(x) / np.sqrt(2.0))


# Makes every possible group of (2*reach+1) symbols in a row. For reach=1 it is 3 symbols,
# so 4*4*4 = 64 groups. Returns I and Q of all the groups one after other.
def _all_symbol_blocks(reach):
    n_sym = 2 * reach + 1
    # one number for each group (0 to 4**n_sym - 1)
    idx = np.arange(4 ** n_sym)
    # write each number in base 4, every digit is one symbol
    code = np.stack([(idx // 4 ** k) % 4 for k in range(n_sym)], axis=1)
    # low bit of a digit is b0 -> I = 1-2*b0, high bit is b1 -> Q = 1-2*b1 (same mapping as TX)
    return (1 - 2 * (code & 1)).reshape(-1), (1 - 2 * (code >> 1)).reshape(-1)



# Signal part, run the clean chain on every possible group of symbols, see how far each decision is from 0.
# Noise part, the noise on the decision has a known variance, so error chance = Q(distance / noise std).
def ber_semi_analytic(h, ebn0_db):
    # filter delay, and how many symbols on each side can touch the middle symbol
    d_delay = 0 if h is None else group_delay_samples(h)
    reach = max(1, int(np.ceil(d_delay / SPS)))
    # this method only works for short filters, so stop if it is too long
    if reach > 2:
        raise ValueError("filter too long for the exact enumeration (order > 64)")

    # signal part, all possible groups of symbols
    I, Q = _all_symbol_blocks(reach)
    n = len(I) * SPS
    t = np.arange(n)
    cos = np.cos(2 * np.pi * FC_OVER_FS * t)
    sin = np.sin(2 * np.pi * FC_OVER_FS * t)
    # clean TX signal for all groups (same equation as TX, I*cos - Q*sin)
    s = np.repeat(I, SPS) * cos - np.repeat(Q, SPS) * sin
    # clean receiver, only the mixer if there is no filter.
    if h is None:
        xi, xq = downconvert(s, cos, sin)
        yi, yq = xi, xq
    else:
        yi, yq = rx_frontend(s, cos, sin, h, aligned=True)
    # add up 16 samples of every symbol to get the decision values
    dI = yi.reshape(-1, SPS).sum(axis=1)
    dQ = yq.reshape(-1, SPS).sum(axis=1)
    # pick the middle symbol of every group 
    centre = np.arange(len(I) // (2 * reach + 1)) * (2 * reach + 1) + reach
    # margin = how far the decision is on the correct side, bigger is safer
    margin_i = (I[centre] * dI[centre])
    margin_q = (Q[centre] * dQ[centre])

    # noise part: g = how much each noise sample counts in the final decision (16 ones * filter)
    g = np.ones(SPS) if h is None else np.convolve(np.ones(SPS), h)
    # time of every g sample, counted from the start of the symbol
    tt = np.arange(len(g)) - d_delay
    # noise variance on the I and Q decision (mixer multiplies the noise by cos for I, sin for Q)
    var_i = np.sum(g ** 2 * np.cos(2 * np.pi * FC_OVER_FS * tt) ** 2)
    var_q = np.sum(g ** 2 * np.sin(2 * np.pi * FC_OVER_FS * tt) ** 2)

    # noise std per sample
    sigma = np.sqrt(channel.noise_sigma2(ebn0_db, SPS, 1.0))
    # error chance = Q(margin / noise std), averaged over all groups, then average I and Q
    ber_i = _q(margin_i / (sigma * np.sqrt(var_i))).mean()
    ber_q = _q(margin_q / (sigma * np.sqrt(var_q))).mean()
    return 0.5 * (ber_i + ber_q)


# How many dB of Eb/N0 the filter costs us. We find the Eb/N0 where ideal theory gives the same
# BER, the gap is the loss. 0 dB means no loss.
def ber_penalty_db(h, ebn0_db):
    # BER of receiver
    ber = ber_semi_analytic(h, ebn0_db)
    # Eb/N0 where theory gives this same BER (searching between -10 and 30 dB)
    eff = brentq(lambda e: channel.theory_ber(e) - ber, -10.0, 30.0)
    # the difference is the loss
    return ebn0_db - eff


# cos and sin the receiver uses in float
def _local_carrier_float(n):
    t = np.arange(n)
    return np.cos(2 * np.pi * FC_OVER_FS * t), np.sin(2 * np.pi * FC_OVER_FS * t)


# counting the wrong bits on I and Q, then divide by the total number of bits
def _ber(I, Q, di, dq):
    n = min(len(I), len(di))
    errs = np.sum((di[:n] < 0) != (I[:n] < 0)) + np.sum((dq[:n] < 0) != (Q[:n] < 0))
    return errs / (2 * n)
