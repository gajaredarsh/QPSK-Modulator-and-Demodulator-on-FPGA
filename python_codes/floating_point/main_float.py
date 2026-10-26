"""
main_float.py
Part D of the QPSK FPGA project golden model: the FLOATING-POINT end-to-end runner.

Uses only the modules in this folder (tx_nco, channel, rx_frontend, rx_backend_eval) and runs
the checks that prove the ALGORITHM is right before any bit-width is chosen:

    1. noiseless chain gives exactly 0 errors (no FIR, FIR aligned, FIR causal)
    2. causal FIR + timing_offset = D gives the same decisions as aligned FIR + offset 0
    3. BER sweep, with and without the FIR, against theory and Part C's exact curve
    4. constellation plots
    5. hardware-style LFSR noise gives the predicted BER (short run, see note below)
    6. the shared 4 dB scenario (fixed bits and noise), saved for the comparison with the integer chain

The integer version of the same chain is in ../fixed_point/main_fixed.py. main() returns the numbers
that ../compare_results.py compares; no results file is saved (only the plots).

Run:   python main_float.py            (full run)
       python main_float.py --quick    (smaller sweep, for a fast check)

Author: Darsh (Part D)
AI-assistance note: first draft written with Claude (Sonnet 5.5, Anthropic) as allowed by the
    EE2000 AI-usage policy. The author must be able to explain and defend all of it in the viva.

Notes:
  * Sweeps use numpy noise. channel.py's LFSR noise repeats exactly every 65535 samples
    (about 4096 symbols at 16 samples/symbol), so it is only used for short runs.
  * Sweep bits are numpy random, not the PRBS-7 (period 127 bits), so the statistics are not
    tied to one short repeating pattern.
"""

import os
import sys

import numpy as np

import params
import channel
import tx_nco
import rx_frontend as C
import rx_backend_eval as D

SPS = params.SAMPLES_PER_SYMBOL
QUICK = "--quick" in sys.argv

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DIR = os.path.join(HERE, "d_outputs")

H = C.design_lpf()                       # float taps, order 24
D_FIR = C.group_delay_samples(H)         # 12 samples

SAVE_FILES = True                         # plots / golden vectors (compare_results.py turns this off)
RESULTS = {}                             # filled by the checks, saved by save_results()


# =======================================================================================
# Chain building blocks
# =======================================================================================

def tx_float(bits):
    I, Q = tx_nco.map_qpsk(bits)
    cos, sin = tx_nco.nco_float(len(I) * SPS)
    s = tx_nco.modulate(I, Q, cos, sin, SPS)
    return I, Q, s, cos, sin


def rx_float(r, cos, sin, h, aligned=True):
    """h=None means no FIR: mixer output goes straight to integrate-and-dump."""
    if h is None:
        return C.downconvert(r, cos, sin)
    return C.rx_frontend(r, cos, sin, h, aligned=aligned)


def decode(yi, yq, timing_offset=0):
    I_hat, Q_hat = D.integrate_dump(yi, yq, timing_offset)
    return I_hat, Q_hat, D.decide(I_hat, Q_hat)


def simulate(ebn0_db, n_sym, seed, noise_mode="numpy"):
    rng = np.random.default_rng(seed)
    bits = rng.integers(0, 2, 2 * n_sym).astype(np.uint8)
    I, Q, s, cos, sin = tx_float(bits)
    r = channel.awgn(s, ebn0_db, mode=noise_mode, seed=seed + 1)
    return bits, r, cos, sin


def run_chunk(ebn0_db, n_sym, seed):
    """One chunk of the sweep: the same noisy r decoded without and with the FIR."""
    bits, r, cos, sin = simulate(ebn0_db, n_sym, seed)
    out = {}
    for name, h in (("no_fir", None), ("fir", H)):
        yi, yq = rx_float(r, cos, sin, h, aligned=True)
        out[name] = D.count_errors(bits, decode(yi, yq)[2])
    return out


# =======================================================================================
# 1. Noiseless sanity (gate: must be exactly zero errors)
# =======================================================================================

def check_noiseless():
    print("\n--- Check 1: noiseless float chain must give exactly 0 errors ---")
    bits = np.random.default_rng(1).integers(0, 2, 4000).astype(np.uint8)
    I, Q, s, cos, sin = tx_float(bits)

    for name, h, aligned, off in (("no FIR", None, True, 0),
                                  ("FIR aligned", H, True, 0),
                                  ("FIR causal", H, False, D_FIR)):
        yi, yq = rx_float(s, cos, sin, h, aligned)
        errs, total = D.count_errors(bits, decode(yi, yq, off)[2])
        print(f"  {name:12s}: {errs} errors / {total} bits")
        assert errs == 0, f"{name}: chain is broken, do not trust any BER number"

    yi, yq = rx_float(s, cos, sin, None)
    I_hat, Q_hat = D.integrate_dump(yi, yq)
    assert np.allclose(I_hat / D.NOISELESS_LEVEL, I) and np.allclose(Q_hat / D.NOISELESS_LEVEL, Q)
    print(f"  no-FIR decision values are exactly +/-{D.NOISELESS_LEVEL:g} (= SPS/2).")
    print("PASS")


# =======================================================================================
# 2. Causal vs aligned timing
# =======================================================================================

def check_timing():
    print("\n--- Check 2: causal FIR + offset D equals aligned FIR + offset 0 ---")
    bits, r, cos, sin = simulate(6.0, 500, seed=9)
    yi_c, yq_c = rx_float(r, cos, sin, H, aligned=False)
    yi_a, yq_a = rx_float(r, cos, sin, H, aligned=True)
    Ic, Qc, _ = decode(yi_c, yq_c, timing_offset=D_FIR)
    Ia, Qa, _ = decode(yi_a, yq_a, timing_offset=0)
    n = len(Ic)
    assert np.allclose(Ic, Ia[:n]) and np.allclose(Qc, Qa[:n])
    print(f"  {n} of {len(Ia)} symbols compared (causal mode cuts off the last one), identical.")
    wrong = decode(yi_c, yq_c, timing_offset=0)[0]
    assert not np.allclose(wrong[:n], Ia[:n])
    print("  and timing_offset = 0 on the causal stream does NOT match, so the offset matters.")
    print("PASS")


# =======================================================================================
# 3. BER sweep
# =======================================================================================

def sweep():
    print("\n--- Check 3: BER vs Eb/N0, without and with the FIR ---")
    ebn0_list = [0, 2, 4, 6, 8]
    max_bits = 200_000 if QUICK else 1_500_000
    names = ["no_fir", "fir"]
    res = D.ber_sweep(run_chunk, ebn0_list, names, min_errors=100, max_bits=max_bits)

    theory = [channel.theory_ber(e) for e in ebn0_list]
    exact_no = [C.ber_semi_analytic(None, e) for e in ebn0_list]
    exact_fir = [C.ber_semi_analytic(H, e) for e in ebn0_list]
    print(f"{'Eb/N0':>6s} {'bits':>9s} | {'no-FIR':>9s} {'theory':>9s} {'z':>5s} | "
          f"{'FIR':>9s} {'exact':>9s} {'z':>5s} | {'FIR cost':>8s}")
    for k, e in enumerate(ebn0_list):
        b0, b1 = res["no_fir"], res["fir"]
        z0 = D.z_score(b0["errors"][k], b0["bits"][k], exact_no[k])
        z1 = D.z_score(b1["errors"][k], b1["bits"][k], exact_fir[k])
        cost = C.ber_penalty_db(H, e)
        print(f"{e:6.1f} {b0['bits'][k]:9d} | {b0['ber'][k]:9.3e} {theory[k]:9.3e} {z0:5.1f} | "
              f"{b1['ber'][k]:9.3e} {exact_fir[k]:9.3e} {z1:5.1f} | {cost:7.3f}dB")
        if not QUICK:
            assert abs(z0) < 4 and abs(z1) < 4, "simulation disagrees with the exact prediction"

    RESULTS.update(
        ebn0=np.array(ebn0_list, dtype=float), theory=np.array(theory),
        exact_no_fir=np.array(exact_no), exact_fir=np.array(exact_fir),
        err_no_fir=np.array(res["no_fir"]["errors"]), bits_no_fir=np.array(res["no_fir"]["bits"]),
        ber_no_fir=np.array(res["no_fir"]["ber"]),
        err_fir=np.array(res["fir"]["errors"]), bits_fir=np.array(res["fir"]["bits"]),
        ber_fir=np.array(res["fir"]["ber"]))

    if SAVE_FILES:
        fine = np.arange(0, 8.01, 0.25)
        path = os.path.join(OUT_DIR, "float_ber_curve.png")
        D.plot_ber(
            sim={"simulated, no FIR": (ebn0_list, res["no_fir"]["ber"]),
                 "simulated, FIR": (ebn0_list, res["fir"]["ber"])},
            lines={"theory Q(sqrt(2Eb/N0))": (fine, [channel.theory_ber(e) for e in fine]),
                   "exact, FIR (Part C)": (fine, [C.ber_semi_analytic(H, e) for e in fine])},
            path=path)
    print("PASS: both simulated curves sit on their predictions."
          if not QUICK else "(quick mode: statistics not asserted)")
    if SAVE_FILES:
        print(f"wrote {path}")


# =======================================================================================
# 4. Constellations
# =======================================================================================

def constellations():
    if not SAVE_FILES:
        return
    print("\n--- Check 4: constellation plots (FIR, aligned) ---")
    panels = []
    for e in (0.0, 6.0, 12.0):
        bits, r, cos, sin = simulate(e, 3000, seed=21)
        yi, yq = rx_float(r, cos, sin, H, aligned=True)
        I_hat, Q_hat, _ = decode(yi, yq)
        panels.append((f"Eb/N0 = {e:.0f} dB", I_hat[1:-1], Q_hat[1:-1]))
    path = os.path.join(OUT_DIR, "float_constellations.png")
    D.plot_constellations(panels, path, scale=D.NOISELESS_LEVEL)
    print(f"wrote {path}")


# =======================================================================================
# 5. LFSR (hardware-style) noise, short run
# =======================================================================================

def check_lfsr_noise():
    print("\n--- Check 5: hardware-style LFSR noise, 4000 symbols at 2 dB ---")
    bits = tx_nco.gen_bits(2 * 4000)
    I, Q, s, cos, sin = tx_float(bits)
    r = channel.awgn(s, 2.0, mode="lfsr", seed=3)
    yi, yq = rx_float(r, cos, sin, H, aligned=True)
    measured = D.ber(bits, decode(yi, yq)[2])
    predicted = C.ber_semi_analytic(H, 2.0)
    print(f"  BER measured {measured:.4f} | exact prediction {predicted:.4f}")
    assert abs(measured - predicted) / predicted < 0.20
    RESULTS.update(lfsr_ebn0=2.0, lfsr_ber=measured, lfsr_bits=len(bits), lfsr_exact=predicted)
    print("PASS")


# =======================================================================================
# 6. Shared 4 dB scenario (the fixed_point folder runs the identical one)
# =======================================================================================

SCENARIO_EBN0_DB = 4.0
SCENARIO_N_SYM = 100_000      # same in both folders, in quick mode too, so the results line up
SCENARIO_BIT_SEED = 5
SCENARIO_NOISE_SEED = 11


def check_scenario():
    print(f"\n--- Check 6: shared {SCENARIO_EBN0_DB:g} dB scenario (same bits, same noise as the integer run) ---")
    bits = np.random.default_rng(SCENARIO_BIT_SEED).integers(0, 2, 2 * SCENARIO_N_SYM).astype(np.uint8)
    I, Q, s, cos, sin = tx_float(bits)
    r = channel.awgn(s, SCENARIO_EBN0_DB, mode="numpy", seed=SCENARIO_NOISE_SEED)
    yi, yq = rx_float(r, cos, sin, H, aligned=True)
    I_hat, Q_hat, rx_bits = decode(yi, yq)
    ber_fl = D.ber(bits, rx_bits)
    print(f"  BER float {ber_fl:.5f}")
    RESULTS.update(
        scen_ebn0=SCENARIO_EBN0_DB, scen_bits_tx=bits, scen_bits_rx=rx_bits, scen_ber=ber_fl,
        scen_I=(I_hat / D.NOISELESS_LEVEL).astype(np.float32),
        scen_Q=(Q_hat / D.NOISELESS_LEVEL).astype(np.float32),
        noiseless_level=D.NOISELESS_LEVEL, acc_bits=D.ACC_BITS)
    print("PASS")


# =======================================================================================

def main():
    """Run every check. Returns the numbers compare_results.py needs; saves no results file."""
    if SAVE_FILES:
        os.makedirs(OUT_DIR, exist_ok=True)
    print("=" * 74)
    print("Part D FLOATING-POINT run" + ("  (quick mode)" if QUICK else ""))
    print("=" * 74)

    check_noiseless()
    check_timing()
    sweep()
    constellations()
    check_lfsr_noise()
    check_scenario()

    print("\n" + "=" * 74)
    print("All floating-point checks completed and PASSED (every check above is an assert).")
    print("=" * 74)
    return dict(RESULTS, kind="floating-point", quick=QUICK, d_fir=D_FIR)


if __name__ == "__main__":
    main()
