"""
main_fixed.py
the FIXED-POINT (integer) end-to-end runner.

Runs the chain with the exact integer widths the RTL will use (12-bit NCO, 13-bit TX mixer, 12-bit receiver input, 12-bit taps, 16-bit integrate-and-dump accumulator) using the modules in this folder, and proves it still behaves like the float chain:

    1. noiseless integer chain gives exactly 0 errors, accumulators fit 16 bits
    2. causal FIR + timing_offset = D gives IDENTICAL integers to aligned FIR + offset 0
    3. integer BER sweep, with and without the FIR, against theory and the exact curve
    4. constellation plots
    5. 4 dB scenario (fixed bits and noise) saved so the integer chain can be compared with float
    6. hardware-style LFSR noise, short run (BER saved; compared with the exact prediction later)
    7. golden hex vectors for the Part D Verilog testbench, read back and verified



Notes:
  * Sweeps use numpy noise. channel.py's LFSR noise repeats exactly every 65535 samples (about 4096 symbols), so it is only used for short runs and for the golden vectors.
  * The golden vectors use the PRBS-7 source (the same LFSR the RTL will have).
"""

import os
import sys

import numpy as np

import params
import fixedpoint
import channel
import tx_nco
import rx_frontend as F
import rx_backend_eval as D

SPS = params.SAMPLES_PER_SYMBOL
QUICK = "--quick" in sys.argv

OUT_DIR = "d_outputs"
GOLDEN_DIR = "d_outputs/golden"

H = F.design_lpf()                               # float taps (designed here, then quantized)
H_INT = F.quantize_coeffs(H, F.COEF_BITS)        # 12-bit taps, DC gain exactly 1
D_FIR = F.group_delay_samples(H_INT)             # 12 samples

SAVE_FILES = True                         # plots / golden vectors (compare_results.py turns this off)


# Chain building blocks

def tx_fixed(bits):
    #Integer TX. Phase is back to 0 at every symbol (2 whole carrier cycles), so one symbol of NCO output tiled n_sym times equals running the NCO for the whole run.
    I, Q = tx_nco.map_qpsk(bits)
    n_sym = len(I)
    c1, s1 = tx_nco.nco_fixed(SPS)
    cos_int = np.tile(c1, n_sym)
    sin_int = np.tile(s1, n_sym)
    s_fix = tx_nco.modulate_fixed(I, Q, cos_int, sin_int, SPS)
    return I, Q, s_fix, cos_int, sin_int


def channel_fixed(s_fix, ebn0_db, mode="numpy", seed=0):
    #Float AWGN on the TX word (rescaled to unit amplitude), then the receiver's ADC step.
    r = channel.awgn(s_fix / params.DATAPATH_FULL_SCALE, ebn0_db, mode=mode, seed=seed)
    return r, F.quantize_rx(r)


def rx_fixed(r_int, cos_int, sin_int, h_int, aligned=True):
    # h_int=None means no FIR: mixer output goes straight to integrate-and-dump.
    if h_int is None:
        return F.downconvert_fixed(r_int, cos_int, sin_int)
    return F.rx_frontend_fixed(r_int, cos_int, sin_int, h_int, aligned=aligned)


def decode(yi, yq, timing_offset=0):
    I_hat, Q_hat = D.integrate_dump(yi, yq, timing_offset)
    return I_hat, Q_hat, D.decide(I_hat, Q_hat)


def simulate(ebn0_db, n_sym, seed, noise_mode="numpy"):
    rng = np.random.default_rng(seed)
    bits = rng.integers(0, 2, 2 * n_sym).astype(np.uint8)
    I, Q, s_fix, cos_i, sin_i = tx_fixed(bits)
    _, r_int = channel_fixed(s_fix, ebn0_db, noise_mode, seed + 1)
    return bits, r_int, cos_i, sin_i


def run_chunk(ebn0_db, n_sym, seed):
    # One chunk of the sweep: the same noisy r_int decoded without and with the FIR.
    bits, r_int, cos_i, sin_i = simulate(ebn0_db, n_sym, seed)
    out = {}
    for name, h_int in (("no_fir", None), ("fir", H_INT)):
        yi, yq = rx_fixed(r_int, cos_i, sin_i, h_int, aligned=True)
        out[name] = D.count_errors(bits, decode(yi, yq)[2])
    return out


# 1. Noiseless sanity (gate: must be exactly zero errors)

def check_noiseless():
    print("\n Check 1: noiseless integer chain must give exactly 0 errors")
    bits = np.random.default_rng(1).integers(0, 2, 4000).astype(np.uint8)
    I, Q, s_fix, cos_i, sin_i = tx_fixed(bits)
    r_int = F.quantize_rx(s_fix / params.DATAPATH_FULL_SCALE)

    for name, h_int, aligned, off in (("no FIR", None, True, 0),
                                      ("FIR aligned", H_INT, True, 0),
                                      ("FIR causal", H_INT, False, D_FIR)):
        yi, yq = rx_fixed(r_int, cos_i, sin_i, h_int, aligned)
        I_hat, Q_hat, rx_bits = decode(yi, yq, off)
        errs, total = D.count_errors(bits, rx_bits)
        print(f"  {name:12s}: {errs} errors / {total} bits | max |accumulator| "
              f"{int(max(np.abs(I_hat).max(), np.abs(Q_hat).max()))}")
        assert errs == 0, f"{name}: integer chain is broken"
        assert D.fits_signed(I_hat, D.ACC_BITS) and D.fits_signed(Q_hat, D.ACC_BITS)
    print(f"  widths: NCO {params.DATAPATH_BITS} | TX mixer {params.MIXER_OUT_BITS} | RX input "
          f"{F.RX_IN_BITS} | taps {F.COEF_BITS} | I&D accumulator {D.ACC_BITS} bits signed")
    print("PASS")


# 2. Causal vs aligned timing (integers, so the match must be EXACT)

def check_timing():
    print("\n Check 2: causal FIR + offset D is bit-identical to aligned FIR + offset 0 ")
    bits, r_int, cos_i, sin_i = simulate(6.0, 500, seed=9)
    yi_c, yq_c = rx_fixed(r_int, cos_i, sin_i, H_INT, aligned=False)
    yi_a, yq_a = rx_fixed(r_int, cos_i, sin_i, H_INT, aligned=True)
    Ic, Qc, _ = decode(yi_c, yq_c, timing_offset=D_FIR)
    Ia, Qa, _ = decode(yi_a, yq_a, timing_offset=0)
    n = len(Ic)
    assert np.array_equal(Ic, Ia[:n]) and np.array_equal(Qc, Qa[:n])
    print(f"  {n} of {len(Ia)} symbols compared, accumulators identical integer for integer.")
    wrong = decode(yi_c, yq_c, timing_offset=0)[0]
    assert not np.array_equal(wrong[:n], Ia[:n])
    print("  and timing_offset = 0 on the causal stream does NOT match, so the offset matters.")
    print("PASS")


# 3. BER sweep

def sweep():
    print("\n Check 3: integer BER vs Eb/N0, without and with the FIR ")
    ebn0_list = [0, 2, 4, 6, 8]
    max_bits = 200_000 if QUICK else 1_500_000
    names = ["no_fir", "fir"]
    res = D.ber_sweep(run_chunk, ebn0_list, names, min_errors=100, max_bits=max_bits)

    theory = [channel.theory_ber(e) for e in ebn0_list]
    print(f"{'Eb/N0':>6s} {'bits':>9s} | {'no-FIR':>9s} {'theory':>9s} {'z':>5s} | {'FIR':>9s}")
    for k, e in enumerate(ebn0_list):
        b0, b1 = res["no_fir"], res["fir"]
        z0 = D.z_score(b0["errors"][k], b0["bits"][k], theory[k])
        print(f"{e:6.1f} {b0['bits'][k]:9d} | {b0['ber'][k]:9.3e} {theory[k]:9.3e} {z0:5.1f} | "
              f"{b1['ber'][k]:9.3e}")
        if not QUICK:
            assert abs(z0) < 4, "integer chain without FIR disagrees with ideal QPSK theory"

    print("PASS: the no-FIR integer curve sits on theory (FIR curve is checked against the exact "
          "prediction by compare_results.py)." if not QUICK else "(quick mode: statistics not asserted)")
    if SAVE_FILES:
        fine = np.arange(0, 8.01, 0.25)
        path = os.path.join(OUT_DIR, "fixed_ber_curve.png")
        D.plot_ber(
            sim={"integer, no FIR": (ebn0_list, res["no_fir"]["ber"]),
                 "integer, FIR": (ebn0_list, res["fir"]["ber"])},
            lines={"theory Q(sqrt(2Eb/N0))": (fine, [channel.theory_ber(e) for e in fine])},
            path=path)
        print(f"wrote {path}")

    results = {"ebn0": np.array(ebn0_list, dtype=float)}
    for n in names:
        results[f"err_{n}"] = np.array(res[n]["errors"])
        results[f"bits_{n}"] = np.array(res[n]["bits"])
        results[f"ber_{n}"] = np.array(res[n]["ber"])
    return results


# 4. Constellations

def constellations():
    if not SAVE_FILES:
        return
    print("\n Check 4: constellation plots (integer chain, FIR, aligned) ")
    panels = []
    for e in (0.0, 6.0, 12.0):
        bits, r_int, cos_i, sin_i = simulate(e, 3000, seed=21)
        yi, yq = rx_fixed(r_int, cos_i, sin_i, H_INT, aligned=True)
        I_hat, Q_hat, _ = decode(yi, yq)
        panels.append((f"Eb/N0 = {e:.0f} dB", I_hat[1:-1], Q_hat[1:-1]))
    path = f"{OUT_DIR}/fixed_constellations.png"
    D.plot_constellations(panels, path, scale=D.NOISELESS_LEVEL)
    print(f"wrote {path}")


# 5. Shared 4 dB scenario (the float folder runs the identical one)


SCENARIO_EBN0_DB = 4.0
SCENARIO_N_SYM = 100_000      # same in both folders, in quick mode too, so the results line up
SCENARIO_BIT_SEED = 5
SCENARIO_NOISE_SEED = 11


def check_scenario():
    print(f"\nCheck 5: shared {SCENARIO_EBN0_DB:g} dB scenario (same bits, same noise as the float run) ")
    bits = np.random.default_rng(SCENARIO_BIT_SEED).integers(0, 2, 2 * SCENARIO_N_SYM).astype(np.uint8)
    I, Q, s_fix, cos_i, sin_i = tx_fixed(bits)
    r_fx, r_int = channel_fixed(s_fix, SCENARIO_EBN0_DB, "numpy", seed=SCENARIO_NOISE_SEED)
    clip = fixedpoint.clip_fraction(r_fx, F.RX_IN_BITS, F.RX_FULL_SCALE)
    yi, yq = rx_fixed(r_int, cos_i, sin_i, H_INT, aligned=True)
    I_hat, Q_hat, rx_bits = decode(yi, yq)
    ber_fx = D.ber(bits, rx_bits)
    acc_max = int(max(np.abs(I_hat).max(), np.abs(Q_hat).max()))
    print(f"  input clipping fraction {clip:.2e} | max |accumulator| {acc_max} "
          f"(limit {(1 << (D.ACC_BITS - 1)) - 1})")
    print(f"  BER integer {ber_fx:.5f}")
    assert D.fits_signed(I_hat, D.ACC_BITS) and D.fits_signed(Q_hat, D.ACC_BITS)

    print("PASS: accumulator never overflows.")
    return dict(
        scen_ebn0=SCENARIO_EBN0_DB, scen_bits_tx=bits, scen_bits_rx=rx_bits, scen_ber=ber_fx,
        scen_I=(I_hat / D.NOISELESS_LEVEL).astype(np.float32),
        scen_Q=(Q_hat / D.NOISELESS_LEVEL).astype(np.float32),
        clip_fraction=clip, acc_max=acc_max, acc_bits=D.ACC_BITS,
        noiseless_level=D.NOISELESS_LEVEL)


# 6. LFSR (hardware-style) noise, short run

def check_lfsr_noise():
    print("\n Check 6: hardware-style LFSR noise, 4000 symbols at 2 dB ")
    bits = tx_nco.gen_bits(2 * 4000)
    I, Q, s_fix, cos_i, sin_i = tx_fixed(bits)
    _, r_int = channel_fixed(s_fix, 2.0, "lfsr", seed=3)
    yi, yq = rx_fixed(r_int, cos_i, sin_i, H_INT, aligned=True)
    measured = D.ber(bits, decode(yi, yq)[2])
    print(f"  BER measured {measured:.4f}  (compared with the exact prediction by compare_results.py)")
    assert 0.0 < measured < 0.5
    print("PASS")
    return dict(lfsr_ber=measured)


# 7. Golden vectors for the Verilog testbench

def export_golden(n_sym=128, ebn0_db=6.0):
    print("\n Check 7: golden vectors for the integrate-and-dump + decision RTL ")
    bits = tx_nco.gen_bits(2 * n_sym)                       # PRBS-7, same as the RTL source
    I, Q, s_fix, cos_i, sin_i = tx_fixed(bits)
    _, r_int = channel_fixed(s_fix, ebn0_db, "lfsr", seed=3)
    yi, yq = rx_fixed(r_int, cos_i, sin_i, H_INT, aligned=False)   # causal, like the RTL
    acc_i, acc_q, rx_bits = decode(yi, yq, timing_offset=D_FIR)
    assert D.fits_signed(acc_i, D.ACC_BITS) and D.fits_signed(acc_q, D.ACC_BITS)
    n = len(acc_i)
    errs, total = D.count_errors(bits, rx_bits)

    vectors = {
        "d_yi.hex": (yi, F.RX_IN_BITS),          # input stream, I branch   (12 bit)
        "d_yq.hex": (yq, F.RX_IN_BITS),          # input stream, Q branch   (12 bit)
        "d_acc_i.hex": (acc_i, D.ACC_BITS),      # expected accumulator, I  (16 bit)
        "d_acc_q.hex": (acc_q, D.ACC_BITS),      # expected accumulator, Q  (16 bit)
        "d_bits_tx.hex": (bits[:2 * n], 1),      # transmitted bits         (1 bit)
        "d_bits_rx.hex": (rx_bits, 1),           # expected decisions       (1 bit)
    }
    print(f"  {n} symbols, offset {D_FIR}, accumulators {D.ACC_BITS} bit, {errs} errors / {total} bits")
    if SAVE_FILES:
        D.write_vectors(GOLDEN_DIR, vectors)
        with open(os.path.join(GOLDEN_DIR, "info.txt"), "w") as f:
            f.write(f"samples per symbol : {SPS}\n")
            f.write(f"timing offset      : {D_FIR} samples (causal FIR group delay)\n")
            f.write(f"input width        : {F.RX_IN_BITS} bits signed\n")
            f.write(f"accumulator width  : {D.ACC_BITS} bits signed\n")
            f.write(f"symbols exported   : {n}\n")
            f.write(f"channel            : lfsr noise, Eb/N0 = {ebn0_db} dB\n")
            f.write(f"errors (edges skipped): {errs} / {total}\n")

        # read every file back: what the testbench will load must equal what we computed
        for name, (codes, width) in vectors.items():
            back = fixedpoint.read_hex(os.path.join(GOLDEN_DIR, name), width)
            want = np.asarray(codes, dtype=np.int64)
            if width == 1:                           # 1-bit words are unsigned bits here
                back = back & 1
            assert np.array_equal(back, want), f"{name}: hex file does not read back to the same values"
        print(f"  wrote 6 hex files + info.txt to {GOLDEN_DIR} and read them all back identical")
    print("PASS")


def main():
    #Run every check. Returns the numbers compare_results.py needs; saves no results file.
    if SAVE_FILES:
        os.makedirs(OUT_DIR, exist_ok=True)
    print("FIXED-POINT run" + ("  (quick mode)" if QUICK else ""))

    check_noiseless()
    check_timing()
    results = sweep()
    constellations()
    results.update(check_scenario())
    results.update(check_lfsr_noise())
    export_golden()

    print("All fixed-point checks completed and PASSED (every check above is an assert).")
    return results


if __name__ == "__main__":
    main()
