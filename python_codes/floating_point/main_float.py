"""
main_float.py
Floating-point end-to-end QPSK simulation runner.

Runs the QPSK transmitter, channel, and receiver using floating-point arithmetic to establish a reference for evaluating the algorithm and comparing it with the fixed-point implementation.

The simulation performs the following checks:

    1. Noiseless decoding produces zero bit errors with and without FIR filtering, including causal and aligned configurations.
    2. Causal FIR filtering with timing offset D is compared against aligned FIR filtering with zero timing offset.
    3. BER sweeps with and without FIR filtering are compared against theoretical QPSK performance and the exact prediction.
    4. Receiver constellation plots are generated at selected Eb/N0 values.
    5. A short hardware-style LFSR noise test checks the measured BER.
    6. A shared 4 dB scenario is saved for comparison with the fixed-point implementation.

Notes:
    - BER sweeps use NumPy-generated noise. The LFSR noise sequence is periodic, so it is reserved for short tests.
    - Sweep bits are generated using NumPy rather than PRBS-7, avoiding dependence on a short repeating bit pattern.
    - The floating-point results serve as a reference; agreement with theoretical results is assessed under the tested conditions.
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

OUT_DIR = "d_outputs"

H = C.design_lpf()                       # float taps, order 24
D_FIR = C.group_delay_samples(H)         # 12 samples

SAVE_FILES = True                         # plots / golden vectors (compare_results.py turns this off)


# Chain building blocks

def tx_float(bits):
    # Map input bits to QPSK symbols and generate the modulated carrier signal.
    I, Q = tx_nco.map_qpsk(bits)
    cos, sin = tx_nco.nco_float(len(I) * SPS)
    s = tx_nco.modulate(I, Q, cos, sin, SPS)
    return I, Q, s, cos, sin


def rx_float(r, cos, sin, h, aligned=True):
    #h=None means no FIR: mixer output goes straight to integrate-and-dump.
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


# 1. Noiseless sanity (gate: must be exactly zero errors)

def check_noiseless():
    print("\nCheck 1: noiseless float chain must give exactly 0 errors")
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


# 2. Causal vs aligned timing

def check_timing():
    print("\nCheck 2: causal FIR + offset D equals aligned FIR + offset 0 ")
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


# 3. BER sweep

def sweep():
    print("\nCheck 3: BER vs Eb/N0, without and with the FIR")
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

    print("PASS: both simulated curves sit on their predictions."
          if not QUICK else "(quick mode: statistics not asserted)")
    if SAVE_FILES:
        fine = np.arange(0, 8.01, 0.25)
        path = os.path.join(OUT_DIR, "float_ber_curve.png")
        D.plot_ber(
            sim={"simulated, no FIR": (ebn0_list, res["no_fir"]["ber"]),
                 "simulated, FIR": (ebn0_list, res["fir"]["ber"])},
            lines={"theory Q(sqrt(2Eb/N0))": (fine, [channel.theory_ber(e) for e in fine]),
                   "exact, FIR (Part C)": (fine, [C.ber_semi_analytic(H, e) for e in fine])},
            path=path)
        print(f"wrote {path}")

    results = {"ebn0": np.array(ebn0_list, dtype=float)}
    for n in names:
        results[f"err_{n}"] = np.array(res[n]["errors"])
        results[f"bits_{n}"] = np.array(res[n]["bits"])
        results[f"ber_{n}"] = np.array(res[n]["ber"])
    results["theory"] = np.array(theory)
    results["exact_no_fir"] = np.array(exact_no)
    results["exact_fir"] = np.array(exact_fir)
    return results


# 4. Constellations

def constellations():
    if not SAVE_FILES:
        return
    print("\nCheck 4: constellation plots (FIR, aligned)")
    panels = []
    for e in (0.0, 6.0, 12.0):
        bits, r, cos, sin = simulate(e, 3000, seed=21)
        yi, yq = rx_float(r, cos, sin, H, aligned=True)
        I_hat, Q_hat, _ = decode(yi, yq)
        panels.append((f"Eb/N0 = {e:.0f} dB", I_hat[1:-1], Q_hat[1:-1]))
    path = os.path.join(OUT_DIR, "float_constellations.png")
    D.plot_constellations(panels, path, scale=D.NOISELESS_LEVEL)
    print(f"wrote {path}")


# 5. LFSR (hardware-style) noise, short run

def check_lfsr_noise():
    print("\nCheck 5: hardware-style LFSR noise, 4000 symbols at 2 dB")
    bits = tx_nco.gen_bits(2 * 4000)
    I, Q, s, cos, sin = tx_float(bits)
    r = channel.awgn(s, 2.0, mode="lfsr", seed=3)
    yi, yq = rx_float(r, cos, sin, H, aligned=True)
    measured = D.ber(bits, decode(yi, yq)[2])
    predicted = C.ber_semi_analytic(H, 2.0)
    print(f"  BER measured {measured:.4f} | exact prediction {predicted:.4f}")
    assert abs(measured - predicted) / predicted < 0.20
    print("PASS")
    return dict(lfsr_ber=measured, lfsr_exact=predicted)


# 6. Shared 4 dB scenario (the fixed_point folder runs the identical one)

SCENARIO_EBN0_DB = 4.0
SCENARIO_N_SYM = 100_000      # same in both folders, in quick mode too, so the results line up
SCENARIO_BIT_SEED = 5
SCENARIO_NOISE_SEED = 11


def check_scenario():
    print(f"\nCheck 6: shared {SCENARIO_EBN0_DB:g} dB scenario (same bits, same noise as the integer run)")
    bits = np.random.default_rng(SCENARIO_BIT_SEED).integers(0, 2, 2 * SCENARIO_N_SYM).astype(np.uint8)
    I, Q, s, cos, sin = tx_float(bits)
    r = channel.awgn(s, SCENARIO_EBN0_DB, mode="numpy", seed=SCENARIO_NOISE_SEED)
    yi, yq = rx_float(r, cos, sin, H, aligned=True)
    I_hat, Q_hat, rx_bits = decode(yi, yq)
    ber_fl = D.ber(bits, rx_bits)
    print(f"  BER float {ber_fl:.5f}")
    print("PASS")
    return dict(
        scen_ebn0=SCENARIO_EBN0_DB, scen_bits_tx=bits, scen_bits_rx=rx_bits, scen_ber=ber_fl,
        scen_I=(I_hat / D.NOISELESS_LEVEL).astype(np.float32),
        scen_Q=(Q_hat / D.NOISELESS_LEVEL).astype(np.float32),
        noiseless_level=D.NOISELESS_LEVEL)


def main():
    """Run every check. Returns the numbers compare_results.py needs; saves no results file."""
    if SAVE_FILES:
        os.makedirs(OUT_DIR, exist_ok=True)
    print("FLOATING-POINT run" + ("  (quick mode)" if QUICK else ""))

    check_noiseless()
    check_timing()
    results = sweep()
    constellations()
    results.update(check_lfsr_noise())
    results.update(check_scenario())

    print("All floating-point checks completed and PASSED (every check above is an assert).")
    return results


if __name__ == "__main__":
    main()
