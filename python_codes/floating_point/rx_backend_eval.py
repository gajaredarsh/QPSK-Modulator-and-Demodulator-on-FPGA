import os

import numpy as np
import matplotlib.pyplot as plt
import params
import fixedpoint
import channel

SPS = params.SAMPLES_PER_SYMBOL
RX_IN_BITS = params.RX_IN_BITS
NOISELESS_LEVEL = SPS / 2.0                                  # |I_hat| for a clean symbol, float chain
ACC_BITS = RX_IN_BITS + int(np.ceil(np.log2(SPS)))         # worst-case integrate-and-dump width

def integrate_dump(yi, yq, timing_offset=0, sps=SPS):
# Sum each block of sps samples after skipping the timing offset.
# This acts as a rectangular-pulse matched filter and produces one accumulated I and Q value per complete symbol.

    yi = np.asarray(yi)[timing_offset:]
    yq = np.asarray(yq)[timing_offset:]
    n_sym = min(len(yi), len(yq)) // sps
    if n_sym == 0:
        raise ValueError("not enough samples for a single symbol")
    if np.issubdtype(yi.dtype, np.integer):
        yi, yq = yi.astype(np.int64), yq.astype(np.int64)
    I_hat = yi[:n_sym * sps].reshape(n_sym, sps).sum(axis=1)
    Q_hat = yq[:n_sym * sps].reshape(n_sym, sps).sum(axis=1)
    return I_hat, Q_hat


def decide(I_hat, Q_hat):
# Convert the signs of the I and Q values into bits (negative = 1).
# Return interleaved bits in the order [I0, Q0, I1, Q1, ...].
    bits = np.empty(2 * len(I_hat), dtype=np.uint8)
    bits[0::2] = np.asarray(I_hat) < 0
    bits[1::2] = np.asarray(Q_hat) < 0
    return bits


# 2. BER counter

def count_errors(tx_bits, rx_bits, skip_first=1, skip_last=1):
# Count bit errors between the transmitted and received streams.
# Compare only complete symbols shared by both streams and optionally skip edge symbols to avoid filter boundary effects.

    tx_bits = np.asarray(tx_bits)
    rx_bits = np.asarray(rx_bits)
    n_sym = min(len(tx_bits), len(rx_bits)) // 2
    lo, hi = skip_first, n_sym - skip_last
    if hi <= lo:
        raise ValueError("no symbols left to compare after skipping the edges")
    a = tx_bits[2 * lo:2 * hi]
    b = rx_bits[2 * lo:2 * hi]
    return int(np.count_nonzero(a != b)), int(a.size)


def ber(tx_bits, rx_bits, skip_first=1, skip_last=1):
# Calculate BER as the number of bit errors divided by the number of bits compared, excluding the selected edge symbols.
    errors, total = count_errors(tx_bits, rx_bits, skip_first, skip_last)
    return errors / total


# 3. Sweep bookkeeping

def bits_needed(expected_ber, min_errors=100, max_bits=1_500_000):
# Estimate the number of bits required to observe the target number of errors at the expected BER, subject to the maximum bit limit.
    n = int(np.ceil(min_errors / max(expected_ber, 1e-12)))
    return min(n, max_bits)


def z_score(errors, bits, expected_ber):
# Measure how far the observed error count differs from the expected count in units of standard deviations.
    mean = bits * expected_ber
    sd = np.sqrt(bits * expected_ber * (1.0 - expected_ber))
    return (errors - mean) / sd


def ber_sweep(run_chunk, ebn0_list, names, min_errors=100, max_bits=1_500_000,
              chunk_sym=50_000, seed0=1000, size_ber=channel.theory_ber):
            
# Run the chain at every Eb/N0 in ebn0_list.  run_chunk(ebn0_db, n_sym, seed) -> {name: (errors, bits)}   (supplied by main.py) Each point is built from chunks of chunk_sym symbols so memory stays small, and the number of chunks is chosen so the LOWEST expected BER (size_ber) still sees ~min_errors errors. Returns {name: {"ebn0": [...], "errors": [...], "bits": [...], "ber": [...]}}.
    out = {n: {"ebn0": [], "errors": [], "bits": [], "ber": []} for n in names}
    for idx, e in enumerate(ebn0_list):
        target = bits_needed(size_ber(e), min_errors, max_bits)
        n_chunks = max(1, int(np.ceil(target / (2 * chunk_sym))))
        chunks = [run_chunk(e, chunk_sym, seed0 + 1000 * idx + k) for k in range(n_chunks)]
        for n in names:
            errs = sum(c[n][0] for c in chunks)
            bits = sum(c[n][1] for c in chunks)
            out[n]["ebn0"].append(e)
            out[n]["errors"].append(errs)
            out[n]["bits"].append(bits)
            out[n]["ber"].append(errs / bits)
    return out


# 4. Plots

def plot_ber(sim, lines, path):
# Plot simulated BER curves alongside reference curves such as theory or exact predictions, then save the figure to the specified path.

    fig, ax = plt.subplots(figsize=(7, 5))
    for label, (x, y) in lines.items():
        ax.semilogy(x, y, "-", label=label)
    for label, (x, y) in sim.items():
        ax.semilogy(x, y, "o", mfc="none", ms=8, label=label)
    ax.set_xlabel("Eb/N0 (dB)")
    ax.set_ylabel("BER")
    ax.set_ylim(1e-5, 1)
    ax.grid(True, which="both", alpha=0.4)
    ax.legend(fontsize=8)
    ax.set_title("QPSK BER vs Eb/N0")
    fig.tight_layout()
    fig.savefig(path, dpi=150)
    plt.close(fig)


def plot_constellations(panels, path, scale=NOISELESS_LEVEL):
# Plot the received I/Q decision values at different noise levels to visualize the QPSK constellation and the effect of noise.
    fig, axes = plt.subplots(1, len(panels), figsize=(5 * len(panels), 5), squeeze=False)
    for ax, (title, I_hat, Q_hat) in zip(axes[0], panels):
        ax.scatter(np.asarray(I_hat) / scale, np.asarray(Q_hat) / scale, s=3, alpha=0.4)
        ax.plot([-1, -1, 1, 1], [-1, 1, -1, 1], "r+", ms=14, mew=2)
        ax.axhline(0, color="gray", lw=0.5)
        ax.axvline(0, color="gray", lw=0.5)
        ax.set_aspect("equal")
        ax.set_title(title)
        ax.set_xlabel("I")
        ax.set_ylabel("Q")
        ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(path, dpi=150)
    plt.close(fig)


# 5. Hex export for the Verilog testbench

def fits_signed(x, bits):
# Check whether every value fits within the specified signed bit width.
    x = np.asarray(x)
    return bool(x.min() >= -(1 << (bits - 1)) and x.max() <= (1 << (bits - 1)) - 1)


def write_vectors(out_dir, vectors):
# Write signal values to hexadecimal files using the specified bit widths so they can be loaded and checked by the Verilog testbench.
    os.makedirs(out_dir, exist_ok=True)
    for name, (codes, bits) in vectors.items():
        fixedpoint.write_hex(os.path.join(out_dir, name), codes, bits)
