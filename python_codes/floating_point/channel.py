import sys
import os

import numpy as np
from params import SAMPLES_PER_SYMBOL as SPS
from params import CARRIER_CYCLES_PER_SYMBOL as CYCLES


# Calculate the noise variance for the given Eb/N0 value.
def noise_sigma2(ebn0_db, sps=SPS, power=1.0):
    # Convert Eb/N0 from dB to a normal ratio before calculating the variance.
    ebn0 = 10**(ebn0_db / 10)
    return power * sps / (4 * ebn0)


# Generate a sequence of bits using a 16-bit LFSR.
def lfsr_bits(n, seed):
    state = seed & 0xFFFF
    if state == 0:
        state = 1
    bits = []
    for i in range(n):
        # XOR the selected state bits to get the feedback bit.
        bit = ((state >> 0) ^ (state >> 2) ^ (state >> 3) ^ (state >> 5)) & 1
        # Shift the state and store the new output bit.
        state = (state >> 1) | (bit << 15)
        bits.append(state & 1)
    return bits


# Group every eight generated bits to form a byte.
def lfsr_byte_stream(n_bytes, seed):
    bits = lfsr_bits(n_bytes * 8, seed)
    bits = np.array(bits).reshape(n_bytes, 8)
    # Give the first bit the highest place value in each byte.
    weights = 2**np.arange(7, -1, -1)
    return bits.dot(weights)


# Generate noise that roughly follows a Gaussian distribution.
def lfsr_gaussian(n, seed=1, k=6):
    total = np.zeros(n)
    for i in range(k):
        # Use a different seed for each byte stream.
        stream_seed = (seed * 1009 + i * 97) % 65535 + 1
        total += lfsr_byte_stream(n, stream_seed)

    # Subtract the mean and scale the values to get roughly unit variance.
    mean = k * 127.5
    var = k * (256**2 - 1) / 12
    return (total - mean) / np.sqrt(var)


# Generate noise using either NumPy or the LFSR method.
def gaussian_noise(n, mode="numpy", seed=0):
    if mode == "numpy":
        rng = np.random.default_rng(seed)
        return rng.standard_normal(n)
    elif mode == "lfsr":
        return lfsr_gaussian(n, seed=seed if seed else 1)
    else:
        raise ValueError("mode must be numpy or lfsr")


# Add noise to the input signal for the selected Eb/N0 value.
def awgn(s, ebn0_db, mode="numpy", seed=0, sps=SPS):
    s = np.array(s, dtype=float)
    # Use the actual signal power to calculate the required noise level.
    power = np.mean(s**2)
    sigma = np.sqrt(noise_sigma2(ebn0_db, sps, power))
    noise = gaussian_noise(len(s), mode, seed)
    return s + sigma * noise


# Print the mean and variance to check the generated noise.
def check_gaussian(x, label=""):
    print(label, "mean =", np.mean(x), " var =", np.var(x))


def q_func(x):
    from math import erfc, sqrt
    return 0.5 * erfc(x / sqrt(2))


# Calculate the theoretical BER of QPSK in an AWGN channel.
def theory_ber(ebn0_db):
    return q_func(np.sqrt(2 * 10**(ebn0_db/10)))
