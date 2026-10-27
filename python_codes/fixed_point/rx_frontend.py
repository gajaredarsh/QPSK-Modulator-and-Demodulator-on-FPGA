#rx_frontend.py (fixed point)
# this part was written by Aditya 

# Same receiver as the float file but with whole numbers only. The Verilog has to match this exactly.

import os
import sys                         

import numpy as np
from scipy import signal            #this is used by design_lpf (firwin)
import params
import fixedpoint               


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


#Keeps an integer inside the signed range of bits (12 bits means -2048 to 2047).
#Hardware clips like this instead of wrapping around.
def _sat(x, bits):
    hi = (1 << (bits - 1)) - 1
    lo = -(1 << (bits - 1))
    return np.clip(x, lo, hi)


#How many samples the filter delays the signal. For a symmetric filter it is (taps-1)/2, so 12 for us.
# Same as the floating pt version is copied here.
def group_delay_samples(h):
    h = np.asarray(h)
    # h[::-1] is h reversed, a symmetric filter looks the same both ways
    if len(h) % 2 == 0 or not np.allclose(h, h[::-1]):
        raise ValueError("filter is not a symmetric odd-length (linear-phase type I) FIR")
    return (len(h) - 1) // 2


#Makes the 25 float taps (low pass, Hamming window), same as in the floating point.
# quantize_coeffs() rounds them to whole numbers later.
def design_lpf(order=FIR_ORDER, fc=FIR_FC, window=FIR_WINDOW):
    # order must be even so the delay (order/2) is a whole number of samples
    if order % 2 != 0:
        raise ValueError("order must be even")
    # fc must be between 0 and 0.5 (cycles per sample)
    if not (0.0 < fc < 0.5):
        raise ValueError("fc is in cycles/sample and must be between 0 and 0.5")
    return signal.firwin(order + 1, fc, window=window, fs=1.0)



# The actual filtering: y[n] = sum of h[k] * x[n-k].
# aligned=False, the output comes 12 samples late.
# aligned=True removes that delay.
def _fir(x, h, aligned):
    x = np.asarray(x)
    if aligned:
        d =group_delay_samples(h)
        #add d zeros at the end, filter, then throw away the first d outputs (that is the delay)
        xp = np.concatenate([x, np.zeros(d, dtype=x.dtype)])
        return np.convolve(xp, h)[d:d + len(x)]
    #not aligned, just filter and keep the first len(x) outputs
    return np.convolve(x, h)[:len(x)]


# This is the receiver's ADC. Float received signal to 12 bit whole numbers.
# code = round(r * 2048 / 8.0), so 1 becomes 256.
# Full scale is 8 because at 0 dB the noise std is 2, so 8 is 4 sigma.
def quantize_rx(r, bits=RX_IN_BITS, full_scale=RX_FULL_SCALE):
    return fixedpoint.to_int(r, bits, full_scale)


# Integer mixer, this is what rx_mixer.v has to do. xi = r*cos, xq = -r*sin.
# cos and sin are about 2048 times bigger than the real values, so at the end we shift right
# by 11 (divide by 2048). The +1024 before the shift makes it round to the nearest number.
def downconvert_fixed(r_int, cos_int, sin_int, lo_bits=params.DATAPATH_BITS, out_bits=RX_IN_BITS):
    # int64 so the multiplication can never overflow
    r_int = np.asarray(r_int, dtype=np.int64)
    
    # cut the carrier to the same length as the signal
    c = np.asarray(cos_int[:len(r_int)], dtype=np.int64)
    s = np.asarray(sin_int[:len(r_int)], dtype=np.int64)
    
    # shift = 11 (divide by 2048), rnd = 1024 (half of 2048)
    shift = lo_bits - 1
    rnd = 1 << (shift - 1)
    
    # multiply, add the rounding part, shift. For q the minus sign goes on sin
    xi = (r_int * c + rnd) >> shift
    xq = (-(r_int * s) + rnd) >> shift
    
    # clip to 12 bits 
    return _sat(xi, out_bits), _sat(xq, out_bits)


# Float taps, whole numbers where 1.0 means 2048 
# Rounding can make the sum 2045 instead of 2048, so we put the missing amount in the centre tap.
# That way the filter gain at 0 Hz is exactly 1 and the filter is still symmetric.
def quantize_coeffs(h, bits=COEF_BITS, preserve_dc=True):
    # round(h * 2048)
    h_int = fixedpoint.to_int(h, bits, full_scale=1.0)
    if preserve_dc:
        # missing amount = 2048 - current sum. The centre tap has no mirror partner so it is safe to change
        h_int[len(h_int) // 2] += (1 << (bits - 1)) - int(h_int.sum())
    return h_int


# Integer taps back to float (divide by 2048) so we can plot and analyse.
def coeffs_to_float(h_int, bits=COEF_BITS):
    return np.asarray(h_int, dtype=float) / (1 << (bits - 1))


# How many bits the filter's adder needs so it can never overflow (from the Verilog pov).
# Worst case = every input at full size with the sign matching each tap, so sum of |taps| * 2048.
def acc_bits_needed(h_int, x_bits=RX_IN_BITS):
    # biggest value the sum can reach
    worst = int(np.abs(h_int).sum()) * (1 << (x_bits - 1))
    # bits for that value, +1 for the sign bit
    return int(np.ceil(np.log2(worst + 1))) + 1


# Integer filter, this is what rx_fir.v has to do. Multiply and add exactly (int64),
# then shift right by 11 to remove the x2048 that the taps have.
# The +1024 makes the shift round to the nearest, then we clip to 12 bits.
def lpf_fixed(x_int, h_int, coef_bits=COEF_BITS, out_bits=RX_IN_BITS, aligned=False):
    acc = _fir(np.asarray(x_int, dtype=np.int64), np.asarray(h_int, dtype=np.int64), aligned)
    shift = coef_bits - 1
    y = (acc + (1 << (shift - 1))) >> shift
    return _sat(y, out_bits)


# The whole front end in integers, mixer, then the filter on I and on Q.
def rx_frontend_fixed(r_int, cos_int, sin_int, h_int, aligned=False):
    xi, xq = downconvert_fixed(r_int, cos_int, sin_int)
    return lpf_fixed(xi, h_int, aligned=aligned), lpf_fixed(xq, h_int, aligned=aligned)


#this is for writing hex files for the Verilog testbench: taps, input, cos, sin, expected mixer output
# and expected filter output. The testbench gives rx_r and cos/sin as input and must get the
# other files back exactly. 
def export_rx_vectors(out_dir, h_int, r_int, cos_int, sin_int, n_vec=2048):
    os.makedirs(out_dir, exist_ok=True)
    #only use the first n_vec samples
    r_v = r_int[:n_vec]
    c_v = cos_int[:n_vec]
    s_v = sin_int[:n_vec]
    #run them through the integer mixer and filter to get the expected outputs
    xi, xq = downconvert_fixed(r_v, c_v, s_v)
    yi = lpf_fixed(xi, h_int)
    yq = lpf_fixed(xq, h_int)

    #to save one file inside out_dir
    def w(name, codes, bits):
        fixedpoint.write_hex(os.path.join(out_dir, name), codes, bits)

    # save everything (the number is how many bits each value has)
    w("fir_coeffs.hex", h_int, COEF_BITS)
    w("rx_r.hex", r_v, RX_IN_BITS)
    w("lo_cos.hex", c_v, params.DATAPATH_BITS)
    w("lo_sin.hex", s_v, params.DATAPATH_BITS)
    w("rx_xi.hex", xi, RX_IN_BITS)
    w("rx_xq.hex", xq, RX_IN_BITS)
    w("rx_yi.hex", yi, RX_IN_BITS)
    w("rx_yq.hex", yq, RX_IN_BITS)
    return xi, xq, yi, yq
