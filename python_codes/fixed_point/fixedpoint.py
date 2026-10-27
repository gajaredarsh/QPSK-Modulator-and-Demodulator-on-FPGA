import numpy as np


# Round values to the nearest level supported by the selected bit width.
def quantize(x, bits, full_scale=1.0):
    levels = 2**(bits - 1)
    codes = np.round(np.array(x) * levels / full_scale)

    # Keep values within the signed number range.
    codes = np.clip(codes, -levels, levels - 1)
    return codes * full_scale / levels


# Convert floating-point values to signed integers.
def to_int(x, bits, full_scale=1.0):
    levels = 2**(bits - 1)
    codes = np.round(np.array(x) * levels / full_scale)

    # Clip values that do not fit in the selected bit width.
    codes = np.clip(codes, -levels, levels - 1)
    return codes.astype(int)


# Keep integer values within the selected bit width.
def saturate(x, bits):
    x = np.asarray(x)
    if not np.issubdtype(x.dtype, np.integer):
        raise TypeError("saturate() is for integer arrays; use to_int() to quantize floats")

    # Find the minimum and maximum allowed values.
    lo = -(1 << (bits - 1))
    hi = (1 << (bits - 1)) - 1
    return np.clip(x, lo, hi)


# Check how many values would be clipped during conversion.
def clip_fraction(x, bits, full_scale=1.0):
    levels = 2**(bits - 1)
    codes = np.round(np.array(x) * levels / full_scale)

    # Find values outside the allowed integer range.
    clipped = (codes < -levels) | (codes > levels - 1)
    return np.mean(clipped)


# Convert signed integers to hexadecimal strings.
def to_hex(codes, bits):
    # Choose enough hexadecimal digits for the selected bit width.
    width = (bits + 3) // 4
    mask = (1 << bits) - 1
    out = []

    for c in codes:
        # Use two's complement to represent negative values.
        out.append(format(int(c) & mask, '0%dx' % width))

    return out


# Save hexadecimal values in a file for Verilog.
def write_hex(filename, codes, bits):
    lines = to_hex(codes, bits)

    with open(filename, 'w') as f:
        for line in lines:
            f.write(line + '\n')


# Read hexadecimal values and convert them back to signed integers.
def read_hex(filename, bits):
    sign = 1 << (bits - 1)
    full = 1 << bits
    vals = []

    with open(filename) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue

            v = int(line, 16)

            # Convert values with the sign bit set to negative integers.
            vals.append(v - full if v >= sign else v)

    return np.array(vals, dtype=np.int64)


if __name__ == "__main__":
    print("fixedpoint.py: helper module.")
