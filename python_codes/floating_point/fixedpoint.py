import numpy as np


# Round values to the nearest level supported by the selected bit width.
def quantize(x, bits, full_scale=1.0):
    """Round to a signed `bits`-bit grid and return FLOAT values (same units as x)."""
    levels = 2**(bits - 1)
    codes = np.round(np.array(x) * levels / full_scale)
    # Keep the rounded values within the signed number range.
    codes = np.clip(codes, -levels, levels - 1)
    return codes * full_scale / levels


# Convert floating-point values into signed integer codes.
def to_int(x, bits, full_scale=1.0):
    """Float -> signed integer codes: round(x * 2^(bits-1) / full_scale), clipped to the full range."""
    levels = 2**(bits - 1)
    codes = np.round(np.array(x) * levels / full_scale)
    # Clip values that do not fit in the selected number of bits.
    codes = np.clip(codes, -levels, levels - 1)
    return codes.astype(int)


# Limit integer values to the range allowed by the selected bit width.
def saturate(x, bits):
    """Clip an INTEGER array to the signed `bits`-bit range [-2^(bits-1), 2^(bits-1)-1]."""
    x = np.asarray(x)
    if not np.issubdtype(x.dtype, np.integer):
        raise TypeError("saturate() is for integer arrays; use to_int() to quantize floats")
    # Find the minimum and maximum values for a signed number.
    lo = -(1 << (bits - 1))
    hi = (1 << (bits - 1)) - 1
    return np.clip(x, lo, hi)


# Find the fraction of samples that would be clipped during conversion.
def clip_fraction(x, bits, full_scale=1.0):
    """Fraction of samples that would be clipped by to_int(x, bits, full_scale)."""
    levels = 2**(bits - 1)
    codes = np.round(np.array(x) * levels / full_scale)
    # Mark values that fall outside the allowed integer range.
    clipped = (codes < -levels) | (codes > levels - 1)
    return np.mean(clipped)


# Convert signed integer values into hexadecimal strings.
def to_hex(codes, bits):
    """Signed integer codes -> list of two's-complement hex strings, ceil(bits/4) digits each."""
    # Choose enough hexadecimal digits to represent the selected bit width.
    width = (bits + 3) // 4
    mask = (1 << bits) - 1
    out = []
    for c in codes:
        # Use two's-complement representation for negative values.
        out.append(format(int(c) & mask, '0%dx' % width))
    return out


# Write hexadecimal values to a file that can be read by Verilog.
def write_hex(filename, codes, bits):
    """Write one hex word per line, ready for Verilog $readmemh."""
    lines = to_hex(codes, bits)
    with open(filename, 'w') as f:
        for line in lines:
            f.write(line + '\n')


# Read hexadecimal values and convert them back to signed integers.
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
            # Convert values with the sign bit set back to negative integers.
            vals.append(v - full if v >= sign else v)
    return np.array(vals, dtype=np.int64)


if __name__ == "__main__":
    print("fixedpoint.py: helper module.")
