"""
Helper functions for fixed-point conversion and hex file handling.
"""

import numpy as np


# Round values to fixed-point levels.
def quantize(x, bits, full_scale=1.0):
    """Round to a signed `bits`-bit grid and return FLOAT values (same units as x)."""
    levels = 2**(bits - 1)
    codes = np.round(np.array(x) * levels / full_scale)
    codes = np.clip(codes, -levels, levels - 1)
    return codes * full_scale / levels


# Convert values to signed integers.
def to_int(x, bits, full_scale=1.0):
    """Float -> signed integer codes: round(x * 2^(bits-1) / full_scale), clipped to the full range."""
    levels = 2**(bits - 1)
    codes = np.round(np.array(x) * levels / full_scale)
    codes = np.clip(codes, -levels, levels - 1)
    return codes.astype(int)


# Keep values within the allowed range.
def saturate(x, bits):
    """Clip an INTEGER array to the signed `bits`-bit range [-2^(bits-1), 2^(bits-1)-1]."""
    x = np.asarray(x)
    if not np.issubdtype(x.dtype, np.integer):
        raise TypeError("saturate() is for integer arrays; use to_int() to quantize floats")
    lo = -(1 << (bits - 1))
    hi = (1 << (bits - 1)) - 1
    return np.clip(x, lo, hi)


# Check how many values exceed the allowed range.
def clip_fraction(x, bits, full_scale=1.0):
    """Fraction of samples that would be clipped by to_int(x, bits, full_scale)."""
    levels = 2**(bits - 1)
    codes = np.round(np.array(x) * levels / full_scale)
    clipped = (codes < -levels) | (codes > levels - 1)
    return np.mean(clipped)


# Convert signed integers to hexadecimal.
def to_hex(codes, bits):
    """Signed integer codes -> list of two's-complement hex strings, ceil(bits/4) digits each."""
    width = (bits + 3) // 4
    mask = (1 << bits) - 1
    out = []
    for c in codes:
        out.append(format(int(c) & mask, '0%dx' % width))
    return out


# Save values in a hex file for Verilog.
def write_hex(filename, codes, bits):
    """Write one hex word per line, ready for Verilog $readmemh."""
    lines = to_hex(codes, bits)
    with open(filename, 'w') as f:
        for line in lines:
            f.write(line + '\n')


# Read hex values back as signed integers.
def read_hex(filename, bits):
    """Read a file written by write_hex() back into signed integers."""
    sign = 1 << (bits - 1)
    full = 1 << bits
    vals = []
    with open(filename) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            v = int(line, 16)
            vals.append(v - full if v >= sign else v)
    return np.array(vals, dtype=np.int64)


if __name__ == "__main__":
    print("fixedpoint.py: helper module. Run `pytest -v` to verify it (test_part_b.py).")
