import sys
import os

import numpy as np
from params import SAMPLES_PER_SYMBOL as SPS
from params import CARRIER_CYCLES_PER_SYMBOL as CYCLES


# Calculate noise variance from Eb/N0.
def noise_sigma2(ebn0_db, sps=SPS, power=1.0):
    ebn0 = 10**(ebn0_db / 10)
    return power * sps / (4 * ebn0)


# Generate bits using a 16-bit LFSR.
def lfsr_bits(n, seed):
    state = seed & 0xFFFF
    if state == 0:
        state = 1
    bits = []
    for i in range(n):
        # Calculate the feedback bit and shift the state.
        bit = ((state >> 0) ^ (state >> 2) ^ (state >> 3) ^ (state >> 5)) & 1
        state = (state >> 1) | (bit << 15)
        bits.append(state & 1)
    return bits


# Pack 8 bits into one byte.
def lfsr_byte_stream(n_bytes, seed):
    bits = lfsr_bits(n_bytes * 8, seed)
    bits = np.array(bits).reshape(n_bytes, 8)
    weights = 2**np.arange(7, -1, -1)
    return bits.dot(weights)


# Approximate Gaussian noise using multiple byte streams.
def lfsr_gaussian(n, seed=1, k=6):
    total = np.zeros(n)
    for i in range(k):
        stream_seed = (seed * 1009 + i * 97) % 65535 + 1
        total += lfsr_byte_stream(n, stream_seed)

    # Center and scale the noise.
    mean = k * 127.5
    var = k * (256**2 - 1) / 12
    return (total - mean) / np.sqrt(var)


# Select the noise source.
def gaussian_noise(n, mode="numpy", seed=0):
    if mode == "numpy":
        rng = np.random.default_rng(seed)
        return rng.standard_normal(n)
    elif mode == "lfsr":
        return lfsr_gaussian(n, seed=seed if seed else 1)
    else:
        raise ValueError("mode must be numpy or lfsr")


# Add noise to the signal.
def awgn(s, ebn0_db, mode="numpy", seed=0, sps=SPS):
    s = np.array(s, dtype=float)
    power = np.mean(s**2)
    sigma = np.sqrt(noise_sigma2(ebn0_db, sps, power))
    noise = gaussian_noise(len(s), mode, seed)
    return s + sigma * noise


# Check the noise mean and variance.
def check_gaussian(x, label=""):
    print(label, "mean =", np.mean(x), " var =", np.var(x))


def q_func(x):
    from math import erfc, sqrt
    return 0.5 * erfc(x / sqrt(2))


# Calculate theoretical BER for QPSK.
def theory_ber(ebn0_db):
    return q_func(np.sqrt(2 * 10**(ebn0_db/10)))
